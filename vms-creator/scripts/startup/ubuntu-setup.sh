#!/bin/bash
set -euo pipefail

echo ">>> VM Creator - Ubuntu Setup Script"
echo ">>> Starting at $(date -u)"

export DEBIAN_FRONTEND=noninteractive

# ─── System update ───────────────────────────────────────────────────────────
apt-get update -y
apt-get upgrade -y

# ─── Common tools ────────────────────────────────────────────────────────────
apt-get install -y \
  git curl wget htop vim jq unzip tree \
  net-tools dnsutils iputils-ping traceroute \
  ca-certificates gnupg lsb-release software-properties-common \
  apt-transport-https build-essential

# ─── Docker ──────────────────────────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Add default user to docker group (ubuntu for most AMIs)
for user in ubuntu azureuser; do
  if id "$user" &>/dev/null; then
    usermod -aG docker "$user"
  fi
done

# ─── kubectl ─────────────────────────────────────────────────────────────────
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl

# ─── Helm ────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── MOTD ────────────────────────────────────────────────────────────────────
cat > /etc/motd << 'MOTD'

  ╔══════════════════════════════════════════════════════════════╗
  ║                   VM Creator Instance                       ║
  ║                                                              ║
  ║  Pre-installed: docker, kubectl, helm, git, jq, curl        ║
  ║                                                              ║
  ║  WARNING: This VM has open security groups for learning.     ║
  ║  Do NOT use this configuration in production.                ║
  ╚══════════════════════════════════════════════════════════════╝

MOTD

echo ">>> VM Creator - Ubuntu setup completed at $(date -u)"
