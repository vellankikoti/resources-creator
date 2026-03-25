locals {
  # Merge Linux and Windows instances for unified outputs
  all_instances = merge(google_compute_instance.vm, google_compute_instance.windows_vm)
}

output "instance_names" {
  description = "Map of instance key to instance name"
  value = {
    for k, v in local.all_instances : k => v.name
  }
}

output "public_ips" {
  description = "Map of instance key to external IP"
  value = {
    for k, v in local.all_instances :
    k => v.network_interface[0].access_config[0].nat_ip
  }
}

output "private_ips" {
  description = "Map of instance key to internal IP"
  value = {
    for k, v in local.all_instances :
    k => v.network_interface[0].network_ip
  }
}

output "os_type" {
  description = "Operating system type"
  value       = var.os_type
}

output "ssh_user" {
  description = "SSH/login username for the instances"
  value       = local.effective_ssh_user
}

output "zone" {
  description = "Zone where instances are created"
  value       = local.effective_zone
}
