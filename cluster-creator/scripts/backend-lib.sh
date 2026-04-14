#!/usr/bin/env bash
set -euo pipefail

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

acquire_repo_lock() {
  local lock_dir="$1"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "another cluster operation is running in this repository: $lock_dir"
    exit 1
  fi
}

release_repo_lock() {
  local lock_dir="$1"
  rm -rf "$lock_dir"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }
}

check_aws_quotas() {
  local region="$1"
  local required_vcpu="4"

  local vcpu_quota
  vcpu_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  local vcpu_quota_int="${vcpu_quota%%.*}"
  if [[ -z "$vcpu_quota_int" || "$vcpu_quota_int" == "None" ]]; then
    echo "unable to read AWS vCPU quota"
    exit 1
  fi
  if (( vcpu_quota_int < required_vcpu )); then
    echo "insufficient AWS vCPU quota in $region: have=$vcpu_quota_int need>=$required_vcpu"
    exit 1
  fi

  local eip_quota eip_used
  eip_quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
  eip_used="$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)"
  local eip_quota_int="${eip_quota%%.*}"
  if (( eip_used + 2 > eip_quota_int )); then
    echo "insufficient AWS EIP quota in $region: used=$eip_used quota=$eip_quota_int"
    exit 1
  fi

  local nlb_limit nlb_used
  nlb_limit="$(aws elbv2 describe-account-limits --region "$region" --query "Limits[?Name=='network-load-balancers'].Max|[0]" --output text 2>/dev/null || echo None)"
  nlb_used="$(aws elbv2 describe-load-balancers --region "$region" --query "length(LoadBalancers[?Type=='network'])" --output text 2>/dev/null || echo 0)"
  if [[ "$nlb_limit" != "None" && "$nlb_limit" =~ ^[0-9]+$ ]]; then
    if (( nlb_used + 2 > nlb_limit )); then
      echo "insufficient AWS NLB quota in $region: used=$nlb_used limit=$nlb_limit"
      exit 1
    fi
  fi
}

check_gcp_quotas_and_apis() {
  local region="$1"
  local project_id="$2"

  local services
  services=(container.googleapis.com compute.googleapis.com iam.googleapis.com logging.googleapis.com monitoring.googleapis.com)
  gcloud services enable "${services[@]}" --project "$project_id" >/dev/null

  local quota_csv
  quota_csv="$(gcloud compute regions describe "$region" --project "$project_id" --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null)"

  local cpus_limit cpus_usage
  cpus_limit="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $2; exit}')"
  cpus_usage="$(echo "$quota_csv" | awk -F, '$1=="CPUS" {print $3; exit}')"
  [[ -n "$cpus_limit" && -n "$cpus_usage" ]] || { echo "unable to read GCP CPU quota for region $region"; exit 1; }
  if (( ${cpus_limit%%.*} - ${cpus_usage%%.*} < 8 )); then
    echo "insufficient GCP CPU quota in $region: usage=$cpus_usage limit=$cpus_limit"
    exit 1
  fi

  local ip_limit ip_usage
  ip_limit="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $2; exit}')"
  ip_usage="$(echo "$quota_csv" | awk -F, '$1=="IN_USE_ADDRESSES" {print $3; exit}')"
  [[ -n "$ip_limit" && -n "$ip_usage" ]] || { echo "unable to read GCP IN_USE_ADDRESSES quota for region $region"; exit 1; }
  if (( ${ip_limit%%.*} - ${ip_usage%%.*} < 2 )); then
    echo "insufficient GCP in-use addresses quota in $region: usage=$ip_usage limit=$ip_limit"
    exit 1
  fi
}

check_azure_quotas() {
  local region="$1"

  # Ensure required providers are registered (non-blocking)
  az provider register -n Microsoft.Compute >/dev/null 2>&1 || true
  az provider register -n Microsoft.Network >/dev/null 2>&1 || true

  local cpu_limit cpu_usage
  cpu_limit="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].limit | [0]" -o tsv 2>/dev/null || true)"
  cpu_usage="$(az vm list-usage --location "$region" --query "[?name.value=='cores'].currentValue | [0]" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$cpu_limit" || -z "$cpu_usage" ]]; then
    echo "WARNING: unable to read Azure core quota for $region (resource provider might still be registering), skipping check."
  else
    if (( cpu_limit - cpu_usage < 2 )); then
      echo "insufficient Azure core quota in $region: usage=$cpu_usage limit=$cpu_limit"
      exit 1
    fi
  fi

  local pip_limit pip_usage
  pip_limit="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].limit | [0]" -o tsv 2>/dev/null || true)"
  pip_usage="$(az network list-usages --location "$region" --query "[?contains(name.value, 'PublicIPAddresses')].currentValue | [0]" -o tsv 2>/dev/null || true)"
  
  if [[ -z "$pip_limit" || -z "$pip_usage" ]]; then
    echo "WARNING: unable to read Azure Public IP quota for $region (resource provider might still be registering), skipping check."
  else
    if (( pip_limit - pip_usage < 2 )); then
      echo "insufficient Azure Public IP quota in $region: usage=$pip_usage limit=$pip_limit"
      exit 1
    fi
  fi
}

prepare_aws_backend() {
  local cluster_name="$1"
  local env_name="$2"
  local region="$3"
  local backend_file="$4"

  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"

  local bucket="rc-tfstate-${account_id}-${region}"
  local table="rc-tf-locks"
  local key="aws/${cluster_name}/${env_name}/${region}/terraform.tfstate"

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
  local cluster_name="$1"
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

  local prefix="gcp/${cluster_name}/${env_name}/${region}"
  cat > "$backend_file" <<HCL
bucket = "${bucket}"
prefix = "${prefix}"
HCL
}

