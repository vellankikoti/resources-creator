#!/usr/bin/env bash
set -euo pipefail

# ─── String Utilities ─────────────────────────────────────────────────────────

sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

hash8() {
  if command -v shasum >/dev/null 2>&1; then
    echo -n "$1" | shasum | awk '{print substr($1,1,8)}'
  else
    echo -n "$1" | sha1sum | awk '{print substr($1,1,8)}'
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }
}

get_public_ip() {
  local ip
  ip="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null || true)"
  ip="${ip//$'\r'/}"
  ip="${ip//$'\n'/}"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"
    ip="${ip//$'\r'/}"
    ip="${ip//$'\n'/}"
  fi
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "unable to detect caller public IPv4"
    exit 1
  fi
  echo "$ip"
}

# ─── Locking ──────────────────────────────────────────────────────────────────

acquire_repo_lock() {
  local lock_dir="$1"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "another VM operation is running in this repository: $lock_dir"
    exit 1
  fi
}

release_repo_lock() {
  local lock_dir="$1"
  rm -rf "$lock_dir"
}

# ─── SSH Key Management ──────────────────────────────────────────────────────

generate_ssh_key() {
  local key_name="$1"
  local key_type="${2:-ed25519}"  # ed25519 for Linux, rsa for Windows (AWS requires RSA for Windows)
  local key_path="${HOME}/.ssh/${key_name}"

  if [[ -f "$key_path" ]]; then
    # Check if existing key type matches requested type
    local existing_type
    existing_type="$(head -1 "$key_path" 2>/dev/null)"
    if [[ "$key_type" == "rsa" && "$existing_type" != *"RSA"* ]] || \
       [[ "$key_type" == "ed25519" && "$existing_type" == *"RSA"* ]]; then
      echo "Regenerating SSH key (switching to $key_type): $key_path" >&2
      rm -f "$key_path" "${key_path}.pub"
    else
      echo "SSH key already exists: $key_path" >&2
      echo "$key_path"
      return
    fi
  fi

  mkdir -p "${HOME}/.ssh"
  if [[ "$key_type" == "rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -m PEM -f "$key_path" -N "" -C "vm-creator-${key_name}" >/dev/null 2>&1
  else
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "vm-creator-${key_name}" >/dev/null 2>&1
  fi
  chmod 600 "$key_path"
  chmod 644 "${key_path}.pub"
  echo "SSH key generated ($key_type): $key_path" >&2

  echo "$key_path"
}

# ─── Quota Checks ────────────────────────────────────────────────────────────

check_aws_quotas_vm() {
  local region="$1"
  local count="${2:-1}"

  local vcpu_quota
  vcpu_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  local vcpu_quota_int="${vcpu_quota%%.*}"
  if [[ -z "$vcpu_quota_int" || "$vcpu_quota_int" == "None" ]]; then
    echo "WARNING: unable to read AWS vCPU quota, skipping check"
    return 0
  fi
  local needed=$(( count * 2 ))
  if (( vcpu_quota_int < needed )); then
    echo "insufficient AWS vCPU quota in $region: have=$vcpu_quota_int need>=$needed"
    exit 1
  fi

  local eip_quota eip_used
  eip_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
  eip_used="$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)"
  local eip_quota_int="${eip_quota%%.*}"
  if (( eip_used + count > eip_quota_int )); then
    echo "insufficient AWS EIP quota in $region: used=$eip_used quota=$eip_quota_int need=$count"
    exit 1
  fi
}

check_gcp_quotas_vm() {
  local region="$1"
  local project_id="$2"
  local count="${3:-1}"

  gcloud services enable compute.googleapis.com --project "$project_id" >/dev/null 2>&1 || true

  local quota_csv
  quota_csv="$(gcloud compute regions describe "$region" --project "$project_id" --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null)"

  local cpus_limit cpus_usage
  cpus_limit="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $2; exit}')"
  cpus_usage="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $3; exit}')"
  if [[ -n "$cpus_limit" && -n "$cpus_usage" ]]; then
    local needed=$(( count * 2 ))
    if (( ${cpus_limit%%.*} - ${cpus_usage%%.*} < needed )); then
      echo "insufficient GCP CPU quota in $region: usage=$cpus_usage limit=$cpus_limit need=$needed"
      exit 1
    fi
  fi

  local ip_limit ip_usage
  ip_limit="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $2; exit}')"
  ip_usage="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $3; exit}')"
  if [[ -n "$ip_limit" && -n "$ip_usage" ]]; then
    if (( ${ip_limit%%.*} - ${ip_usage%%.*} < count )); then
      echo "insufficient GCP in-use addresses quota in $region: usage=$ip_usage limit=$ip_limit"
      exit 1
    fi
  fi
}

check_azure_quotas_vm() {
  local region="$1"
  local count="${2:-1}"

  az provider register -n Microsoft.Compute >/dev/null 2>&1 || true
  az provider register -n Microsoft.Network >/dev/null 2>&1 || true

  local cpu_limit cpu_usage
  cpu_limit="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].limit | [0]" -o tsv 2>/dev/null || true)"
  cpu_usage="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].currentValue | [0]" -o tsv 2>/dev/null || true)"

  if [[ -z "$cpu_limit" || -z "$cpu_usage" ]]; then
    echo "WARNING: unable to read Azure core quota for $region, skipping check."
  else
    local needed=$(( count * 2 ))
    if (( cpu_limit - cpu_usage < needed )); then
      echo "insufficient Azure core quota in $region: usage=$cpu_usage limit=$cpu_limit need=$needed"
      exit 1
    fi
  fi

  local pip_limit pip_usage
  pip_limit="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].limit | [0]" -o tsv 2>/dev/null || true)"
  pip_usage="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].currentValue | [0]" -o tsv 2>/dev/null || true)"

  if [[ -z "$pip_limit" || -z "$pip_usage" ]]; then
    echo "WARNING: unable to read Azure Public IP quota for $region, skipping check."
  else
    if (( pip_limit - pip_usage < count )); then
      echo "insufficient Azure Public IP quota in $region: usage=$pip_usage limit=$pip_limit need=$count"
      exit 1
    fi
  fi
}

