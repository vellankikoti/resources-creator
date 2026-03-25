#!/bin/bash
set -euo pipefail

echo ">>> VM Creator - Rocky Linux Setup Script"
echo ">>> Starting at $(date -u)"

# ─── System update ───────────────────────────────────────────────────────────
dnf update -y

# ─── Common tools ────────────────────────────────────────────────────────────
dnf install -y \
  git curl wget htop vim jq unzip tree \
  net-tools bind-utils iputils traceroute \
  ca-certificates gnupg2 tar

# ─── Docker ──────────────────────────────────────────────────────────────────
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Add default users to docker group
for user in rocky cloud-user ec2-user; do
  if id "$user" &>/dev/null; then
    usermod -aG docker "$user"
  fi
done

# ─── kubectl ─────────────────────────────────────────────────────────────────
cat > /etc/yum.repos.d/kubernetes.repo <<'REPO'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
REPO
dnf install -y kubectl

# ─── Helm ────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── MOTD ────────────────────────────────────────────────────────────────────
cat > /etc/motd << 'MOTD'

  ╔══════════════════════════════════════════════════════════════╗
  ║              VM Creator Instance (Rocky Linux)              ║
  ║                                                              ║
  ║  Pre-installed: docker, kubectl, helm, git, jq, curl        ║
  ║  Package manager: dnf / yum                                  ║
  ║                                                              ║
  ║  WARNING: This VM has open security groups for learning.     ║
  ║  Do NOT use this configuration in production.                ║
  ╚══════════════════════════════════════════════════════════════╝

MOTD

echo ">>> VM Creator - Rocky Linux setup completed at $(date -u)"
