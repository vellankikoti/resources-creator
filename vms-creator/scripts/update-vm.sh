#!/usr/bin/env bash
set -euo pipefail

# ─── Argument Parsing ─────────────────────────────────────────────────────────

CLOUD=""
NAME=""
ENV_NAME=""
REGION=""
COUNT=""
INSTANCE_TYPE=""
OS_TYPE="ubuntu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)         CLOUD="$2";         shift 2 ;;
    --name)          NAME="$2";          shift 2 ;;
    --env)           ENV_NAME="$2";      shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --count)         COUNT="$2";         shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --os)            OS_TYPE="$2";       shift 2 ;;
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

if [[ -z "$COUNT" && -z "$INSTANCE_TYPE" ]]; then
  echo "At least one of --count or --instance-type must be specified for update"
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
require_cmd jq

# ─── SSH Key (must exist from create) ─────────────────────────────────────────

SSH_KEY_NAME="vm-creator-${NAME}-${ENV_NAME}"
SSH_KEY_PATH="${HOME}/.ssh/${SSH_KEY_NAME}"
if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  echo "SSH key not found: ${SSH_KEY_PATH}.pub"
  echo "Run create-vm.sh first to create the VMs and SSH key."
  exit 1
fi
SSH_PUB_KEY="$(cat "${SSH_KEY_PATH}.pub")"

# ─── Naming + tfvars ─────────────────────────────────────────────────────────

TF_VARS_FILE="${TMP_DIR}/vars.tfvars"
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

    # Read current state for defaults
    pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
    prepare_aws_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$TF_BACKEND_FILE"
    terraform init -reconfigure -backend-config="$TF_BACKEND_FILE" >/dev/null

    CURRENT_COUNT="$(terraform output -json instance_ids 2>/dev/null | jq 'length' 2>/dev/null || echo 1)"
    popd >/dev/null

    EFFECTIVE_COUNT="${COUNT:-$CURRENT_COUNT}"

    cat > "$TF_VARS_FILE" <<TFVARS
region         = "${REGION}"
base_name      = "${BASE_NAME}"
environments   = ["${ENV_NAME}"]
instance_count = ${EFFECTIVE_COUNT}
os_type        = "${OS_TYPE}"
ssh_public_key = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "instance_type = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi
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

    pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
    prepare_gcp_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$PROJECT_ID" "$TF_BACKEND_FILE"
    terraform init -reconfigure -backend-config="$TF_BACKEND_FILE" >/dev/null

    CURRENT_COUNT="$(terraform output -json instance_names 2>/dev/null | jq 'length' 2>/dev/null || echo 1)"
    popd >/dev/null

    EFFECTIVE_COUNT="${COUNT:-$CURRENT_COUNT}"

    cat > "$TF_VARS_FILE" <<TFVARS
project_id     = "${PROJECT_ID}"
region         = "${REGION}"
base_name      = "${BASE_NAME}"
environments   = ["${ENV_NAME}"]
instance_count = ${EFFECTIVE_COUNT}
os_type        = "${OS_TYPE}"
ssh_public_key = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "machine_type = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi
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

    pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
    prepare_azure_backend "$VM_NAME" "$ENV_NAME" "$REGION" "$SUB_ID" "$TF_BACKEND_FILE"
    terraform init -reconfigure -backend-config="$TF_BACKEND_FILE" >/dev/null

    CURRENT_COUNT="$(terraform output -json vm_names 2>/dev/null | jq 'length' 2>/dev/null || echo 1)"
    popd >/dev/null

    EFFECTIVE_COUNT="${COUNT:-$CURRENT_COUNT}"

    cat > "$TF_VARS_FILE" <<TFVARS
subscription_id = "${SUB_ID}"
region          = "${REGION}"
base_name       = "${BASE_NAME}"
environments    = ["${ENV_NAME}"]
instance_count  = ${EFFECTIVE_COUNT}
os_type         = "${OS_TYPE}"
ssh_public_key  = "${SSH_PUB_KEY}"
TFVARS

    if [[ -n "$INSTANCE_TYPE" ]]; then
      echo "vm_size = \"${INSTANCE_TYPE}\"" >> "$TF_VARS_FILE"
    fi
    ;;
esac

# ─── Terraform Apply ──────────────────────────────────────────────────────────

echo ""
echo "Updating VMs: ${VM_NAME} in ${REGION} (${CLOUD})"
[[ -n "$COUNT" ]]         && echo "  New count: ${COUNT}"
[[ -n "$INSTANCE_TYPE" ]] && echo "  New instance type: ${INSTANCE_TYPE}"
echo ""

pushd "${ROOT_DIR}/terraform/${TF_STACK}" >/dev/null
terraform init -reconfigure -backend-config="$TF_BACKEND_FILE"
terraform apply -auto-approve -input=false -var-file="$TF_VARS_FILE"
popd >/dev/null

# ─── Display Results ──────────────────────────────────────────────────────────

display_ssh_info "${ROOT_DIR}/terraform/${TF_STACK}" "$SSH_KEY_PATH" "$CLOUD"
