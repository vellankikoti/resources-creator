#!/usr/bin/env bash
set -euo pipefail

# ─── Argument Parsing ─────────────────────────────────────────────────────────

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)  CLOUD="$2";    shift 2 ;;
    --name)   NAME="$2";     shift 2 ;;
    --env)    ENV_NAME="$2"; shift 2 ;;
    --region) REGION="$2";   shift 2 ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$NAME" || -z "$ENV_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --name <name> --env dev|qa|staging|prod --region <region>"
  exit 1
fi

if [[ ! "$ENV_NAME" =~ ^(dev|qa|staging|prod)$ ]]; then
  echo "Invalid env: $ENV_NAME"
  exit 1
fi

if [[ ! "$CLOUD" =~ ^(aws|gcp|azure)$ ]]; then
  echo "Invalid cloud: $CLOUD"
  exit 1
fi

# ─── Setup ────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
LOCK_DIR="${ROOT_DIR}/scripts/.vm-factory.lock"
trap 'rm -rf "$TMP_DIR"; release_repo_lock "${LOCK_DIR}" 2>/dev/null || true' EXIT

source "${ROOT_DIR}/scripts/vm-lib.sh"
acquire_repo_lock "$LOCK_DIR"

require_cmd terraform

# ─── Naming ───────────────────────────────────────────────────────────────────

TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

case "$CLOUD" in
  aws)
    require_cmd aws
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    SUFFIX="${ACCOUNT_ID: -6}"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
      BASE_NAME="${VM_NAME%-${ENV_NAME}-vm}"
    else
      BASE_NAME="$(sanitize_name "${NAME}-aws-${SUFFIX}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="ec2"
    prepare_aws_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    ;;

  gcp)
    require_cmd gcloud
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "gcloud project is not set"; exit 1; }
    PROJ_HASH="$(hash8 "$PROJECT_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
      BASE_NAME="${VM_NAME%-${ENV_NAME}-vm}"
    else
      BASE_NAME="$(sanitize_name "${NAME}-gcp-${PROJ_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="gce"
    prepare_gcp_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    ;;

  azure)
    require_cmd az
    SUB_ID="$(az account show --query id -o tsv)"
    SUB_HASH="$(hash8 "$SUB_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
      BASE_NAME="${VM_NAME%-${ENV_NAME}-vm}"
    else
      BASE_NAME="$(sanitize_name "${NAME}-az-${SUB_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi
    TF_STACK="azure-vm"
    prepare_azure_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    ;;
esac

# ─── Terraform Destroy (with retries) ────────────────────────────────────────

echo ""
echo "Destroying VMs: ${VM_NAME} in ${REGION} (${CLOUD})"
echo ""

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE"

MAX_RETRIES=3
for attempt in $(seq 1 $MAX_RETRIES); do
  echo "Destroy attempt ${attempt}/${MAX_RETRIES}"
  if terraform destroy -auto-approve -input=false 2>&1; then
    echo ""
    echo "VMs destroyed successfully: ${VM_NAME}"
    popd >/dev/null
    exit 0
  fi

  if (( attempt < MAX_RETRIES )); then
    echo "Destroy failed, retrying in 30s..."
    sleep 30
  fi
done

popd >/dev/null
echo "Destroy failed after ${MAX_RETRIES} attempts"
exit 1
