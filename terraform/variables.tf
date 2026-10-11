variable "project_id" {
  description = "Google Cloud Project ID where GKE Inference Gateway MVP is provisioned"
  type        = string
}

variable "region" {
  description = "GCP region for VPC subnetworks and regional external Gateway"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Single GCP zone for the GKE Standard cluster and CPU node pool"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE Standard cluster"
  type        = string
  default     = "gke-inference-gw-cpu"
}

variable "machine_type" {
  description = "GCE machine type for the single CPU inference node (2 vCPU, 8 GB RAM)"
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Number of nodes in the single-zone CPU node pool"
  type        = number
  default     = 1
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for the GKE node"
  type        = number
  default     = 30
}

variable "disk_type" {
  description = "Boot disk type for the GKE node (pd-standard is cheapest for CPU inference)"
  type        = string
  default     = "pd-standard"
}

variable "node_subnet_cidr" {
  description = "Primary CIDR range for the GKE node subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_subnet_cidr" {
  description = "Secondary CIDR range for GKE pods"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_subnet_cidr" {
  description = "Secondary CIDR range for GKE services"
  type        = string
  default     = "10.30.0.0/20"
}

variable "proxy_subnet_cidr" {
  description = "CIDR range for the regional Envoy proxy-only subnet required by gke-l7-regional-external-managed"
  type        = string
  default     = "10.10.1.0/24"
}
