packer {
  required_plugins {
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