prepare_azure_backend() {
  local cluster_name="$1"
  local env_name="$2"
  local region="$3"
  local subscription_id="$4"
  local backend_file="$5"

  local rg="$(sanitize_name "rc-tfstate-rg-${region}")"
  local sa="rctf$(hash8 "${subscription_id}-${region}")"
  local container="tfstate"
  local key="azure/${cluster_name}/${env_name}/${region}/terraform.tfstate"

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

kube_api_reachable() {
  kubectl --request-timeout=10s get --raw='/readyz' >/dev/null 2>&1
}

wait_for_kube_api() {
  local attempts="${1:-30}"
  local sleep_seconds="${2:-10}"
  local i
  for i in $(seq 1 "$attempts"); do
    if kube_api_reachable; then
      return 0
    fi
    # After several failed attempts, flush DNS cache in case of stale entries
    if (( i % 6 == 0 )); then
      echo "  API not yet reachable (attempt $i/$attempts), flushing DNS cache..."
      flush_dns_cache
    fi
    sleep "$sleep_seconds"
  done
  return 1
}


ensure_eks_public_api_access() {
  local cluster_name="$1"
  local region="$2"
  local cidr="$3"

  # Fetch current endpoint config to avoid unnecessary updates
  local current_config
  current_config="$(aws eks describe-cluster --name "$cluster_name" --region "$region" \
    --query 'cluster.resourcesVpcConfig.{public:endpointPublicAccess,cidrs:publicAccessCidrs}' --output json 2>/dev/null)"

  local already_public
  already_public="$(echo "$current_config" | jq -r '.public')"
  local current_cidrs
  current_cidrs="$(echo "$current_config" | jq -r '.cidrs[]' 2>/dev/null || true)"

  # If already public with 0.0.0.0/0 or the requested CIDR, skip the update entirely
  if [[ "$already_public" == "true" ]]; then
    if echo "$current_cidrs" | grep -qF '0.0.0.0/0'; then
      echo "Public endpoint already enabled with 0.0.0.0/0 — skipping update."
      return 0
    fi
    if echo "$current_cidrs" | grep -qF "$cidr"; then
      echo "Public endpoint already enabled with CIDR $cidr — skipping update."
      return 0
    fi
  fi

  # Merge caller CIDR with existing CIDRs rather than replacing them
  local merged_cidrs="$cidr"
  if [[ -n "$current_cidrs" ]]; then
    merged_cidrs="$(printf '%s\n%s' "$current_cidrs" "$cidr" | sort -u | paste -sd ',' -)"
  fi

  echo "Enabling public endpoint access with CIDRs: $merged_cidrs"
  aws eks update-cluster-config \
    --name "$cluster_name" \
    --region "$region" \
    --resources-vpc-config "endpointPrivateAccess=true,endpointPublicAccess=true,publicAccessCidrs=$merged_cidrs" >/dev/null

  aws eks wait cluster-active --name "$cluster_name" --region "$region"

  # Flush local DNS cache to pick up the new endpoint address
  flush_dns_cache
}

restore_eks_private_only() {
  local cluster_name="$1"
  local region="$2"

  # Check current state — don't disable if Terraform manages it as public
  local already_public
  already_public="$(aws eks describe-cluster --name "$cluster_name" --region "$region" \
    --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>/dev/null || echo "true")"
  local current_cidrs
  current_cidrs="$(aws eks describe-cluster --name "$cluster_name" --region "$region" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output json 2>/dev/null || echo '[]')"

  # If it has 0.0.0.0/0, it was intentionally configured public (by Terraform) — don't disable
  if echo "$current_cidrs" | grep -qF '0.0.0.0/0'; then
    echo "Cluster has 0.0.0.0/0 public access (Terraform-managed) — not disabling."
    return 0
  fi

  aws eks update-cluster-config \
    --name "$cluster_name" \
    --region "$region" \
    --resources-vpc-config endpointPrivateAccess=true,endpointPublicAccess=false >/dev/null

  aws eks wait cluster-active --name "$cluster_name" --region "$region"
}

flush_dns_cache() {
  # macOS
  if command -v dscacheutil >/dev/null 2>&1; then
    sudo dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
  fi
  # Linux systemd-resolved
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
  fi
}

wait_for_eks_active() {
  local cluster_name="$1"
  local region="$2"
  aws eks wait cluster-active --name "$cluster_name" --region "$region"
}

resolve_kube_context() {
  local cluster_name="$1"
  local exact=""
  local fuzzy=""

  exact="$(kubectl config get-contexts -o name 2>/dev/null | awk -v c="$cluster_name" '$0==c {print; exit}')"
  if [[ -n "$exact" ]]; then
    echo "$exact"
    return 0
  fi

  fuzzy="$(kubectl config get-contexts -o name 2>/dev/null | awk -v c="$cluster_name" 'index($0,c)>0 {print; exit}')"
  if [[ -n "$fuzzy" ]]; then
    echo "$fuzzy"
    return 0
  fi

  return 1
}

delete_kubernetes_lb_resources() {
  local cluster_name="$1"
  local region="$2"

  echo "Attempting to delete Kubernetes LoadBalancer services and Ingresses for cluster: ${cluster_name}..."
  
  # Update kubeconfig to ensure we can talk to the cluster if it's still alive or deleting
  local status
  status="$(aws eks describe-cluster --name "$cluster_name" --region "$region" --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")"
  
  if [[ "$status" == "ACTIVE" || "$status" == "DELETING" ]]; then
    aws eks update-kubeconfig --name "$cluster_name" --region "$region" >/dev/null 2>&1 || true
    local context
    context="$(resolve_kube_context "$cluster_name" || true)"
    if [[ -n "$context" ]]; then
      echo "Deleting Services of type LoadBalancer..."
      kubectl --context "$context" get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | [.metadata.namespace, .metadata.name] | @tsv' | while read -r ns name; do
        kubectl --context "$context" delete svc "$name" -n "$ns" --timeout=30s --wait=false || true
      done

      echo "Deleting Ingresses..."
      kubectl --context "$context" delete ingress -A --all --timeout=30s --wait=false || true
      
      # Wait a bit for controllers to clean up
      sleep 10
    fi
  else
    echo "Cluster status is ${status}, skipping Kubernetes-level cleanup."
  fi
}

cleanup_eks_addons_cli() {
  local cluster_name="$1"
  local region="$2"

  echo "Proactively deleting EKS addons via CLI for cluster: ${cluster_name}..."
  
  local addons
  addons="$(aws eks list-addons --cluster-name "$cluster_name" --region "$region" --query 'addons' --output text 2>/dev/null || true)"
  
  for addon in $addons; do
    echo "Deleting EKS addon: ${addon}"
    aws eks delete-addon --cluster-name "$cluster_name" --addon-name "$addon" --region "$region" --preserve=false >/dev/null 2>&1 || true
  done

  if [[ -n "$addons" ]]; then
    echo "Waiting for addons to initiate deletion..."
    sleep 10
  fi
}

