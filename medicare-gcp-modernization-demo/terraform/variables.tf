variable "project_id" {
  description = "GCP project ID used for the demo."
  type        = string
}

variable "primary_region" {
  description = "Primary GCP region."
  type        = string
  default     = "us-east4"
}

variable "dr_region" {
  description = "Secondary DR region."
  type        = string
  default     = "us-central1"
}

variable "vm_target_size" {
  description = "Number of VM instances in the primary regional MIG."
  type        = number
  default     = 3
}

variable "enable_gke" {
  description = "Deploy the regional GKE workload."
  type        = bool
  default     = true
}

variable "enable_dr" {
  description = "Deploy a warm secondary-region VM MIG for DR demonstrations."
  type        = bool
  default     = false
}

variable "enable_filestore" {
  description = "Deploy Regional Filestore. Disabled by default because it is relatively expensive for a short demo."
  type        = bool
  default     = false
}

variable "enable_local_ssd" {
  description = "Attach one Local SSD scratch disk to each demo VM. Disabled by default to reduce demo cost."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to supported resources."
  type        = map(string)
  default = {
    application = "medicare-portal-demo"
    environment = "demo"
    managed_by  = "terraform"
  }
}