# ─── Backend Preparation ─────────────────────────────────────────────────────

prepare_aws_backend() {
  local vm_name="$1"
  local env_name="$2"
  local region="$3"
  local backend_file="$4"

  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"

  local bucket="rc-tfstate-${account_id}-${region}"
  local table="rc-tf-locks"
  local key="aws-vm/${vm_name}/${env_name}/${region}/terraform.tfstate"

  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    if [[ "$region" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration LocationConstraint="$region" >/dev/null
    fi
  fi

  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null

  if ! aws dynamodb describe-table --table-name "$table" --region "$region" >/dev/null 2>&1; then
    aws dynamodb create-table \
      --table-name "$table" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$region" >/dev/null
    aws dynamodb wait table-exists --table-name "$table" --region "$region"
  fi

  cat > "$backend_file" <<HCL
bucket         = "${bucket}"
key            = "${key}"
region         = "${region}"
encrypt        = true
dynamodb_table = "${table}"
HCL
}

prepare_gcp_backend() {
  local vm_name="$1"
  local env_name="$2"
  local region="$3"
  local project_id="$4"
  local backend_file="$5"

  local bucket
  bucket="$(sanitize_name "rc-tfstate-${project_id}")"

  if ! gcloud storage buckets describe "gs://${bucket}" --project "$project_id" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${bucket}" --project "$project_id" --location "$region" --uniform-bucket-level-access >/dev/null
  fi

  gcloud storage buckets update "gs://${bucket}" --versioning >/dev/null

  local prefix="gcp-vm/${vm_name}/${env_name}/${region}"
  cat > "$backend_file" <<HCL
bucket = "${bucket}"
prefix = "${prefix}"
HCL
}

prepare_azure_backend() {
  local vm_name="$1"
  local env_name="$2"
  local region="$3"
  local subscription_id="$4"
  local backend_file="$5"

  local rg="$(sanitize_name "rc-tfstate-rg-${region}")"
  local sa="rctf$(hash8 "${subscription_id}-${region}")"
  local container="tfstate"
  local key="azure-vm/${vm_name}/${env_name}/${region}/terraform.tfstate"

  az group create --name "$rg" --location "$region" >/dev/null

  if ! az storage account show --name "$sa" --resource-group "$rg" >/dev/null 2>&1; then
    az storage account create \
      --name "$sa" \
      --resource-group "$rg" \
      --location "$region" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --allow-blob-public-access false \
      --min-tls-version TLS1_2 >/dev/null
  fi

  az storage container create --name "$container" --account-name "$sa" --auth-mode login >/dev/null

  cat > "$backend_file" <<HCL
resource_group_name  = "${rg}"
storage_account_name = "${sa}"
container_name       = "${container}"
key                  = "${key}"
HCL
}

# ─── Display Helpers ──────────────────────────────────────────────────────────

display_ssh_info() {
  local tf_dir="$1"
  local ssh_key_path="$2"
  local cloud="$3"

  pushd "$tf_dir" >/dev/null

  local ssh_user os_type
  ssh_user="$(terraform output -raw ssh_user 2>/dev/null || echo "ubuntu")"
  os_type="$(terraform output -raw os_type 2>/dev/null || echo "ubuntu")"

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  VM INSTANCES READY (${os_type})"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  local public_ips
  public_ips="$(terraform output -json public_ips 2>/dev/null)"

  if [[ -n "$public_ips" && "$public_ips" != "{}" ]]; then
    echo "$public_ips" | jq -r 'to_entries[] | "\(.key):\(.value)"' | while IFS=: read -r key ip; do
      ip="$(echo "$ip" | tr -d ' ')"
      echo "  Instance: $key"
      echo "    Public IP: $ip"

      if [[ "$os_type" == "windows" ]]; then
        echo "    RDP:       ${ip}:3389"
        echo "    User:      ${ssh_user}"

        case "$cloud" in
          aws)
            local instance_id
            instance_id="$(terraform output -json instance_ids 2>/dev/null | jq -r --arg k "$key" '.[$k] // empty')"
            if [[ -n "$instance_id" ]]; then
              echo "    Password:  (run after ~4 min) aws ec2 get-password-data --instance-id ${instance_id} --priv-launch-key ${ssh_key_path} --query PasswordData --output text | base64 -d | openssl pkeyutl -decrypt -inkey ${ssh_key_path}"
            fi
            ;;
          gcp)
            local instance_name zone
            instance_name="$(terraform output -json instance_names 2>/dev/null | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true)"
            zone="$(terraform output -raw zone 2>/dev/null || true)"
            if [[ -n "$instance_name" && -n "$zone" ]]; then
              echo "    Password:  gcloud compute reset-windows-password ${instance_name} --zone ${zone}"
            fi
            ;;
          azure)
            echo "    Password:  VMcreator2024!"
            ;;
        esac
      else
        echo "    SSH:       ssh -i ${ssh_key_path} ${ssh_user}@${ip}"
      fi
      echo ""
    done
  fi

  echo "═══════════════════════════════════════════════════════════════"
  if [[ "$os_type" == "windows" ]]; then
    echo "  Connect via: Remote Desktop (RDP) client to <ip>:3389"
    echo "  User:        ${ssh_user}"
  else
    echo "  SSH Key:     ${ssh_key_path}"
    echo "  User:        ${ssh_user}"
    echo "  Connect:     ssh -i ${ssh_key_path} ${ssh_user}@<ip>"
  fi
  echo ""
  echo "  WARNING: These VMs have OPEN security groups for learning."
  echo "  See README.md for production hardening guidance."
  echo "═══════════════════════════════════════════════════════════════"

  popd >/dev/null
}