cleanup_eks_nodegroups_cli() {
  local cluster_name="$1"
  local region="$2"

  echo "Deleting EKS node groups via CLI for cluster: ${cluster_name}..."
  local nodegroups
  nodegroups="$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$region" \
    --query 'nodegroups' --output text 2>/dev/null || true)"

  for ng in $nodegroups; do
    echo "Deleting node group: ${ng}"
    aws eks delete-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$region" >/dev/null 2>&1 || true
  done

  if [[ -n "$nodegroups" ]]; then
    echo "Waiting for node groups to be deleted (this can take 5-10 minutes)..."
    for ng in $nodegroups; do
      local i
      for i in {1..40}; do
        local ng_status
        ng_status="$(aws eks describe-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$region" \
          --query 'nodegroup.status' --output text 2>/dev/null || echo "GONE")"
        if [[ "$ng_status" == "GONE" ]]; then
          echo "Node group ${ng} deleted."
          break
        fi
        echo "Node group ${ng} status: ${ng_status} (Attempt $i/40)..."
        sleep 15
      done
    done
  fi
}

cleanup_eks_aws_resources() {
  local cluster_name="$1"
  local region="$2"

  echo "Starting NUCLEAR cleanup of AWS resources for cluster: ${cluster_name} in ${region}..."

  # 1. Find VPC ID — try multiple tag patterns
  local vpc_id base_pattern
  base_pattern="${cluster_name%-[a-z]*-eks}"
  vpc_id="$(aws ec2 describe-vpcs --region "$region" \
    --filters "Name=tag:Name,Values=*${base_pattern}*" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")"

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    vpc_id="$(aws ec2 describe-vpcs --region "$region" \
      --filters "Name=tag:kubernetes.io/cluster/${cluster_name},Values=shared,owned" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")"
  fi

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "Could not resolve VPC ID for cleanup, skipping AWS CLI force cleanup."
    return 0
  fi
  echo "Target VPC for cleanup: ${vpc_id}"

  # 2. Delete EKS node groups via CLI (they hold ENIs in subnets)
  cleanup_eks_nodegroups_cli "$cluster_name" "$region" || true

  # 3. Cleanup NAT Gateways — capture EIP allocations BEFORE deletion
  echo "Checking for NAT Gateways..."
  local nat_gw_ids nat_eip_allocs
  nat_gw_ids="$(aws ec2 describe-nat-gateways --region "$region" \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)"

  nat_eip_allocs=""
  for ngw in $nat_gw_ids; do
    local eips
    eips="$(aws ec2 describe-nat-gateways --region "$region" --nat-gateway-ids "$ngw" \
      --query 'NatGateways[0].NatGatewayAddresses[*].AllocationId' --output text 2>/dev/null || true)"
    nat_eip_allocs="${nat_eip_allocs} ${eips}"
    echo "Deleting NAT Gateway: ${ngw} (EIPs: ${eips:-none})"
    aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$ngw" || true
  done

  # Also collect EIP allocs from NAT GWs already in "deleting" state (from prior failed runs)
  local deleting_ngw_eips
  deleting_ngw_eips="$(aws ec2 describe-nat-gateways --region "$region" \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query 'NatGateways[?State==`deleting`].NatGatewayAddresses[*].AllocationId' --output text 2>/dev/null || true)"
  nat_eip_allocs="${nat_eip_allocs} ${deleting_ngw_eips}"

  if [[ -n "$nat_gw_ids" ]]; then
    echo "Waiting for NAT Gateways to reach DELETED state..."
    local i
    for i in {1..30}; do
      local remaining
      remaining="$(aws ec2 describe-nat-gateways --region "$region" \
        --filter "Name=vpc-id,Values=${vpc_id}" \
        --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)"
      if [[ -z "$remaining" ]]; then
        echo "All NAT Gateways deleted."
        break
      fi
      echo "Still waiting for NAT Gateways: ${remaining} (Attempt $i/30)..."
      sleep 20
    done
  fi

  # Release NAT GW EIPs
  for alloc in $nat_eip_allocs; do
    [[ -z "$alloc" || "$alloc" == "None" ]] && continue
    echo "Releasing NAT Gateway EIP allocation: ${alloc}"
    aws ec2 release-address --region "$region" --allocation-id "$alloc" 2>/dev/null || true
  done

  # 4. Cleanup Load Balancers (ELB v2 - NLB/ALB)
  echo "Checking for orphaned ELB v2..."
  local elbv2_arns
  elbv2_arns="$(aws elbv2 describe-load-balancers --region "$region" \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text)"
  for arn in $elbv2_arns; do
    echo "Deleting ELB v2: ${arn}"
    aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$arn" || true
  done

  # 5. Cleanup Classic Load Balancers
  echo "Checking for orphaned Classic ELBs..."
  local elb_names
  elb_names="$(aws elb describe-load-balancers --region "$region" \
    --query "LoadBalancerDescriptions[?VpcId=='${vpc_id}'].LoadBalancerName" --output text)"
  for name in $elb_names; do
    echo "Deleting Classic ELB: ${name}"
    aws elb delete-load-balancer --region "$region" --load-balancer-name "$name" || true
  done

  if [[ -n "$elbv2_arns" || -n "$elb_names" ]]; then
    echo "Waiting for load balancers to be deleted..."
    sleep 30
  fi

  # 6. Cleanup Target Groups
  echo "Checking for orphaned Target Groups..."
  local tg_arns
  tg_arns="$(aws elbv2 describe-target-groups --region "$region" \
    --query "TargetGroups[?VpcId=='${vpc_id}'].TargetGroupArn" --output text)"
  for arn in $tg_arns; do
    echo "Deleting Target Group: ${arn}"
    aws elbv2 delete-target-group --region "$region" --target-group-arn "$arn" || true
  done

  # 7. Cleanup VPC Endpoints
  echo "Checking for VPC Endpoints..."
  local vpce_ids
  vpce_ids="$(aws ec2 describe-vpc-endpoints --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'VpcEndpoints[*].VpcEndpointId' --output text)"
  for vpce in $vpce_ids; do
    echo "Deleting VPC Endpoint: ${vpce}"
    aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$vpce" || true
  done

  # 8. Cleanup Transit Gateway Attachments
  echo "Checking for Transit Gateway Attachments..."
  local tgw_attachments
  tgw_attachments="$(aws ec2 describe-transit-gateway-vpc-attachments --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'TransitGatewayVpcAttachments[*].TransitGatewayAttachmentId' --output text 2>/dev/null || true)"
  for tgw_att in $tgw_attachments; do
    echo "Deleting Transit Gateway Attachment: ${tgw_att}"
    aws ec2 delete-transit-gateway-vpc-attachment --region "$region" --transit-gateway-attachment-id "$tgw_att" || true
  done

  # 9. Cleanup VPC Peering Connections
  echo "Checking for VPC Peering Connections..."
  local peer_ids
  peer_ids="$(aws ec2 describe-vpc-peering-connections --region "$region" \
    --filters "Name=requester-vpc-info.vpc-id,Values=${vpc_id}" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text)"
  peer_ids+=" $(aws ec2 describe-vpc-peering-connections --region "$region" \
    --filters "Name=accepter-vpc-info.vpc-id,Values=${vpc_id}" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text)"
  for peer in $peer_ids; do
    if [[ -n "$peer" && "$peer" != "None" ]]; then
      echo "Deleting VPC Peering Connection: ${peer}"
      aws ec2 delete-vpc-peering-connection --region "$region" --vpc-peering-connection-id "$peer" || true
    fi
  done

  # 10. Cleanup Security Groups (must go before ENIs to break SG→ENI dependency cycles)
  echo "Checking for orphaned Security Groups..."
  local sg_ids
  sg_ids="$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  for sg in $sg_ids; do
    echo "Stripping rules from SG: ${sg}"
    aws ec2 revoke-security-group-ingress --region "$region" --group-id "$sg" \
      --ip-permissions "$(aws ec2 describe-security-groups --region "$region" --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissions' --output json)" >/dev/null 2>&1 || true
    aws ec2 revoke-security-group-egress --region "$region" --group-id "$sg" \
      --ip-permissions "$(aws ec2 describe-security-groups --region "$region" --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json)" >/dev/null 2>&1 || true
  done
  for sg in $sg_ids; do
    echo "Deleting SG: ${sg}"
    aws ec2 delete-security-group --region "$region" --group-id "$sg" 2>/dev/null || true
  done

  # 11. Cleanup ENIs with retry loop — EKS-managed ENIs can take 60s+ to release
  echo "Performing ENI sweep for VPC: ${vpc_id} (with retries)..."
  local eni_retry
  for eni_retry in {1..6}; do
    local eni_ids
    eni_ids="$(aws ec2 describe-network-interfaces --region "$region" \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text)"

    if [[ -z "$eni_ids" ]]; then
      echo "All ENIs cleaned up."
      break
    fi

    echo "ENI sweep attempt ${eni_retry}/6 — found ENIs: ${eni_ids}"
    for eni in $eni_ids; do
      local eni_status
      eni_status="$(aws ec2 describe-network-interfaces --region "$region" \
        --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].Status' --output text 2>/dev/null || echo "GONE")"
      [[ "$eni_status" == "GONE" ]] && continue

      if [[ "$eni_status" == "in-use" ]]; then
        local attachment_id
        attachment_id="$(aws ec2 describe-network-interfaces --region "$region" \
          --network-interface-ids "$eni" \
          --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "None")"
        if [[ -n "$attachment_id" && "$attachment_id" != "None" ]]; then
          echo "Force-detaching ENI: ${eni} (attachment: ${attachment_id})"
          aws ec2 detach-network-interface --region "$region" --attachment-id "$attachment_id" --force 2>/dev/null || true
        fi
      else
        echo "Deleting available ENI: ${eni}"
        aws ec2 delete-network-interface --region "$region" --network-interface-id "$eni" 2>/dev/null || true
      fi
    done

    if [[ "$eni_retry" -lt 6 ]]; then
      echo "Waiting 15s for ENIs to finish detaching..."
      sleep 15
    fi
  done

  # Final pass: delete any ENIs that are now available after detach
  local leftover_enis
  leftover_enis="$(aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text)"
  for eni in $leftover_enis; do
    echo "Deleting leftover ENI: ${eni}"
    aws ec2 delete-network-interface --region "$region" --network-interface-id "$eni" 2>/dev/null || true
  done

  # 12. Release ALL Elastic IPs associated with this VPC (final sweep)
  # This catches EIPs on ENIs, orphaned NAT GW EIPs from prior runs, etc.
  echo "Final EIP sweep for VPC ${vpc_id}..."
  local all_eips_json
  all_eips_json="$(aws ec2 describe-addresses --region "$region" \
    --query 'Addresses[*].{AllocationId:AllocationId,AssociationId:AssociationId,NetworkInterfaceId:NetworkInterfaceId,Tags:Tags}' \
    --output json 2>/dev/null || echo "[]")"

  local eip_count
  eip_count="$(echo "$all_eips_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

  local idx
  for idx in $(seq 0 $(( eip_count - 1 ))); do
    local alloc assoc_id eni_id tags_json
    alloc="$(echo "$all_eips_json" | python3 -c "import sys,json; d=json.load(sys.stdin)[$idx]; print(d.get('AllocationId',''))" 2>/dev/null)"
    assoc_id="$(echo "$all_eips_json" | python3 -c "import sys,json; d=json.load(sys.stdin)[$idx]; print(d.get('AssociationId') or '')" 2>/dev/null)"
    eni_id="$(echo "$all_eips_json" | python3 -c "import sys,json; d=json.load(sys.stdin)[$idx]; print(d.get('NetworkInterfaceId') or '')" 2>/dev/null)"
    tags_json="$(echo "$all_eips_json" | python3 -c "import sys,json; d=json.load(sys.stdin)[$idx]; print(' '.join(t.get('Value','') for t in (d.get('Tags') or [])))" 2>/dev/null)"

    [[ -z "$alloc" ]] && continue

    local should_release="false"

    if [[ -n "$eni_id" ]]; then
      # EIP attached to an ENI — check if ENI is in our VPC
      local eni_vpc
      eni_vpc="$(aws ec2 describe-network-interfaces --region "$region" \
        --network-interface-ids "$eni_id" \
        --query 'NetworkInterfaces[0].VpcId' --output text 2>/dev/null || echo "None")"
      if [[ "$eni_vpc" == "$vpc_id" ]]; then
        should_release="true"
        if [[ -n "$assoc_id" ]]; then
          echo "Disassociating EIP ${alloc} from ENI ${eni_id}"
          aws ec2 disassociate-address --region "$region" --association-id "$assoc_id" 2>/dev/null || true
          sleep 2
        fi
      fi
    else
      # Unassociated EIP — check tags for VPC ID, cluster name, or base name
      if echo "$tags_json" | grep -qiE "${vpc_id}|${cluster_name}|${base_pattern}"; then
        should_release="true"
      fi
    fi

    if [[ "$should_release" == "true" ]]; then
      echo "Releasing EIP: ${alloc}"
      aws ec2 release-address --region "$region" --allocation-id "$alloc" 2>/dev/null || true
    fi
  done

  # 13. Cleanup custom route table associations (prevents subnet deletion failures)
  echo "Cleaning up route table associations..."
  local rt_ids
  rt_ids="$(aws ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[*].RouteTableId' --output text)"
  for rt in $rt_ids; do
    local assoc_ids
    assoc_ids="$(aws ec2 describe-route-tables --region "$region" \
      --route-table-ids "$rt" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text)"
    for assoc in $assoc_ids; do
      [[ -z "$assoc" || "$assoc" == "None" ]] && continue
      echo "Disassociating route table ${rt} association ${assoc}"
      aws ec2 disassociate-route-table --region "$region" --association-id "$assoc" 2>/dev/null || true
    done
  done

  # Delete non-main route tables
  for rt in $rt_ids; do
    local is_main
    is_main="$(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rt" \
      --query 'RouteTables[0].Associations[?Main==`true`] | length(@)' --output text 2>/dev/null || echo "0")"
    if [[ "$is_main" == "0" ]]; then
      echo "Deleting route table: ${rt}"
      aws ec2 delete-route-table --region "$region" --route-table-id "$rt" 2>/dev/null || true
    fi
  done

  # 14. Retry SG deletion now that ENIs are gone
  sg_ids="$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  for sg in $sg_ids; do
    echo "Retrying SG deletion: ${sg}"
    aws ec2 delete-security-group --region "$region" --group-id "$sg" 2>/dev/null || true
  done

  echo "AWS resource cleanup complete for VPC: ${vpc_id}"
}

