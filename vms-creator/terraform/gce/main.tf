# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  env_config = {
    dev     = { machine_type = "e2-medium" }
    qa      = { machine_type = "e2-medium" }
    staging = { machine_type = "e2-standard-2" }
    prod    = { machine_type = "e2-standard-4" }
  }

  selected = { for env in var.environments : env => local.env_config[env] }

  effective_zone = var.zone != "" ? var.zone : "${var.region}-a"

  effective_machine_type = {
    for env, cfg in local.selected :
    env => var.machine_type != "" ? var.machine_type : cfg.machine_type
  }

  is_windows = var.os_type == "windows"
  is_linux   = !local.is_windows

  # Image selection based on os_type
  effective_image = (
    var.image != "" ? var.image :
    var.os_type == "ubuntu" ? "ubuntu-os-cloud/ubuntu-2204-lts" :
    var.os_type == "rocky" ? "rocky-linux-cloud/rocky-linux-9" :
    "windows-cloud/windows-2022"
  )

  # SSH user depends on OS
  effective_ssh_user = (
    var.ssh_username != "" ? var.ssh_username :
    var.os_type == "ubuntu" ? "ubuntu" :
    var.os_type == "rocky" ? "rocky" :
    "admin"
  )

  # Startup script
  linux_startup_script = (
    var.os_type == "ubuntu" ? file("${path.module}/../../scripts/startup/ubuntu-setup.sh") :
    var.os_type == "rocky" ? file("${path.module}/../../scripts/startup/rocky-setup.sh") :
    ""
  )
  windows_startup_script = local.is_windows ? file("${path.module}/../../scripts/startup/windows-setup.ps1") : ""

  common_labels = merge(var.tags, {
    gcp-project = var.project_id
    os-type     = var.os_type
  })

  # Ports open for learning
  allowed_ports = ["22", "80", "443", "3000", "3389", "5000", "5985", "5986", "6443", "8080", "8443"]
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "google_project" "current" {}

# ─── Networking ───────────────────────────────────────────────────────────────

resource "google_compute_network" "main" {
  for_each = local.selected

  name                    = "${var.base_name}-${each.key}-vm-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  for_each = local.selected

  name          = "${var.base_name}-${each.key}-vm-subnet"
  ip_cidr_range = "10.51.${index(var.environments, each.key)}.0/24"
  region        = var.region
  network       = google_compute_network.main[each.key].id
}

# ─── Firewall Rules ──────────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_common" {
  for_each = local.selected

  name    = "${var.base_name}-${each.key}-vm-allow-common"
  network = google_compute_network.main[each.key].id

  allow {
    protocol = "tcp"
    ports    = local.allowed_ports
  }

  # NodePort range
  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }

  # ICMP (ping)
  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Open ports for learning VMs - NOT for production"
}

# ─── Linux Compute Instances ─────────────────────────────────────────────────

resource "google_compute_instance" "vm" {
  for_each = local.is_linux ? {
    for pair in flatten([
      for env, cfg in local.selected : [
        for i in range(var.instance_count) : {
          key = "${env}-${i}"
          env = env
          idx = i
        }
      ]
    ]) : pair.key => pair
  } : {}

  name         = "${var.base_name}-${each.value.env}-vm-${each.value.idx}"
  machine_type = local.effective_machine_type[each.value.env]
  zone         = local.effective_zone

  boot_disk {
    initialize_params {
      image = local.effective_image
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main[each.value.env].id

    access_config {
      # Ephemeral external IP
    }
  }

  metadata = {
    ssh-keys = "${local.effective_ssh_user}:${var.ssh_public_key}"
  }

  metadata_startup_script = local.linux_startup_script

  labels = merge(local.common_labels, {
    env  = each.value.env
    name = "${var.base_name}-${each.value.env}-vm-${each.value.idx}"
  })

  tags = ["${var.base_name}-${each.value.env}-vm"]
}

# ─── Windows Compute Instances ────────────────────────────────────────────────

resource "google_compute_instance" "windows_vm" {
  for_each = local.is_windows ? {
    for pair in flatten([
      for env, cfg in local.selected : [
        for i in range(var.instance_count) : {
          key = "${env}-${i}"
          env = env
          idx = i
        }
      ]
    ]) : pair.key => pair
  } : {}

  name         = "${var.base_name}-${each.value.env}-vm-${each.value.idx}"
  machine_type = local.effective_machine_type[each.value.env]
  zone         = local.effective_zone

  boot_disk {
    initialize_params {
      image = local.effective_image
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main[each.value.env].id

    access_config {
      # Ephemeral external IP
    }
  }

  metadata = {
    windows-startup-script-ps1 = local.windows_startup_script
  }

  labels = merge(local.common_labels, {
    env  = each.value.env
    name = "${var.base_name}-${each.value.env}-vm-${each.value.idx}"
  })

  tags = ["${var.base_name}-${each.value.env}-vm"]
}
