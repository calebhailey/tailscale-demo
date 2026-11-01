#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
     ca-certificates \
     curl \
     jq \
     openssh-server

if [[ "${INSTALL_AWSCLI:-false}" == "true" ]]; then
  sudo apt-get install --yes --no-install-recommends awscli
fi

if [[ "${INSTALL_TAILSCALE:-false}" == "true" ]]; then
  # Install but do not enroll Tailscale. A boot-time configuration script owns
  # enrollment so every EC2 instance receives a unique, short-lived identity.
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  sudo apt-get update
  sudo apt-get install --yes --no-install-recommends tailscale
  sudo systemctl enable tailscaled.service
fi

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