delete_kubernetes_lb_resources_aks() {
  local cluster_name="$1"
  local region="$2"
  local rg="rg-${cluster_name}"

  echo "Attempting to delete Kubernetes LoadBalancer services for AKS cluster: ${cluster_name}..."

  # Get kubeconfig if cluster is still running
  local cluster_status
  cluster_status="$(az aks show --name "$cluster_name" --resource-group "$rg" --query 'provisioningState' -o tsv 2>/dev/null || echo "UNKNOWN")"

  if [[ "$cluster_status" == "Succeeded" || "$cluster_status" == "Deleting" ]]; then
    az aks get-credentials --name "$cluster_name" --resource-group "$rg" --overwrite-existing >/dev/null 2>&1 || true
    local context
    context="$(resolve_kube_context "$cluster_name" || true)"
    if [[ -n "$context" ]]; then
      echo "Deleting Services of type LoadBalancer..."
      kubectl --context "$context" get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | [.metadata.namespace, .metadata.name] | @tsv' | while read -r ns name; do
        kubectl --context "$context" delete svc "$name" -n "$ns" --timeout=30s --wait=false || true
      done
      echo "Deleting Ingresses..."
      kubectl --context "$context" delete ingress -A --all --timeout=30s --wait=false || true
      sleep 15
    fi
  else
    echo "Cluster status is ${cluster_status}, skipping Kubernetes-level cleanup."
  fi
}

