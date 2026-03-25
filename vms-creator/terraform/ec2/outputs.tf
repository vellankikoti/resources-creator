output "instance_ids" {
  description = "Map of instance key to instance ID"
  value = {
    for k, v in aws_instance.vm : k => v.id
  }
}

output "public_ips" {
  description = "Map of instance key to public IP (Elastic IP)"
  value = {
    for k, v in aws_eip.vm : k => v.public_ip
  }
}

output "private_ips" {
  description = "Map of instance key to private IP"
  value = {
    for k, v in aws_instance.vm : k => v.private_ip
  }
}

output "os_type" {
  description = "Operating system type"
  value       = var.os_type
}

output "ssh_user" {
  description = "SSH/login username for the instances"
  value       = local.ssh_user
}

output "security_group_ids" {
  description = "Map of environment to security group ID"
  value = {
    for k, v in aws_security_group.vm : k => v.id
  }
}

output "vpc_ids" {
  description = "Map of environment to VPC ID"
  value = {
    for k, v in aws_vpc.main : k => v.id
  }
}

