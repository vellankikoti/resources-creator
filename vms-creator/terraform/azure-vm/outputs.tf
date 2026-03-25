locals {
  # Merge Linux and Windows VMs for unified outputs
  all_vm_names = merge(
    { for k, v in azurerm_linux_virtual_machine.vm : k => v.name },
    { for k, v in azurerm_windows_virtual_machine.vm : k => v.name }
  )
}

output "vm_names" {
  description = "Map of instance key to VM name"
  value       = local.all_vm_names
}

output "public_ips" {
  description = "Map of instance key to public IP"
  value = {
    for k, v in azurerm_public_ip.vm : k => v.ip_address
  }
}

output "private_ips" {
  description = "Map of instance key to private IP"
  value = {
    for k, v in azurerm_network_interface.vm :
    k => v.ip_configuration[0].private_ip_address
  }
}

output "os_type" {
  description = "Operating system type"
  value       = var.os_type
}

output "ssh_user" {
  description = "SSH/login username for the instances"
  value       = local.effective_admin_username
}

output "resource_group_names" {
  description = "Map of environment to resource group name"
  value = {
    for k, v in azurerm_resource_group.main : k => v.name
  }
}