cleanup_aks_azure_resources() {
  local cluster_name="$1"
  local region="$2"
  local rg="rg-${cluster_name}"

  echo "Starting cleanup of Azure resources for AKS cluster: ${cluster_name}..."

  # The MC_ (managed cluster) resource group holds the actual infra
  local mc_rg
  mc_rg="$(az aks show --name "$cluster_name" --resource-group "$rg" --query 'nodeResourceGroup' -o tsv 2>/dev/null || true)"

  # 1. Delete load balancers in MC_ resource group
  if [[ -n "$mc_rg" ]]; then
    echo "Cleaning up MC resource group: ${mc_rg}..."
    local lb_ids
    lb_ids="$(az network lb list -g "$mc_rg" --query '[].id' -o tsv 2>/dev/null || true)"
    for lb_id in $lb_ids; do
      echo "Deleting load balancer: ${lb_id}"
      az network lb delete --ids "$lb_id" 2>/dev/null || true
    done

    # Delete public IPs in MC_ resource group
    local pip_ids
    pip_ids="$(az network public-ip list -g "$mc_rg" --query '[].id' -o tsv 2>/dev/null || true)"
    for pip_id in $pip_ids; do
      echo "Deleting public IP: ${pip_id}"
      az network public-ip delete --ids "$pip_id" 2>/dev/null || true
    done
  fi

  # 2. Delete load balancers in the main resource group
  local lb_ids
  lb_ids="$(az network lb list -g "$rg" --query '[].id' -o tsv 2>/dev/null || true)"
  for lb_id in $lb_ids; do
    echo "Deleting load balancer: ${lb_id}"
    az network lb delete --ids "$lb_id" 2>/dev/null || true
  done

  # 3. Delete public IPs in the main resource group
  local pip_ids
  pip_ids="$(az network public-ip list -g "$rg" --query '[].id' -o tsv 2>/dev/null || true)"
  for pip_id in $pip_ids; do
    echo "Deleting public IP: ${pip_id}"
    az network public-ip delete --ids "$pip_id" 2>/dev/null || true
  done

  # 4. Delete NSGs (Network Security Groups) that block subnet deletion
  local nsg_ids
  nsg_ids="$(az network nsg list -g "$rg" --query '[].id' -o tsv 2>/dev/null || true)"
  for nsg_id in $nsg_ids; do
    echo "Deleting NSG: ${nsg_id}"
    az network nsg delete --ids "$nsg_id" 2>/dev/null || true
  done

  # 5. Delete NICs that block subnet deletion
  local nic_ids
  nic_ids="$(az network nic list -g "$rg" --query '[].id' -o tsv 2>/dev/null || true)"
  for nic_id in $nic_ids; do
    echo "Deleting NIC: ${nic_id}"
    az network nic delete --ids "$nic_id" 2>/dev/null || true
  done

  echo "Azure resource cleanup complete for cluster: ${cluster_name}"
}

delete_kubernetes_lb_resources_gke() {
  local cluster_name="$1"
  local region="$2"

  echo "Attempting to delete Kubernetes LoadBalancer services for GKE cluster: ${cluster_name}..."

  local cluster_status
  cluster_status="$(gcloud container clusters describe "$cluster_name" --region "$region" \
    --format='value(status)' 2>/dev/null || echo "UNKNOWN")"

  if [[ "$cluster_status" == "RUNNING" || "$cluster_status" == "RECONCILING" ]]; then
    gcloud container clusters get-credentials "$cluster_name" --region "$region" >/dev/null 2>&1 || true
    local context
    context="$(resolve_kube_context "$cluster_name" || true)"
    if [[ -n "$context" ]]; then
      echo "Deleting Services of type LoadBalancer..."
      kubectl --context "$context" get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | [.metadata.namespace, .metadata.name] | @tsv' | while read -r ns name; do
        kubectl --context "$context" delete svc "$name" -n "$ns" --timeout=30s --wait=false || true
      done
      echo "Deleting Ingresses..."
      kubectl --context "$context" delete ingress -A --all --timeout=30s --wait=false || true
      sleep 15
    fi
  else
    echo "Cluster status is ${cluster_status}, skipping Kubernetes-level cleanup."
  fi
}

