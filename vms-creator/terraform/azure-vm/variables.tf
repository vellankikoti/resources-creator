variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "region" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "base_name" {
  description = "Base name prefix for all resources"
  type        = string
  default     = "platform"
}

variable "environments" {
  description = "List of environments to provision"
  type        = list(string)
  default     = ["dev"]
}

variable "instance_count" {
  description = "Number of VM instances to create per environment"
  type        = number
  default     = 1
}

variable "vm_size" {
  description = "Azure VM size override (empty = use env-based default)"
  type        = string
  default     = ""
}

variable "os_type" {
  description = "Operating system: ubuntu, rocky, or windows"
  type        = string
  default     = "ubuntu"

  validation {
    condition     = contains(["ubuntu", "rocky", "windows"], var.os_type)
    error_message = "os_type must be one of: ubuntu, rocky, windows"
  }
}

variable "ssh_public_key" {
  description = "SSH public key content for instance access (Linux only)"
  type        = string
  default     = ""
}

variable "admin_username" {
  description = "Admin username for the VMs"
  type        = string
  default     = ""
}

variable "admin_password" {
  description = "Admin password for Windows VMs"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    owner       = "platform-team"
    managed_by  = "terraform"
    cost_center = "vm-learning"
    repo        = "resource-creator"
  }
}
