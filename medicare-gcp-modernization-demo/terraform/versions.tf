terraform {
  required_version = ">= 1.12.2"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.40.0, < 8.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.40.0, < 8.0.0"
    }
  }

  # The bucket is passed at init time:
  # terraform init -backend-config="bucket=${TF_STATE_BUCKET}"
  backend "gcs" {
    prefix = "medicare-modernization-demo"
  }
}

provider "google" {
  project = var.project_id
  region  = var.primary_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.primary_region
}
