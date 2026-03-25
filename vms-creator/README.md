# VM Creator

One-command VM provisioning across AWS (EC2), GCP (Compute Engine), and Azure (Virtual Machines).

Supports **3 operating systems**:
- **Ubuntu 22.04** (Debian-based, `apt`) -- default
- **Rocky Linux 9** (RHEL-based, `yum`/`dnf`) -- open source RHEL alternative
- **Windows Server 2022** (RDP access, Chocolatey package manager)

Designed for **learning and experimentation** -- VMs get public IPs, open security groups, and pre-installed tools (Docker, kubectl, Helm, git, jq, etc.).

## 1. Prerequisites

Required local tools:
- Terraform `>= 1.7`
- AWS CLI v2
- Google Cloud SDK (`gcloud`)
- Azure CLI (`az`)

Required authentication state:
- AWS: configured profile with EC2/VPC/IAM permissions
- GCP: active project and account with Compute/IAM permissions
- Azure: active subscription with VM/VNet/NSG permissions

Verification:

```bash
terraform version
aws sts get-caller-identity
gcloud config get-value project
az account show
```

## 2. One-Command VM Creation

AWS:

```bash
cd vms-creator
./scripts/create-vm.sh --cloud aws --name myvm --env dev --region us-east-1
```

GCP:

```bash
cd vms-creator
./scripts/create-vm.sh --cloud gcp --name myvm --env dev --region us-central1
```

Azure:

```bash
cd vms-creator
./scripts/create-vm.sh --cloud azure --name myvm --env dev --region eastus
```

Flags:
- `--cloud`: target platform (`aws|gcp|azure`)
- `--name`: logical VM group name (used in deterministic naming)
- `--env`: environment (`dev|qa|staging|prod`)
- `--region`: cloud region
- `--count N`: number of VMs (default: 1)
- `--instance-type <type>`: override default instance size
- `--os`: operating system (`ubuntu|rocky|windows`, default: `ubuntu`)

Examples:

```bash
# Create 3 Ubuntu VMs on AWS
./scripts/create-vm.sh --cloud aws --name lab --env dev --region us-east-1 --count 3

# Create Rocky Linux VMs (RHEL-based, yum/dnf)
./scripts/create-vm.sh --cloud aws --name lab --env dev --region us-east-1 --os rocky

# Create Windows Server VMs (RDP access)
./scripts/create-vm.sh --cloud azure --name winlab --env dev --region eastus --os windows

# Create 2 VMs on GCP with custom instance type
./scripts/create-vm.sh --cloud gcp --name lab --env qa --region us-central1 --count 2 --instance-type e2-standard-4
```

## 3. What Gets Created

Per cloud:

**AWS (EC2)**
- VPC with public subnet + Internet Gateway
- Security group with open learning ports
- EC2 instances with Elastic IPs (stable across stop/start)
- SSH key pair (auto-generated)
- 30GB gp3 encrypted root volume

**GCP (Compute Engine)**
- VPC network + subnet
- Firewall rules for learning ports
- Compute instances with external IPs
- SSH keys via instance metadata
- 30GB pd-balanced boot disk

**Azure (Virtual Machines)**
- Resource group + VNet + subnet
- NSG with learning port rules
- Public IPs (Static) + NICs
- Linux VMs with SSH keys
- 30GB Premium SSD OS disk

**Open ports (all clouds):**
22 (SSH), 80 (HTTP), 443 (HTTPS), 3000 (dev servers), 3389 (RDP), 5000 (Flask/registry), 5985-5986 (WinRM), 6443 (K8s API), 8080 (alt HTTP), 8443 (alt HTTPS), 30000-32767 (NodePort range), ICMP (ping)

**Pre-installed software (Linux):**
Docker, kubectl, Helm, git, curl, wget, htop, vim, jq, unzip

**Pre-installed software (Windows):**
Chocolatey, Docker Desktop, kubectl, Helm, git, curl, jq, OpenSSH Server

**Supported operating systems:**

| OS | Package Manager | AMI / Image | SSH User |
|----|----------------|-------------|----------|
| Ubuntu 22.04 | `apt` | Canonical Ubuntu Jammy | `ubuntu` (AWS/GCP), `azureuser` (Azure) |
| Rocky Linux 9 | `yum` / `dnf` | Rocky Linux official | `rocky` (AWS/GCP), `azureuser` (Azure) |
| Windows Server 2022 | `choco` | Microsoft Windows Server | RDP: `Administrator` (AWS), `adminuser` (Azure) |

**Default instance sizes by environment:**

| Env     | AWS          | GCP            | Azure           |
|---------|--------------|----------------|-----------------|
| dev     | t3.medium    | e2-medium      | Standard_B2s    |
| qa      | t3.medium    | e2-medium      | Standard_B2s    |
| staging | t3.large     | e2-standard-2  | Standard_D2s_v3 |
| prod    | t3.xlarge    | e2-standard-4  | Standard_D4s_v3 |

## 4. Connecting to VMs

### Linux VMs (Ubuntu / Rocky Linux)

After creation, the script displays SSH commands:

```bash
ssh -i ~/.ssh/vm-creator-myvm-dev ubuntu@<public-ip>     # Ubuntu
ssh -i ~/.ssh/vm-creator-myvm-dev rocky@<public-ip>       # Rocky Linux
ssh -i ~/.ssh/vm-creator-myvm-dev azureuser@<public-ip>   # Azure (any Linux)
```

Quick connect helper:

```bash
# Connect to first VM (index 0)
./scripts/ssh-connect.sh --cloud aws --name myvm --env dev --region us-east-1

# Connect to third VM (index 2)
./scripts/ssh-connect.sh --cloud aws --name myvm --env dev --region us-east-1 --index 2
```

