locals {
  primary_zones = [
    "${var.primary_region}-a",
    "${var.primary_region}-b",
    "${var.primary_region}-c"
  ]

  dr_zones = [
    "${var.dr_region}-a",
    "${var.dr_region}-b",
    "${var.dr_region}-c"
  ]

  vm_startup = <<-EOT
    #!/usr/bin/env bash
    set -euxo pipefail
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

    cat >/var/www/html/index.html <<'HTML'
    <!doctype html>
    <html>
      <head><title>Medicare Portal VM Demo</title></head>
      <body style="font-family:Arial;margin:40px">
        <h1>Medicare Portal - VM Workload</h1>
        <p>This page is served from a Compute Engine regional managed instance group.</p>
        <p>Hostname: <strong>HOSTNAME_PLACEHOLDER</strong></p>
        <p>Architecture: Cloud Foundation Fabric + regional MIG + autohealing.</p>
      </body>
    </html>
    HTML
    sed -i "s/HOSTNAME_PLACEHOLDER/$(hostname)/g" /var/www/html/index.html
    echo ok >/var/www/html/health
    systemctl enable --now nginx
  EOT
}

# -----------------------------------------------------------------------------
# NETWORK - Cloud Foundation Fabric
# -----------------------------------------------------------------------------
module "network" {
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-vpc?ref=v58.0.0"

  project_id = var.project_id
  name       = "medicare-demo-vpc"

  subnets = [
    {
      name                  = "primary-app"
      region                = var.primary_region
      ip_cidr_range         = "10.10.0.0/20"
      enable_private_access = true
      secondary_ip_ranges = {
        pods     = { ip_cidr_range = "10.20.0.0/16" }
        services = { ip_cidr_range = "10.30.0.0/20" }
      }
    },
    {
      name                  = "dr-app"
      region                = var.dr_region
      ip_cidr_range         = "10.40.0.0/20"
      enable_private_access = true
      secondary_ip_ranges = {
        pods     = { ip_cidr_range = "10.50.0.0/16" }
        services = { ip_cidr_range = "10.60.0.0/20" }
      }
    }
  ]
}

