packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.4.0"
    }
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.21.0"
    }
  }
}

variable "app_version" {
  type        = string
  default     = "dev"
  description = "Version recorded alongside the installed application and AMI name."
}

variable "app_binary" {
  type        = string
  default     = "../dist/tailscale-demo-app"
  description = "Path to the Linux binary baked into the image. The release script supplies this artifact."
}

variable "install_tailscale" {
  type        = bool
  default     = false
  description = "Install and enable the Tailscale client in an application image."
}

variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region for amazon-ebs builds."
}

variable "aws_ssh_username" {
  type        = string
  default     = "admin"
  description = "SSH user provided by the selected Debian AMI."
}

variable "aws_instance_type" {
  type        = string
  default     = "t4g.micro"
  description = "Temporary EC2 builder instance type."
}

variable "debian_release" {
  type        = string
  default     = "13"
  description = "Official Debian release number used to select the current ARM64 base AMI."
}
