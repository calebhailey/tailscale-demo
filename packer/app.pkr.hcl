# Usage
#
# Local build (macOS/tart):
#   packer build -only=app.tart-cli.app .
#
# AWS AMI build:
#   packer build -only=app.amazon-ebs.app -var aws_region=us-east-2 .

build {
  name = "app"
  sources = [
    "source.tart-cli.app",
    "source.amazon-ebs.app",
  ]

  provisioner "shell" {
    script           = "scripts/install-base.sh"
    environment_vars = ["INSTALL_TAILSCALE=${var.install_tailscale}"]
  }

  provisioner "file" {
    source      = var.app_binary
    destination = "/tmp/tailscale-demo-app"
  }

  provisioner "file" {
    source      = "systemd/tailscale-demo-app.service"
    destination = "/tmp/tailscale-demo-app.service"
  }

  provisioner "shell" {
    environment_vars = ["APP_VERSION=${var.app_version}"]
    inline_shebang   = "/bin/bash -e"
    inline = [<<-SCRIPT
      set -o pipefail

      test -n "$APP_VERSION"

      if ! id --user tailscale-demo-app >/dev/null 2>&1; then
        sudo useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin tailscale-demo-app
      fi

      sudo install -D -o root -g root -m 0755 /tmp/tailscale-demo-app /usr/local/bin/tailscale-demo-app
      sudo install -D -o root -g root -m 0644 /tmp/tailscale-demo-app.service /etc/systemd/system/tailscale-demo-app.service
      sudo install -d -o root -g root -m 0755 /usr/local/share/tailscale-demo-app
      printf '%s\n' "$APP_VERSION" | sudo tee /usr/local/share/tailscale-demo-app/VERSION >/dev/null
      rm -f /tmp/tailscale-demo-app /tmp/tailscale-demo-app.service

      sudo systemctl daemon-reload
      sudo systemctl enable tailscale-demo-app.service
      sudo systemd-analyze verify /etc/systemd/system/tailscale-demo-app.service

      # This role demonstrates conventional SSH over the subnet route. Terraform
      # supplies a dedicated public key and permits TCP/22 only from the router
      # security group.
      sudo systemctl enable ssh.service
    SCRIPT
    ]
  }

  provisioner "shell" {
    environment_vars = ["INSTALL_TAILSCALE=${var.install_tailscale}"]
    inline_shebang   = "/bin/bash -e"
    inline = [<<-SCRIPT
      set -o pipefail

      if [[ "$INSTALL_TAILSCALE" == "true" ]]; then
        command -v tailscale
        test -x /usr/sbin/tailscaled
        systemctl is-enabled tailscaled.service
      else
        ! command -v tailscale
        ! test -e /usr/sbin/tailscaled
        ! systemctl is-enabled tailscaled.service
      fi
      systemctl is-enabled ssh.service
      systemctl is-enabled tailscale-demo-app.service
      test -x /usr/local/bin/tailscale-demo-app
      test -s /usr/local/share/tailscale-demo-app/VERSION
      systemd-analyze verify /etc/systemd/system/tailscale-demo-app.service
      ! test -e /tmp/tailscale-demo-app
      ! test -e /tmp/tailscale-demo-app.service
      ! test -e /var/lib/tailscale/tailscaled.state
    SCRIPT
    ]
  }
}
# Local development (macOS)
source "tart-cli" "app" {
  vm_base_name = "ghcr.io/cirruslabs/debian:latest"
  vm_name      = "tailscale-demo-app-local"
  headless     = true

  cpu_count    = 2
  memory_gb    = 2
  disk_size_gb = 20

  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "5m"
}

# Production (AWS EBS)
source "amazon-ebs" "app" {
  region                 = var.aws_region
  skip_region_validation = true
  ssh_username           = var.aws_ssh_username
  instance_type          = var.aws_instance_type

  source_ami_filter {
    filters = {
      architecture        = "arm64"
      name                = "debian-${var.debian_release}-arm64-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["136693071363"]
  }

  ami_name        = "tailscale-demo-app-${var.app_version}-{{timestamp}}"
  ami_description = "Debian application base image for the Tailscale FDE demo"
  encrypt_boot    = true

  tags = {
    Name         = "tailscale-demo-app"
    Role         = "app"
    Architecture = "arm64"
    ManagedBy    = "packer"
    AppVersion   = var.app_version
  }
}