cleanup_gke_gcp_resources() {
  local cluster_name="$1"
  local region="$2"

  echo "Starting cleanup of GCP resources for GKE cluster: ${cluster_name}..."

  local project_id
  project_id="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
  if [[ -z "$project_id" || "$project_id" == "(unset)" ]]; then
    echo "gcloud project not set, skipping GCP cleanup."
    return 0
  fi

  # Derive VPC name from cluster name: base_name-env-gke-vpc
  local base_env="${cluster_name%-gke}"
  local vpc_name="${cluster_name}-vpc"

  # Verify VPC exists
  local vpc_self_link
  vpc_self_link="$(gcloud compute networks describe "$vpc_name" --project "$project_id" \
    --format='value(selfLink)' 2>/dev/null || true)"

  if [[ -z "$vpc_self_link" ]]; then
    echo "VPC ${vpc_name} not found, skipping GCP resource cleanup."
    return 0
  fi
  echo "Target VPC for cleanup: ${vpc_name}"

  # 1. Disable deletion protection on the GKE cluster (required for prod clusters)
  echo "Disabling deletion protection on cluster ${cluster_name}..."
  gcloud container clusters update "$cluster_name" --region "$region" --project "$project_id" \
    --no-deletion-protection --quiet 2>/dev/null || true

  # 2. Delete forwarding rules (load balancer frontends) in the VPC
  echo "Checking for forwarding rules..."
  local fwd_rules
  fwd_rules="$(gcloud compute forwarding-rules list --project "$project_id" \
    --filter="network:${vpc_name} OR network:${vpc_self_link}" \
    --format='csv[no-heading](name,region.basename())' 2>/dev/null || true)"
  while IFS=, read -r fr_name fr_region; do
    [[ -z "$fr_name" ]] && continue
    if [[ -n "$fr_region" ]]; then
      echo "Deleting regional forwarding rule: ${fr_name}"
      gcloud compute forwarding-rules delete "$fr_name" --region "$fr_region" --project "$project_id" --quiet 2>/dev/null || true
    else
      echo "Deleting global forwarding rule: ${fr_name}"
      gcloud compute forwarding-rules delete "$fr_name" --global --project "$project_id" --quiet 2>/dev/null || true
    fi
  done <<< "$fwd_rules"

  # 3. Delete target pools
  echo "Checking for target pools..."
  local target_pools
  target_pools="$(gcloud compute target-pools list --project "$project_id" \
    --filter="region:${region}" \
    --format='value(name)' 2>/dev/null || true)"
  for tp in $target_pools; do
    echo "Deleting target pool: ${tp}"
    gcloud compute target-pools delete "$tp" --region "$region" --project "$project_id" --quiet 2>/dev/null || true
  done

  # 4. Delete backend services
  echo "Checking for backend services..."
  local backend_svcs
  backend_svcs="$(gcloud compute backend-services list --project "$project_id" \
    --filter="network:${vpc_name} OR network:${vpc_self_link}" \
    --format='csv[no-heading](name,region.basename())' 2>/dev/null || true)"
  while IFS=, read -r bs_name bs_region; do
    [[ -z "$bs_name" ]] && continue
    if [[ -n "$bs_region" ]]; then
      echo "Deleting regional backend service: ${bs_name}"
      gcloud compute backend-services delete "$bs_name" --region "$bs_region" --project "$project_id" --quiet 2>/dev/null || true
    else
      echo "Deleting global backend service: ${bs_name}"
      gcloud compute backend-services delete "$bs_name" --global --project "$project_id" --quiet 2>/dev/null || true
    fi
  done <<< "$backend_svcs"

  # 5. Delete health checks associated with the cluster
  echo "Checking for health checks..."
  local health_checks
  health_checks="$(gcloud compute health-checks list --project "$project_id" \
    --filter="name~${base_env}" \
    --format='value(name)' 2>/dev/null || true)"
  for hc in $health_checks; do
    echo "Deleting health check: ${hc}"
    gcloud compute health-checks delete "$hc" --project "$project_id" --quiet 2>/dev/null || true
  done

  # 6. Delete firewall rules for the VPC
  echo "Checking for firewall rules..."
  local fw_rules
  fw_rules="$(gcloud compute firewall-rules list --project "$project_id" \
    --filter="network:${vpc_name} OR network:${vpc_self_link}" \
    --format='value(name)' 2>/dev/null || true)"
  for fw in $fw_rules; do
    echo "Deleting firewall rule: ${fw}"
    gcloud compute firewall-rules delete "$fw" --project "$project_id" --quiet 2>/dev/null || true
  done

  # 7. Delete Cloud NAT and router
  local router_name="${base_env}-router"
  echo "Deleting Cloud NAT and router: ${router_name}..."
  local nats
  nats="$(gcloud compute routers nats list --router "$router_name" --region "$region" --project "$project_id" \
    --format='value(name)' 2>/dev/null || true)"
  for nat_name in $nats; do
    echo "Deleting Cloud NAT: ${nat_name}"
    gcloud compute routers nats delete "$nat_name" --router "$router_name" --region "$region" \
      --project "$project_id" --quiet 2>/dev/null || true
  done
  gcloud compute routers delete "$router_name" --region "$region" --project "$project_id" --quiet 2>/dev/null || true

  # 8. Delete static external IP addresses
  echo "Checking for external addresses..."
  local addresses
  addresses="$(gcloud compute addresses list --project "$project_id" \
    --filter="region:${region} AND name~${base_env}" \
    --format='value(name)' 2>/dev/null || true)"
  for addr in $addresses; do
    echo "Deleting address: ${addr}"
    gcloud compute addresses delete "$addr" --region "$region" --project "$project_id" --quiet 2>/dev/null || true
  done

  echo "GCP resource cleanup complete for cluster: ${cluster_name}"
}

# ============================================================================
# Robustness: quota preflight, orphan cleanup, post-destroy verification
# ============================================================================