SSH usernames per OS and cloud:

| OS | AWS | GCP | Azure |
|----|-----|-----|-------|
| Ubuntu | `ubuntu` | `ubuntu` | `azureuser` |
| Rocky Linux | `rocky` | `rocky` | `azureuser` |

File transfer:

```bash
scp -i ~/.ssh/vm-creator-myvm-dev myfile.txt ubuntu@<ip>:/home/ubuntu/
scp -i ~/.ssh/vm-creator-myvm-dev ubuntu@<ip>:/home/ubuntu/result.txt ./
```

### Windows VMs (RDP)

Windows VMs use **Remote Desktop Protocol (RDP)** on port 3389.

**AWS:** Password is auto-generated. Decrypt it after ~4 minutes:
```bash
aws ec2 get-password-data --instance-id <id> --priv-launch-key ~/.ssh/vm-creator-myvm-dev
```

**GCP:** Reset the Windows password:
```bash
gcloud compute reset-windows-password <instance-name> --zone <zone>
```

**Azure:** Default credentials are `adminuser` / `VMcreator2024!`

Connect using any RDP client (Microsoft Remote Desktop, Remmina, etc.) to `<public-ip>:3389`.

## 5. Update VMs

Scale up/down or change instance type:

```bash
# Scale to 5 VMs
./scripts/update-vm.sh --cloud aws --name myvm --env dev --region us-east-1 --count 5

# Change instance type
./scripts/update-vm.sh --cloud aws --name myvm --env dev --region us-east-1 --instance-type t3.xlarge

# Both at once
./scripts/update-vm.sh --cloud aws --name myvm --env dev --region us-east-1 --count 3 --instance-type t3.large
```

## 6. Destroy VMs

```bash
./scripts/destroy-vm.sh --cloud aws --name myvm --env dev --region us-east-1
./scripts/destroy-vm.sh --cloud gcp --name myvm --env dev --region us-central1
./scripts/destroy-vm.sh --cloud azure --name myvm --env dev --region eastus
```

Destroys all Terraform-managed resources (VMs, networking, security groups, IPs).

## 7. Python Alternative

Equivalent Python scripts are available:

```bash
cd vms-creator/python
python3 create_vm.py --cloud aws --name myvm --env dev --region us-east-1 --count 2
python3 create_vm.py --cloud aws --name myvm --env dev --region us-east-1 --os rocky
python3 create_vm.py --cloud azure --name winvm --env dev --region eastus --os windows
python3 update_vm.py --cloud aws --name myvm --env dev --region us-east-1 --count 3 --os ubuntu
python3 destroy_vm.py --cloud aws --name myvm --env dev --region us-east-1
```

Install dependencies first: `pip install -r requirements.txt`

## 8. Environment Strategy

- `dev`, `qa`, `staging`, `prod` control naming and default sizing.
- Collision avoidance: name suffix derives from cloud account/project/subscription hash.
- Resulting VM names are deterministic and unique per cloud account context.

## 9. Naming Convention

- AWS: `{name}-aws-{account-suffix}-{env}-vm` (e.g., `lab-aws-a1b2c3-dev-vm`)
- GCP: `{name}-gcp-{project-hash}-{env}-vm` (e.g., `lab-gcp-7f9a21d4-dev-vm`)
- Azure: `{name}-az-{sub-hash}-{env}-vm` (e.g., `lab-az-3c0f8a12-dev-vm`)

## 10. Production Hardening Checklist

**These VMs are configured for learning with wide-open security. For production use, apply these changes:**

- [ ] **Restrict security group/firewall CIDRs** -- Replace `0.0.0.0/0` with your office/VPN CIDR blocks
- [ ] **Use a bastion host or VPN** -- Place VMs in private subnets, access through a jump box or VPN
- [ ] **Disable direct SSH from internet** -- Use SSM Session Manager (AWS), IAP tunnels (GCP), or Azure Bastion
- [ ] **Enable OS-level firewall** -- Configure `ufw` or `iptables` to restrict ports at the OS level
- [ ] **Disable password authentication** -- Enforce SSH key-only access (already the default in this setup)
- [ ] **Enable disk encryption** -- AWS EBS encryption is enabled; verify for GCP and Azure
- [ ] **Set up monitoring and alerting** -- CloudWatch, Stackdriver, or Azure Monitor for VM metrics
- [ ] **Enable audit logging** -- CloudTrail (AWS), Cloud Audit Logs (GCP), Activity Log (Azure)
- [ ] **Apply OS security patches** -- Configure unattended-upgrades or equivalent
- [ ] **Use private subnets with NAT** -- VMs should not have public IPs in production
- [ ] **Implement IAM least privilege** -- Restrict service account and IAM role permissions
- [ ] **Add remote Terraform state + locking** -- Already supported via backend preparation scripts
- [ ] **Enable backup strategy** -- Snapshots, AMIs, or disk backup policies
- [ ] **Use immutable infrastructure** -- Prefer replacing VMs over patching in-place

How to restrict security groups for production:
- AWS: Edit `terraform/ec2/main.tf`, change `cidr_blocks = ["0.0.0.0/0"]` to your CIDR
- GCP: Edit `terraform/gce/main.tf`, change `source_ranges = ["0.0.0.0/0"]` to your CIDR
- Azure: Edit `terraform/azure-vm/main.tf`, change `source_address_prefix = "*"` to your CIDR

## 11. Known Limitations

- VMs use ephemeral external IPs on GCP (not static) -- for stability, reserve static IPs manually or update Terraform
- AWS Elastic IPs are limited to 5 per region by default -- request a quota increase for more VMs
- Startup script runs once on first boot only -- subsequent stop/start does not re-run it
- No automatic DNS assignment -- use external-dns or cloud DNS manually if needed
