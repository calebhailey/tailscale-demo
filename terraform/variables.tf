variable "aws_profile" {
  type        = string
  default     = "tailscale-demo"
  description = "AWS CLI profile used by the provider."
}

variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region for the short-lived demonstration."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.42.0/24"
  description = "Demonstration VPC and Tailscale subnet-router prefix."
}

variable "availability_zones" {
  type        = list(string)
  default     = ["us-east-2a", "us-east-2c"]
  description = "Two Availability Zones used by the demo. Override for another AWS region."

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Provide exactly two Availability Zones."
  }
}

variable "router_ami_id" {
  type        = string
  description = "ARM64 Debian subnet-router AMI produced by Packer."
  nullable    = false
}

variable "app_ami_id" {
  type        = string
  description = "ARM64 Debian application AMI produced by Packer."
  nullable    = false
}

variable "instance_type" {
  type        = string
  default     = "t4g.micro"
  description = "ARM64 instance type used by both fixed-size Auto Scaling Groups."
}

variable "router_instance_count" {
  type        = number
  default     = 2
  description = "Router ASG desired, minimum, and maximum capacity."
}

variable "router_version" {
  type        = string
  default     = "0"
  description = "Unix-epoch version used to deliberately create a new router launch-template version and trigger its rolling refresh."
}

variable "app_instance_count" {
  type        = number
  default     = 3
  description = "App ASG desired, minimum, and maximum capacity."
}

variable "app_port" {
  type        = number
  default     = 8080
  description = "TCP port served by tailscale-demo-app."
}

variable "valkey_node_type" {
  type        = string
  default     = "cache.t4g.micro"
  description = "ElastiCache node type for the single-node Valkey demonstration."
}

variable "valkey_password" {
  type        = string
  sensitive   = true
  nullable    = false
  description = "Password for the Valkey RBAC user. Supply it through TF_VAR_valkey_password; it is write-only and is not stored in Terraform state."

  validation {
    condition     = length(var.valkey_password) >= 16 && length(var.valkey_password) <= 128 && can(regex("^[ -~]+$", var.valkey_password)) && !strcontains(var.valkey_password, ",") && !strcontains(var.valkey_password, "\"") && !strcontains(var.valkey_password, "/") && !strcontains(var.valkey_password, "@")
    error_message = "The Valkey CLI password must be 16-128 characters and cannot contain comma, double quote, slash, or at sign."
  }
}

variable "valkey_password_version" {
  type        = number
  default     = 1
  description = "Increment this value after changing valkey_password to send the replacement password to ElastiCache."
}

variable "ssh_public_key_path" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional public key installed by EC2 for the app OpenSSH demonstration, such as ~/.ssh/tailscale-demo.pub."
}

variable "tailscale_router_client_id" {
  type        = string
  description = "Client ID of the router AWS workload-identity federation credential. This is not a secret."
  nullable    = false
}

variable "tailscale_router_audience" {
  type        = string
  description = "Audience of the router AWS workload-identity federation credential. This is not a secret."
  nullable    = false
}

variable "tailscale_app_client_id" {
  type        = string
  description = "Client ID of the app AWS workload-identity federation credential. This is not a secret."
  nullable    = false
}

variable "tailscale_app_audience" {
  type        = string
  description = "Audience of the app AWS workload-identity federation credential. This is not a secret."
  nullable    = false
}
