# Usage
#
# Local build (macOS/tart):
#   packer build -only=router.tart-cli.router .

build {
  name = "router"
  sources = [
    "source.tart-cli.router",
  ]

  provisioner "shell" {
    script = "scripts/install-base.sh"
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-SCRIPT
      set -o pipefail

      # Tailscale is installed, but never enrolled, in this image. Each launched
      # instance receives its own tagged identity, route advertisement, and SSH
      # setting through cloud-init/Terraform.
      printf '%s\n' \
        'net.ipv4.ip_forward = 1' \
        'net.ipv6.conf.all.forwarding = 1' | \
        sudo tee /etc/sysctl.d/99-tailscale-subnet-router.conf >/dev/null
      sudo sysctl --system

      # The router role is accessed through Tailscale SSH at launch time. Disable
      # conventional OpenSSH for subsequent boots, but do not stop it while Packer
      # is still connected to the builder over SSH.
      sudo systemctl disable ssh.service
    SCRIPT
    ]
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-SCRIPT
      set -o pipefail

      command -v tailscale
      test -x /usr/sbin/tailscaled
      systemctl is-enabled tailscaled.service
      grep -qx 'net.ipv4.ip_forward = 1' /etc/sysctl.d/99-tailscale-subnet-router.conf
      grep -qx 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.d/99-tailscale-subnet-router.conf
      ! test -e /usr/local/bin/tailscale-demo-app
      ! systemctl is-enabled ssh.service
      ! test -e /var/lib/tailscale/tailscaled.state
    SCRIPT
    ]
  }
}

# Local development base (MacOS/tart)
source "tart-cli" "router" {
  vm_base_name = "ghcr.io/cirruslabs/debian:latest"
  vm_name      = "tailscale-demo-router-local"
  headless     = true

  cpu_count    = 2
  memory_gb    = 2
  disk_size_gb = 20

  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "5m"
}
