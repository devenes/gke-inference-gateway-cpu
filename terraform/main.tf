provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "networkservices.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  node_sa_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]

  pods_range_name     = "pods"
  services_range_name = "services"
}

# 1. Enable Required Google Cloud APIs
resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 2. Custom VPC Network
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

# 3. Primary GKE Node Subnet with Pod & Service Secondary Ranges
resource "google_compute_subnetwork" "nodes" {
  project                  = var.project_id
  name                     = "${var.cluster_name}-nodes"
  ip_cidr_range            = var.node_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = var.pods_subnet_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = var.services_subnet_cidr
  }
}

# 4. Regional Managed Proxy-Only Subnet (Mandatory for gke-l7-regional-external-managed GatewayClass)
resource "google_compute_subnetwork" "proxy_only" {
  project       = var.project_id
  name          = "${var.cluster_name}-proxy-only"
  ip_cidr_range = var.proxy_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# 5. Firewall Rule Allowing Regional Envoy Proxy & GCP Health Checks to Reach Model Pods, EPP, and BBR
resource "google_compute_firewall" "allow_proxy_and_health_checks" {
  project = var.project_id
  name    = "${var.cluster_name}-allow-proxy-and-hc"
  network = google_compute_network.vpc.name

  direction = "INGRESS"
  priority  = 1000

  source_ranges = [
    var.proxy_subnet_cidr,
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  destination_ranges = [
    var.node_subnet_cidr,
    var.pods_subnet_cidr,
  ]

  allow {
    protocol = "tcp"
    # 8080: llama.cpp model servers (/v1/chat/completions, /health)
    # 9002: Endpoint Picker (EPP) ext-proc gRPC
    # 9003: Endpoint Picker (EPP) gRPC health check
    # 9004: Body-Based Router (BBR) ext-proc gRPC
    # 9005: Body-Based Router (BBR) gRPC health check
    ports = ["8080", "9002", "9003", "9004", "9005"]
  }
}

# 6. Dedicated Least-Privilege Service Account for GKE Nodes
resource "google_service_account" "gke_nodes" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "GKE Node SA for ${var.cluster_name}"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset(local.node_sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# 7. Single-Zone GKE Standard Cluster with Gateway API Standard Channel Enabled
resource "google_container_cluster" "primary" {
  provider = google-beta
  project  = var.project_id
  name     = var.cluster_name
  location = var.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = local.pods_range_name
    services_secondary_range_name = local.services_range_name
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      # Disabled to save ~400Mi RAM / ~150m CPU on our single node and avoid GMP ingestion fees.
      # GKE Inference Gateway EPP scrapes model pod /metrics directly in-cluster.
      enabled = false
    }
  }

  depends_on = [
    google_project_service.apis,
    google_compute_subnetwork.nodes,
    google_compute_subnetwork.proxy_only,
    google_project_iam_member.gke_node_roles,
  ]
}

# 8. Single-Node CPU Inference Node Pool
resource "google_container_node_pool" "cpu_pool" {
  provider   = google-beta
  project    = var.project_id
  name       = "cpu-inference-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.id
  node_count = var.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    disk_size_gb    = var.disk_size_gb
    disk_type       = var.disk_type
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      role = "cpu-inference"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
