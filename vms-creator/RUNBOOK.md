# VM Creator Runbook

## Quick Reference

| Operation | Command |
|-----------|---------|
| Create VMs | `./scripts/create-vm.sh --cloud aws --name myvm --env dev --region us-east-1 --count 2` |
| Destroy VMs | `./scripts/destroy-vm.sh --cloud aws --name myvm --env dev --region us-east-1` |
| Update VMs | `./scripts/update-vm.sh --cloud aws --name myvm --env dev --region us-east-1 --count 3` |
| SSH connect | `./scripts/ssh-connect.sh --cloud aws --name myvm --env dev --region us-east-1 --index 0` |

## How to Connect via SSH

```bash
# Direct SSH (use the command printed after creation)
ssh -i ~/.ssh/vm-creator-myvm-dev ubuntu@<public-ip>

# Using the helper script
./scripts/ssh-connect.sh --cloud aws --name myvm --env dev --region us-east-1
```

## How to Transfer Files

```bash
# Upload a file
scp -i ~/.ssh/vm-creator-myvm-dev localfile.txt ubuntu@<ip>:/home/ubuntu/

# Download a file
scp -i ~/.ssh/vm-creator-myvm-dev ubuntu@<ip>:/home/ubuntu/output.txt ./

# Upload a directory
scp -r -i ~/.ssh/vm-creator-myvm-dev ./myproject/ ubuntu@<ip>:/home/ubuntu/

# Rsync (faster for repeated syncs)
rsync -avz -e "ssh -i ~/.ssh/vm-creator-myvm-dev" ./myproject/ ubuntu@<ip>:/home/ubuntu/myproject/
```

## Troubleshooting

### SSH connection refused

1. VM might still be starting up -- wait 2-3 minutes after creation
2. Check the VM is running:
   - AWS: `aws ec2 describe-instances --filters "Name=tag:Name,Values=*myvm*" --query "Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]" --output table`
   - GCP: `gcloud compute instances list --filter="name~myvm"`
   - Azure: `az vm list -g rg-*myvm* -o table`
3. Check security group allows port 22

### SSH permission denied

1. Verify you're using the correct key: `ssh -i ~/.ssh/vm-creator-myvm-dev`
2. Verify the correct username:
   - AWS/GCP: `ubuntu`
   - Azure: `azureuser`
3. Check key permissions: `chmod 600 ~/.ssh/vm-creator-myvm-dev`

### SSH connection timeout

1. Verify the VM has a public IP
2. Check your local firewall/VPN isn't blocking port 22
3. Verify the security group/firewall rules exist

### Terraform state issues

If terraform reports state lock errors:
```bash
# Force unlock (use with caution)
cd terraform/ec2  # or gce, azure-vm
terraform force-unlock <lock-id>
```

### Startup script not completed

Check the startup script logs on the VM:

```bash
# Ubuntu (cloud-init)
sudo cat /var/log/cloud-init-output.log

# Check if Docker is running
systemctl status docker

# Check installed tools
docker --version
kubectl version --client
helm version
```

### VM not accessible after stop/start

- AWS: Elastic IPs persist across stop/start -- IP should remain the same
- GCP: Ephemeral IPs change after stop/start -- get new IP from `gcloud compute instances list`
- Azure: Static IPs persist across stop/start

## How to Check VM Status

```bash
# AWS
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*myvm*" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress,InstanceType]" \
  --output table

# GCP
gcloud compute instances list --filter="name~myvm"

# Azure
az vm list -g rg-*-vm -d -o table
```

## Cost Management

- **Stop VMs when not in use** -- you still pay for storage but not compute
  - AWS: `aws ec2 stop-instances --instance-ids <id>`
  - GCP: `gcloud compute instances stop <name> --zone <zone>`
  - Azure: `az vm deallocate --name <name> -g <rg>`
- **Destroy VMs when done** -- removes all resources including storage
- **Use `dev` environment** -- smallest instance sizes by default
- **AWS Elastic IPs cost money when unattached** -- destroy VMs rather than just stopping them
- **Check billing dashboards regularly** -- AWS Cost Explorer, GCP Billing, Azure Cost Management