is_noninteractive() {
  if [[ "${NONINTERACTIVE:-0}" == "1" || "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    return 1
  fi
  return 0
}

# ----- AWS: VPC quota preflight -----
check_aws_vpc_quota() {
  local region="$1"
  local vpc_quota vpc_used
  vpc_quota="$(aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --region "$region" \
    --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
  vpc_quota="${vpc_quota%%.*}"
  [[ -z "$vpc_quota" || "$vpc_quota" == "None" ]] && vpc_quota=5
  vpc_used="$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"

  if (( vpc_used + 1 <= vpc_quota )); then
    echo "AWS VPC quota OK in ${region}: ${vpc_used}/${vpc_quota}"
    return 0
  fi

  echo ""
  echo "⚠️  AWS VPC limit reached in ${region}: ${vpc_used}/${vpc_quota}"
  echo "Existing VPCs:"
  aws ec2 describe-vpcs --region "$region" \
    --query 'Vpcs[*].[VpcId,CidrBlock,IsDefault,Tags[?Key==`Name`].Value|[0]]' \
    --output table

  if is_noninteractive; then
    echo ""
    echo "Non-interactive mode: aborting."
    echo "To resolve:"
    echo "  1. Delete unused VPCs manually"
    echo "  2. Request quota increase: https://${region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
    exit 1
  fi

  echo ""
  echo "Options:"
  echo "  [A] Abort (safe default)"
  echo "  [C] Clean up an orphan VPC (destructive: deletes NATs, ELBs, ENIs, SGs, subnets, VPC)"
  echo "  [Q] Print quota-increase URL and abort"
  local ans
  read -r -p "Choose [A/C/Q] (default A): " ans </dev/tty || ans="A"
  ans="${ans:-A}"
  case "${ans^^}" in
    C)
      local target_vpc
      read -r -p "Enter VPC ID to clean up (e.g. vpc-0abc...): " target_vpc </dev/tty || target_vpc=""
      if [[ -z "$target_vpc" ]]; then
        echo "No VPC ID entered. Aborting."
        exit 1
      fi
      force_delete_aws_vpc "$target_vpc" "$region" || {
        echo "Orphan VPC cleanup failed. Inspect cloud console and retry."
        exit 1
      }
      # Re-check quota after cleanup
      local new_used
      new_used="$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
      if (( new_used + 1 > vpc_quota )); then
        echo "VPC count still at limit (${new_used}/${vpc_quota}). Aborting."
        exit 1
      fi
      echo "VPC count now ${new_used}/${vpc_quota} — proceeding."
      ;;
    Q)
      echo "Request quota increase at:"
      echo "  https://${region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
      exit 1
      ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
}

force_delete_aws_vpc() {
  local vpc_id="$1" region="$2"

  local is_default
  is_default="$(aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc_id" \
    --query 'Vpcs[0].IsDefault' --output text 2>/dev/null || echo "true")"
  if [[ "$is_default" == "true" ]]; then
    echo "Refusing to delete default VPC: ${vpc_id}"
    return 1
  fi

  local vpc_name
  vpc_name="$(aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc_id" \
    --query 'Vpcs[0].Tags[?Key==`Name`].Value|[0]' --output text 2>/dev/null || echo "")"
  local base="${vpc_name%-vpc}"
  base="${base:-orphan}"

  echo "Force-cleaning VPC ${vpc_id} (Name: ${vpc_name:-unknown})..."

  # Run the existing AWS nuclear sweep against this VPC's implied cluster name.
  # cleanup_eks_aws_resources handles NATs, ELBs, ENIs, SGs, EIPs, route-tables within the VPC.
  cleanup_eks_aws_resources "${base}-eks" "$region" || true

  _teardown_empty_aws_vpc "$vpc_id" "$region"
}

_teardown_empty_aws_vpc() {
  local vpc_id="$1" region="$2"

  local igws
  igws="$(aws ec2 describe-internet-gateways --region "$region" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || true)"
  for igw in $igws; do
    echo "Detaching + deleting IGW: ${igw}"
    aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw" --vpc-id "$vpc_id" 2>/dev/null || true
    aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw" 2>/dev/null || true
  done

  local subnets
  subnets="$(aws ec2 describe-subnets --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)"
  for subnet in $subnets; do
    echo "Deleting subnet: ${subnet}"
    aws ec2 delete-subnet --region "$region" --subnet-id "$subnet" 2>/dev/null || true
  done

  local rts
  rts="$(aws ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || true)"
  for rt in $rts; do
    echo "Deleting route table: ${rt}"
    aws ec2 delete-route-table --region "$region" --route-table-id "$rt" 2>/dev/null || true
  done

  local sgs
  sgs="$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
  for sg in $sgs; do
    echo "Deleting SG: ${sg}"
    aws ec2 delete-security-group --region "$region" --group-id "$sg" 2>/dev/null || true
  done

  echo "Deleting VPC: ${vpc_id}"
  if aws ec2 delete-vpc --region "$region" --vpc-id "$vpc_id" 2>&1; then
    echo "VPC ${vpc_id} deleted."
    return 0
  else
    echo "Failed to delete VPC ${vpc_id} — may still have dependencies."
    return 1
  fi
}

# ----- Azure: VNet quota preflight -----
check_azure_vnet_quota() {
  local region="$1"
  local vnet_limit vnet_used
  vnet_limit="$(az network list-usages --location "$region" \
    --query "[?name.value=='VirtualNetworks'].limit | [0]" -o tsv 2>/dev/null || true)"
  vnet_used="$(az network list-usages --location "$region" \
    --query "[?name.value=='VirtualNetworks'].currentValue | [0]" -o tsv 2>/dev/null || true)"

  if [[ -z "$vnet_limit" || -z "$vnet_used" ]]; then
    echo "WARNING: unable to read Azure VNet quota for $region. Continuing."
    return 0
  fi

  if (( vnet_used + 1 <= vnet_limit )); then
    echo "Azure VNet quota OK in ${region}: ${vnet_used}/${vnet_limit}"
    return 0
  fi

  echo ""
  echo "⚠️  Azure VNet limit reached in ${region}: ${vnet_used}/${vnet_limit}"
  echo "Existing VNets in this region:"
  az network vnet list --query "[?location=='${region}'].{Name:name,RG:resourceGroup,CIDR:addressSpace.addressPrefixes[0]}" -o table 2>/dev/null || true

  if is_noninteractive; then
    echo ""
    echo "Non-interactive mode: aborting. Delete unused resource groups or request quota increase."
    exit 1
  fi

  echo ""
  echo "Options:"
  echo "  [A] Abort"
  echo "  [C] Delete an orphan resource group (entire RG — destructive)"
  local ans
  read -r -p "Choose [A/C] (default A): " ans </dev/tty || ans="A"
  ans="${ans:-A}"
  case "${ans^^}" in
    C)
      local target_rg
      read -r -p "Enter resource group name to delete: " target_rg </dev/tty || target_rg=""
      if [[ -z "$target_rg" ]]; then
        echo "No RG entered. Aborting."
        exit 1
      fi
      echo "Deleting resource group: ${target_rg} (this may take several minutes)..."
      if az group delete --name "$target_rg" --yes 2>&1; then
        echo "Resource group ${target_rg} deleted."
      else
        echo "Failed to delete resource group. Aborting."
        exit 1
      fi
      ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
}

