output "vpc_name" {
  value       = module.network.name
  description = "Demo VPC name."
}

output "primary_mig_id" {
  value       = module.vm_mig_primary.id
  description = "Primary regional managed instance group ID."
}

output "dr_mig_id" {
  value       = var.enable_dr ? module.vm_mig_dr[0].id : null
  description = "Optional warm DR regional MIG ID."
}

output "gke_cluster_name" {
  value       = var.enable_gke ? module.gke_primary[0].name : null
  description = "Regional GKE cluster name."
}

output "gke_get_credentials" {
  value = var.enable_gke ? "gcloud container clusters get-credentials ${module.gke_primary[0].name} --region ${var.primary_region} --project ${var.project_id}" : null
}

output "object_bucket" {
  value       = module.portal_objects.name
  description = "Cloud Storage bucket used for object storage."
}

output "filestore_ip" {
  value       = var.enable_filestore ? google_filestore_instance.shared[0].networks[0].ip_addresses[0] : null
  description = "Regional Filestore IP when enabled."
}
