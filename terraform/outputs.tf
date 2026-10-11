output "project_id" {
  description = "GCP Project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP Region"
  value       = var.region
}

output "zone" {
  description = "GCP Zone for the single-zone GKE cluster"
  value       = var.zone
}

output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "vpc_name" {
  description = "Custom VPC network name"
  value       = google_compute_network.vpc.name
}

output "node_subnet_name" {
  description = "Primary GKE node subnet name"
  value       = google_compute_subnetwork.nodes.name
}

output "proxy_only_subnet_name" {
  description = "Regional managed proxy-only subnet name"
  value       = google_compute_subnetwork.proxy_only.name
}

output "node_service_account_email" {
  description = "Dedicated GKE node service account email"
  value       = google_service_account.gke_nodes.email
}

output "get_credentials_command" {
  description = "Command to configure kubectl credentials for this cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}
