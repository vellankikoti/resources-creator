variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone override (empty = {region}-a)"
  type        = string
  default     = ""
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

variable "machine_type" {
  description = "GCE machine type override (empty = use env-based default)"
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

variable "ssh_username" {
  description = "SSH username override (auto-detected from os_type if empty)"
  type        = string
  default     = ""
}

variable "image" {
  description = "VM image override (auto-detected from os_type if empty)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common labels for all resources"
  type        = map(string)
  default = {
    owner       = "platform-team"
    managed-by  = "terraform"
    cost-center = "vm-learning"
    repo        = "resource-creator"
  }
}
