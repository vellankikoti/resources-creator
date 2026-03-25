#!/usr/bin/env bash
set -euo pipefail

# ─── Argument Parsing ─────────────────────────────────────────────────────────

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""
INDEX="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)  CLOUD="$2";    shift 2 ;;
    --name)   NAME="$2";     shift 2 ;;
    --env)    ENV_NAME="$2"; shift 2 ;;
    --region) REGION="$2";   shift 2 ;;
    --index)  INDEX="$2";    shift 2 ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$NAME" || -z "$ENV_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --name <name> --env dev|qa|staging|prod --region <region> [--index N]"
  exit 1
fi

# ─── Setup ────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "${ROOT_DIR}/scripts/vm-lib.sh"

require_cmd terraform
require_cmd jq

# ─── SSH Key ──────────────────────────────────────────────────────────────────

SSH_KEY_NAME="vm-creator-${NAME}-${ENV_NAME}"
SSH_KEY_PATH="${HOME}/.ssh/${SSH_KEY_NAME}"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "SSH key not found: $SSH_KEY_PATH"
  echo "Run create-vm.sh first."
  exit 1
fi

# ─── Get IP from Terraform State ──────────────────────────────────────────────

TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

case "$CLOUD" in
  aws)
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    SUFFIX="${ACCOUNT_ID: -6}"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
    else
      BASE_NAME="$(sanitize_name "${NAME}-aws-${SUFFIX}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="ec2"
    prepare_aws_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    ;;
  gcp)
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    PROJ_HASH="$(hash8 "$PROJECT_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
    else
      BASE_NAME="$(sanitize_name "${NAME}-gcp-${PROJ_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="gce"
    prepare_gcp_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    ;;
  azure)
    SUB_ID="$(az account show --query id -o tsv)"
    SUB_HASH="$(hash8 "$SUB_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
    else
      BASE_NAME="$(sanitize_name "${NAME}-az-${SUB_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="azure-vm"
    prepare_azure_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    ;;
esac

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE" >/dev/null 2>&1

SSH_USER="$(terraform output -raw ssh_user 2>/dev/null || echo "ubuntu")"
OS_TYPE="$(terraform output -raw os_type 2>/dev/null || echo "ubuntu")"
TARGET_KEY="${ENV_NAME}-${INDEX}"
IP="$(terraform output -json public_ips | jq -r --arg k "$TARGET_KEY" '.[$k] // empty')"

popd >/dev/null

if [[ -z "$IP" ]]; then
  echo "No VM found at index $INDEX for environment $ENV_NAME"
  echo "Available instances:"
  pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
  terraform output -json public_ips | jq -r 'to_entries[] | "  \(.key): \(.value)"'
  popd >/dev/null
  exit 1
fi

if [[ "$OS_TYPE" == "windows" ]]; then
  echo "Windows VM at ${IP}:3389"
  echo "  User: ${SSH_USER}"
  echo ""
  echo "Cannot SSH into Windows VMs. Use an RDP client instead:"
  echo "  macOS:  open rdp://full%20address=s:${IP}"
  echo "  Linux:  xfreerdp /v:${IP} /u:${SSH_USER}"
  echo ""
  case "$CLOUD" in
    aws)
      pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
      INSTANCE_ID="$(terraform output -json instance_ids | jq -r --arg k "$TARGET_KEY" '.[$k] // empty')"
      popd >/dev/null
      echo "Get password: aws ec2 get-password-data --instance-id ${INSTANCE_ID} --priv-launch-key ${SSH_KEY_PATH} --query PasswordData --output text | base64 -d | openssl pkeyutl -decrypt -inkey ${SSH_KEY_PATH}"
      ;;
    gcp)
      pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
      INSTANCE_NAME="$(terraform output -json instance_names | jq -r --arg k "$TARGET_KEY" '.[$k] // empty')"
      ZONE="$(terraform output -raw zone 2>/dev/null || true)"
      popd >/dev/null
      echo "Get password: gcloud compute reset-windows-password ${INSTANCE_NAME} --zone ${ZONE}"
      ;;
    azure)
      echo "Password: VMcreator2024!"
      ;;
  esac
  exit 0
fi

echo "Connecting to ${VM_NAME} instance ${INDEX} at ${IP}..."
exec ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${IP}"