# Public HTTP is deliberately allowed for this short demo so the VM pages can
# be reached directly. In production, put the MIG behind an external
# Application Load Balancer + Cloud Armor and remove direct public VM access.
resource "google_compute_firewall" "demo_http" {
  name    = "medicare-demo-allow-http"
  project = var.project_id
  network = module.network.self_link

  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["medicare-demo-web"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# -----------------------------------------------------------------------------
# VM WORKLOAD - Fabric compute-vm + regional compute-mig
# -----------------------------------------------------------------------------
module "vm_template_primary" {
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/compute-vm?ref=v58.0.0"

  project_id   = var.project_id
  name         = "medicare-portal-vm"
  zone         = local.primary_zones[0]
  machine_type = "e2-standard-2"
  tags         = ["medicare-demo-web"]
  labels       = var.labels

  create_template = {}

  network_interfaces = [{
    network    = module.network.self_link
    subnetwork = module.network.subnet_self_links["primary-app"]
    nat        = true
    addresses  = null
  }]

  boot_disk = {
    source = {
      image = "projects/debian-cloud/global/images/family/debian-12"
    }
  }

  scratch_disks = {
    count     = var.enable_local_ssd ? 1 : 0
    interface = "NVME"
  }

  metadata_startup_script = local.vm_startup

  service_account = {
    auto_create = true
  }
}

module "vm_mig_primary" {
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/compute-mig?ref=v58.0.0"

  project_id        = var.project_id
  name              = "medicare-portal-primary"
  location          = var.primary_region
  target_size       = var.vm_target_size
  instance_template = module.vm_template_primary.template.self_link

  distribution_policy = {
    target_shape = "EVEN"
    zones        = local.primary_zones
  }

  health_check_config = {
    enable_logging = true
    http = {
      port         = 80
      request_path = "/health"
    }
  }

  auto_healing_policies = {
    initial_delay_sec = 120
  }

  named_ports = {
    http = 80
  }

  depends_on = [google_compute_firewall.demo_http]
}

# Optional warm DR compute capacity. This proves the secondary-region compute
# pattern without forcing every inexpensive demo run to pay for two regions.
module "vm_template_dr" {
  count  = var.enable_dr ? 1 : 0
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/compute-vm?ref=v58.0.0"

  project_id   = var.project_id
  name         = "medicare-portal-vm-dr"
  zone         = local.dr_zones[0]
  machine_type = "e2-standard-2"
  tags         = ["medicare-demo-web"]
  labels       = merge(var.labels, { role = "dr" })

  create_template = {}

  network_interfaces = [{
    network    = module.network.self_link
    subnetwork = module.network.subnet_self_links["dr-app"]
    nat        = true
    addresses  = null
  }]

  boot_disk = {
    source = {
      image = "projects/debian-cloud/global/images/family/debian-12"
    }
  }

  metadata_startup_script = local.vm_startup

  service_account = {
    auto_create = true
  }
}

module "vm_mig_dr" {
  count  = var.enable_dr ? 1 : 0
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/compute-mig?ref=v58.0.0"

  project_id        = var.project_id
  name              = "medicare-portal-dr"
  location          = var.dr_region
  target_size       = 1
  instance_template = module.vm_template_dr[0].template.self_link

  distribution_policy = {
    target_shape = "ANY_SINGLE_ZONE"
    zones        = local.dr_zones
  }

  health_check_config = {
    enable_logging = true
    http = {
      port         = 80
      request_path = "/health"
    }
  }

  auto_healing_policies = {
    initial_delay_sec = 120
  }

  named_ports = {
    http = 80
  }
}

# -----------------------------------------------------------------------------
# CONTAINER WORKLOAD - Fabric regional GKE Standard + node pool
# -----------------------------------------------------------------------------
module "gke_primary" {
  count  = var.enable_gke ? 1 : 0
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/gke-cluster-standard?ref=v58.0.0"

  project_id = var.project_id
  name       = "medicare-gke-primary"
  location   = var.primary_region

  node_locations = local.primary_zones

  # Public nodes/control-plane are used only to make this lab easy to run from
  # Cloud Shell. Production should use private nodes plus controlled egress.
  access_config = {
    dns_access = {
      allow_external_traffic = false
    }
    ip_access = {
      authorized_ranges                = {}
      disable_public_endpoint          = false
      gcp_public_cidrs_access_enabled = true
    }
    private_nodes = false
  }

  vpc_config = {
    network    = module.network.self_link
    subnetwork = module.network.subnet_self_links["primary-app"]
    secondary_range_names = {
      pods     = "pods"
      services = "services"
    }
  }

  enable_features = {
    dataplane_v2          = true
    secret_manager_config = true
    workload_identity     = true
  }

  labels = var.labels
}

module "gke_primary_nodes" {
  count  = var.enable_gke ? 1 : 0
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/gke-nodepool?ref=v58.0.0"

  project_id   = var.project_id
  cluster_name = module.gke_primary[0].name
  location     = var.primary_region
  name         = "portal-pool"
  node_locations = local.primary_zones

  k8s_labels = {
    application = "medicare-portal"
    environment = "demo"
  }

  service_account = {
    create       = true
    email        = "medicare-gke-nodes"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  node_config = {
    machine_type = "e2-standard-2"
    disk_size_gb = 50
    disk_type    = "pd-balanced"
    gvnic        = true
  }

  nodepool_config = {
    autoscaling = {
      min_node_count = 1
      max_node_count = 2
    }
    management = {
      auto_repair  = true
      auto_upgrade = true
    }
  }

  depends_on = [module.gke_primary]
}

# -----------------------------------------------------------------------------
# OBJECT STORAGE - Fabric GCS
# -----------------------------------------------------------------------------
module "portal_objects" {
  source = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/gcs?ref=v58.0.0"

  project_id = var.project_id
  prefix     = var.project_id
  name       = "portal-objects"
  location   = "US"
  versioning = true

  soft_delete_retention = 604800
  labels                = var.labels
}

# -----------------------------------------------------------------------------
# OPTIONAL NETWORK FILE STORAGE
# Enterprise Filestore is regional but comparatively expensive. Keep it off for
# the default demo and enable only when you want to demonstrate shared NFS.
# -----------------------------------------------------------------------------
resource "google_filestore_instance" "shared" {
  count   = var.enable_filestore ? 1 : 0
  name    = "medicare-shared-files"
  project = var.project_id
  location = var.primary_region
  tier     = "ENTERPRISE"

  file_shares {
    capacity_gb = 1024
    name        = "shared"
  }

  networks {
    network = module.network.name
    modes   = ["MODE_IPV4"]
  }

  labels = var.labels
}
