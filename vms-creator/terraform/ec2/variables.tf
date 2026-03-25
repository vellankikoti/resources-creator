variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
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

variable "instance_type" {
  description = "EC2 instance type override (empty = use env-based default)"
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

variable "ami_id" {
  description = "AMI ID override (empty = auto-detect based on os_type)"
  type        = string
  default     = ""
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
