#!/usr/bin/env bash
set -euo pipefail

# ─── Argument Parsing ─────────────────────────────────────────────────────────

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""
COUNT="1"
INSTANCE_TYPE=""
OS_TYPE="ubuntu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)        CLOUD="$2";         shift 2 ;;
    --name)         NAME="$2";          shift 2 ;;
    --env)          ENV_NAME="$2";      shift 2 ;;
    --region)       REGION="$2";        shift 2 ;;
    --count)        COUNT="$2";         shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --os)           OS_TYPE="$2";       shift 2 ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CLOUD" || -z "$NAME" || -z "$ENV_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 --cloud aws|gcp|azure --name <name> --env dev|qa|staging|prod --region <region> [--count N] [--instance-type <type>] [--os ubuntu|rocky|windows]"
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

if [[ ! "$OS_TYPE" =~ ^(ubuntu|rocky|windows)$ ]]; then
  echo "Invalid os: $OS_TYPE (must be ubuntu, rocky, or windows)"
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
require_cmd jq

# ─── Preflight ────────────────────────────────────────────────────────────────

echo "Preflight check for cloud=$CLOUD region=$REGION os=$OS_TYPE"

case "$CLOUD" in
  aws)
    require_cmd aws
    aws sts get-caller-identity >/dev/null || { echo "AWS authentication failed"; exit 1; }
    ;;
  gcp)
    require_cmd gcloud
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
    [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "gcloud project is not set"; exit 1; }
    ;;
  azure)
    require_cmd az
    az account show >/dev/null 2>&1 || { echo "Azure authentication failed"; exit 1; }
    ;;
esac

echo "Preflight OK for cloud=$CLOUD region=$REGION os=$OS_TYPE"

# ─── SSH Key (Linux) / Password info (Windows) ───────────────────────────────

SSH_KEY_PATH=""
SSH_PUB_KEY=""

if [[ "$OS_TYPE" != "windows" ]]; then
  SSH_KEY_NAME="vm-creator-${NAME}-${ENV_NAME}"
  SSH_KEY_PATH="$(generate_ssh_key "$SSH_KEY_NAME")"
  SSH_PUB_KEY="$(cat "${SSH_KEY_PATH}.pub")"
else
  # Windows: generate RSA key (AWS doesn't support ED25519 for Windows)
  SSH_KEY_NAME="vm-creator-${NAME}-${ENV_NAME}"
  SSH_KEY_PATH="$(generate_ssh_key "$SSH_KEY_NAME" "rsa")"
  SSH_PUB_KEY="$(cat "${SSH_KEY_PATH}.pub")"
  echo ""
  echo "NOTE: Windows VMs use RDP (port 3389), not SSH."
  echo "  AWS: Password can be decrypted with the SSH key after ~4 minutes"
  echo "  GCP: Set password via: gcloud compute reset-windows-password <instance> --zone <zone>"
  echo "  Azure: Username=adminuser Password=VMcreator2024!"
  echo ""
fi

# ─── Cloud-specific naming + tfvars ──────────────────────────────────────────

TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
TF_BACKEND_FILE="${TMP_DIR}/backend.hcl"

case "$CLOUD" in
  aws)
    check_aws_quotas_vm "$REGION" "$COUNT"

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

    cat > "$TF_VARS_FILE" <<TFVARS
region         = "${REGION}"
base_name      = "${BASE_NAME}"
environments   = ["${ENV_NAME}"]
instance_count = ${COUNT}
os_type        = "${OS_TYPE}"
ssh_public_key = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "instance_type = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi

    prepare_aws_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    ;;

  gcp)
    check_gcp_quotas_vm "$REGION" "$PROJECT_ID" "$COUNT"

    PROJ_HASH="$(hash8 "$PROJECT_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
      BASE_NAME="${VM_NAME%-${ENV_NAME}-vm}"
    else
      BASE_NAME="$(sanitize_name "${NAME}-gcp-${PROJ_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi

    TF_STACK="gce"

    cat > "$TF_VARS_FILE" <<TFVARS
project_id     = "${PROJECT_ID}"
region         = "${REGION}"
base_name      = "${BASE_NAME}"
environments   = ["${ENV_NAME}"]
instance_count = ${COUNT}
os_type        = "${OS_TYPE}"
ssh_public_key = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "machine_type = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi

    prepare_gcp_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    ;;

  azure)
    SUB_ID="$(az account show --query id -o tsv)"
    check_azure_quotas_vm "$REGION" "$COUNT"

    SUB_HASH="$(hash8 "$SUB_ID")"
    if [[ "$NAME" == *"-${ENV_NAME}-vm" ]]; then
      VM_NAME="$(sanitize_name "$NAME")"
      BASE_NAME="${VM_NAME%-${ENV_NAME}-vm}"
    else
      BASE_NAME="$(sanitize_name "${NAME}-az-${SUB_HASH}")"
      VM_NAME="${BASE_NAME}-${ENV_NAME}-vm"
    fi

    TF_STACK="azure-vm"

    cat > "$TF_VARS_FILE" <<TFVARS
subscription_id = "${SUB_ID}"
region          = "${REGION}"
base_name       = "${BASE_NAME}"
environments    = ["${ENV_NAME}"]
instance_count  = ${COUNT}
os_type         = "${OS_TYPE}"
ssh_public_key  = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "vm_size = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi

    prepare_azure_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    ;;
esac

# ─── Terraform Apply ──────────────────────────────────────────────────────────

echo ""
echo "Creating ${COUNT} ${OS_TYPE} VM(s): ${VM_NAME} in ${REGION} (${CLOUD})"
echo ""

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE"
terraform apply -auto-approve -input=false -var-file="$TF_VARS_FILE"
popd >/dev/null

# ─── Display Results ──────────────────────────────────────────────────────────

display_ssh_info "${ROOT_DIR}/terraform/${TF_STACK}" "$SSH_KEY_PATH" "$CLOUD"

echo ""
echo "VM name:  ${VM_NAME}"
echo "Region:   ${REGION}"
echo "Cloud:    ${CLOUD}"
echo "OS:       ${OS_TYPE}"
echo "Count:    ${COUNT}"
if [[ "$OS_TYPE" != "windows" ]]; then
  echo "SSH key:  ${SSH_KEY_PATH}"
fi
echo ""
echo "To destroy: ./scripts/destroy-vm.sh --cloud ${CLOUD} --name ${NAME} --env ${ENV_NAME} --region ${REGION}"
