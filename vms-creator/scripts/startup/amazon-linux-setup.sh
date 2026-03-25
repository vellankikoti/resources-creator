#!/bin/bash
set -euo pipefail

echo ">>> VM Creator - Amazon Linux Setup Script"
echo ">>> Starting at $(date -u)"

# ─── System update ───────────────────────────────────────────────────────────
dnf update -y

# ─── Common tools ────────────────────────────────────────────────────────────
dnf install -y \
  git curl wget htop vim jq unzip tree \
  net-tools bind-utils iputils traceroute \
  ca-certificates gnupg2

# ─── Docker ──────────────────────────────────────────────────────────────────
dnf install -y docker
systemctl enable docker
systemctl start docker

# Add ec2-user to docker group
if id "ec2-user" &>/dev/null; then
  usermod -aG docker ec2-user
fi

# ─── kubectl ─────────────────────────────────────────────────────────────────
curl -fsSLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

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

echo ">>> VM Creator - Amazon Linux setup completed at $(date -u)"