# ----- GCP: Network quota preflight -----
check_gcp_network_quota() {
  local region="$1" project_id="$2"
  local nets_limit nets_used
  nets_limit="$(gcloud compute project-info describe --project "$project_id" \
    --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null \
    | awk -F, '$1=="NETWORKS"{print $2; exit}')"
  nets_used="$(gcloud compute project-info describe --project "$project_id" \
    --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null \
    | awk -F, '$1=="NETWORKS"{print $3; exit}')"
  nets_limit="${nets_limit%%.*}"
  nets_used="${nets_used%%.*}"

  if [[ -z "$nets_limit" || -z "$nets_used" ]]; then
    echo "WARNING: unable to read GCP NETWORKS quota. Continuing."
    return 0
  fi

  if (( nets_used + 1 <= nets_limit )); then
    echo "GCP NETWORKS quota OK: ${nets_used}/${nets_limit}"
    return 0
  fi

  echo ""
  echo "⚠️  GCP NETWORKS quota reached: ${nets_used}/${nets_limit}"
  echo "Existing networks in project ${project_id}:"
  gcloud compute networks list --project "$project_id" 2>/dev/null || true

  if is_noninteractive; then
    echo ""
    echo "Non-interactive mode: aborting. Delete unused networks or request quota increase."
    exit 1
  fi

  echo ""
  echo "Options:"
  echo "  [A] Abort"
  echo "  [C] Delete an orphan network (and its subnets, routers, firewall rules)"
  local ans
  read -r -p "Choose [A/C] (default A): " ans </dev/tty || ans="A"
  ans="${ans:-A}"
  case "${ans^^}" in
    C)
      local target_net
      read -r -p "Enter network name to delete: " target_net </dev/tty || target_net=""
      if [[ -z "$target_net" ]]; then
        echo "No network entered. Aborting."
        exit 1
      fi
      force_delete_gcp_network "$target_net" "$region" "$project_id" || {
        echo "Orphan network cleanup failed."
        exit 1
      }
      ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
}

force_delete_gcp_network() {
  local net="$1" region="$2" project_id="$3"
  echo "Force-cleaning GCP network: ${net}..."

  local fws
  fws="$(gcloud compute firewall-rules list --project "$project_id" \
    --filter="network:${net}" --format='value(name)' 2>/dev/null || true)"
  for fw in $fws; do
    echo "Deleting firewall rule: ${fw}"
    gcloud compute firewall-rules delete "$fw" --project "$project_id" --quiet 2>/dev/null || true
  done

  local routers_csv
  routers_csv="$(gcloud compute routers list --project "$project_id" \
    --filter="network:${net}" --format='csv[no-heading](name,region.basename())' 2>/dev/null || true)"
  while IFS=, read -r r_name r_region; do
    [[ -z "$r_name" ]] && continue
    echo "Deleting router: ${r_name} in ${r_region}"
    gcloud compute routers delete "$r_name" --region "$r_region" --project "$project_id" --quiet 2>/dev/null || true
  done <<< "$routers_csv"

  local subnets_csv
  subnets_csv="$(gcloud compute networks subnets list --project "$project_id" \
    --filter="network:${net}" --format='csv[no-heading](name,region.basename())' 2>/dev/null || true)"
  while IFS=, read -r s_name s_region; do
    [[ -z "$s_name" ]] && continue
    echo "Deleting subnet: ${s_name} in ${s_region}"
    gcloud compute networks subnets delete "$s_name" --region "$s_region" --project "$project_id" --quiet 2>/dev/null || true
  done <<< "$subnets_csv"

  echo "Deleting network: ${net}"
  if gcloud compute networks delete "$net" --project "$project_id" --quiet 2>&1; then
    echo "Network ${net} deleted."
    return 0
  else
    echo "Failed to delete network ${net}."
    return 1
  fi
}

# ----- Post-destroy verification -----
verify_aws_destroyed() {
  local cluster_name="$1" region="$2"
  local base="${cluster_name%-eks}"
  local vpc_name="${base}-vpc"

  local vpc_id
  vpc_id="$(aws ec2 describe-vpcs --region "$region" \
    --filters "Name=tag:Name,Values=${vpc_name}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")"

  if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
    echo "✅ Verify: VPC '${vpc_name}' is gone."
    return 0
  fi

  echo "❌ Verify: VPC '${vpc_name}' (${vpc_id}) still exists."
  return 1
}

verify_azure_destroyed() {
  local cluster_name="$1" region="$2"
  local rg="rg-${cluster_name}"
  if az group show --name "$rg" >/dev/null 2>&1; then
    echo "❌ Verify: Resource group '${rg}' still exists."
    return 1
  fi
  echo "✅ Verify: Resource group '${rg}' is gone."
  return 0
}

verify_gcp_destroyed() {
  local cluster_name="$1" region="$2"
  local project_id
  project_id="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
  local vpc_name="${cluster_name}-vpc"
  if gcloud compute networks describe "$vpc_name" --project "$project_id" >/dev/null 2>&1; then
    echo "❌ Verify: Network '${vpc_name}' still exists."
    return 1
  fi
  echo "✅ Verify: Network '${vpc_name}' is gone."
  return 0
}

post_destroy_verify() {
  local cloud="$1" cluster_name="$2" region="$3"
  local max=3 i
  for i in $(seq 1 "$max"); do
    case "$cloud" in
      aws)   verify_aws_destroyed   "$cluster_name" "$region" && return 0 ;;
      azure) verify_azure_destroyed "$cluster_name" "$region" && return 0 ;;
      gcp)   verify_gcp_destroyed   "$cluster_name" "$region" && return 0 ;;
    esac

    if [[ $i -lt $max ]]; then
      echo "Verify attempt ${i}/${max} failed. Running cleanup sweep..."
      case "$cloud" in
        aws)   cleanup_eks_aws_resources   "$cluster_name" "$region" || true ;;
        azure) cleanup_aks_azure_resources "$cluster_name" "$region" || true ;;
        gcp)   cleanup_gke_gcp_resources   "$cluster_name" "$region" || true ;;
      esac
      sleep 30
    fi
  done

  echo ""
  echo "❌ Post-destroy verification FAILED after ${max} attempts."
  echo "   Orphaned resources remain. Check the cloud console and run the"
  echo "   preflight orphan-cleanup path (option [C]) on the next create attempt."
  return 1
}
