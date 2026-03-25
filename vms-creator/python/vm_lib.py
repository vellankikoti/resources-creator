#!/usr/bin/env python3
"""Shared library for VM creation, destruction, and management across clouds."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
TF_STACK = {"aws": "ec2", "gcp": "gce", "azure": "azure-vm"}


# ─── Subprocess Helpers ───────────────────────────────────────────────────────


def run(cmd, check=True, timeout=600, quiet=False, **kwargs):
    """Run a command, print output in real time unless quiet."""
    if not quiet:
        print(f"+ {' '.join(cmd)}", flush=True)
    result = subprocess.run(
        cmd,
        check=check,
        timeout=timeout,
        capture_output=quiet,
        text=True,
        **kwargs,
    )
    return result


def run_output(cmd, check=True, timeout=60, **kwargs):
    """Run a command and return its stdout."""
    result = subprocess.run(
        cmd, capture_output=True, text=True, check=check, timeout=timeout, **kwargs
    )
    return result.stdout.strip()


# ─── Utility Functions ────────────────────────────────────────────────────────


def sanitize_name(name):
    import re

    name = name.lower()
    name = re.sub(r"[^a-z0-9-]", "-", name)
    name = re.sub(r"-+", "-", name)
    return name.strip("-")


def hash8(value):
    return hashlib.sha1(value.encode()).hexdigest()[:8]


def require_cmd(cmd):
    if not shutil.which(cmd):
        print(f"missing command: {cmd}")
        sys.exit(1)


def get_public_ip():
    import urllib.request

    for url in ["https://checkip.amazonaws.com", "https://ifconfig.me"]:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                ip = resp.read().decode().strip()
                if ip:
                    return ip
        except Exception:
            continue
    print("unable to detect caller public IPv4")
    sys.exit(1)


# ─── VM Naming ────────────────────────────────────────────────────────────────


def derive_vm_info(cloud, name, env_name, region):
    """Derive deterministic VM names, matching shell script logic exactly."""
    info = {"env": env_name, "region": region, "cloud": cloud}

    if cloud == "aws":
        account_id = run_output(
            ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"]
        )
        suffix = account_id[-6:]
        info["account_id"] = account_id

        if name.endswith(f"-{env_name}-vm"):
            info["vm_name"] = sanitize_name(name)
            info["base_name"] = info["vm_name"].removesuffix(f"-{env_name}-vm")
        else:
            info["base_name"] = sanitize_name(f"{name}-aws-{suffix}")
            info["vm_name"] = f"{info['base_name']}-{env_name}-vm"

    elif cloud == "gcp":
        project_id = run_output(
            ["gcloud", "config", "get-value", "project"]
        ).replace("\r", "")
        if not project_id or project_id == "(unset)":
            print("gcloud project is not set")
            sys.exit(1)
        proj_hash = hash8(project_id)
        info["project_id"] = project_id

        if name.endswith(f"-{env_name}-vm"):
            info["vm_name"] = sanitize_name(name)
            info["base_name"] = info["vm_name"].removesuffix(f"-{env_name}-vm")
        else:
            info["base_name"] = sanitize_name(f"{name}-gcp-{proj_hash}")
            info["vm_name"] = f"{info['base_name']}-{env_name}-vm"

    elif cloud == "azure":
        sub_id = run_output(["az", "account", "show", "--query", "id", "-o", "tsv"])
        sub_hash = hash8(sub_id)
        info["subscription_id"] = sub_id

        if name.endswith(f"-{env_name}-vm"):
            info["vm_name"] = sanitize_name(name)
            info["base_name"] = info["vm_name"].removesuffix(f"-{env_name}-vm")
        else:
            info["base_name"] = sanitize_name(f"{name}-az-{sub_hash}")
            info["vm_name"] = f"{info['base_name']}-{env_name}-vm"

    return info


# ─── SSH Key Management ──────────────────────────────────────────────────────


def generate_ssh_keypair(name, env_name):
    """Generate an SSH key pair if it doesn't exist. Returns (private_path, public_path)."""
    key_name = f"vm-creator-{name}-{env_name}"
    key_path = Path.home() / ".ssh" / key_name

    if not key_path.exists():
        key_path.parent.mkdir(parents=True, exist_ok=True)
        run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(key_path), "-N", "", "-C", f"vm-creator-{key_name}"],
            quiet=True,
        )
        os.chmod(str(key_path), 0o600)
        os.chmod(f"{key_path}.pub", 0o644)
        print(f"SSH key generated: {key_path}")
    else:
        print(f"SSH key already exists: {key_path}")

    return str(key_path), f"{key_path}.pub"


# ─── Terraform Variable Generation ───────────────────────────────────────────


def write_tfvars(cloud, info, count, instance_type, ssh_pub_key, tfvars_path, os_type="ubuntu"):
    """Write cloud-specific tfvars file."""
    lines = []

    if cloud == "aws":
        lines.extend([
            f'region         = "{info["region"]}"',
            f'base_name      = "{info["base_name"]}"',
            f'environments   = ["{info["env"]}"]',
            f"instance_count = {count}",
            f'os_type        = "{os_type}"',
            f'ssh_public_key = "{ssh_pub_key}"',
        ])
        if instance_type:
            lines.append(f'instance_type = "{instance_type}"')

    elif cloud == "gcp":
        lines.extend([
            f'project_id     = "{info["project_id"]}"',
            f'region         = "{info["region"]}"',
            f'base_name      = "{info["base_name"]}"',
            f'environments   = ["{info["env"]}"]',
            f"instance_count = {count}",
            f'os_type        = "{os_type}"',
            f'ssh_public_key = "{ssh_pub_key}"',
        ])
        if instance_type:
            lines.append(f'machine_type = "{instance_type}"')

    elif cloud == "azure":
        lines.extend([
            f'subscription_id = "{info["subscription_id"]}"',
            f'region          = "{info["region"]}"',
            f'base_name       = "{info["base_name"]}"',
            f'environments    = ["{info["env"]}"]',
            f"instance_count  = {count}",
            f'os_type         = "{os_type}"',
            f'ssh_public_key  = "{ssh_pub_key}"',
        ])
        if instance_type:
            lines.append(f'vm_size = "{instance_type}"')

    Path(tfvars_path).write_text("\n".join(lines) + "\n")


# ─── Backend Preparation ─────────────────────────────────────────────────────


def prepare_backend(cloud, info, backend_path):
    """Prepare remote backend, dispatching to cloud-specific function."""
    if cloud == "aws":
        _prepare_aws_backend(info, backend_path)
    elif cloud == "gcp":
        _prepare_gcp_backend(info, backend_path)
    elif cloud == "azure":
        _prepare_azure_backend(info, backend_path)


def _prepare_aws_backend(info, backend_path):
    account_id = info["account_id"]
    region = info["region"]
    vm_name = info["vm_name"]
    env_name = info["env"]

    bucket = f"rc-tfstate-{account_id}-{region}"
    table = "rc-tf-locks"
    key = f"aws-vm/{vm_name}/{env_name}/{region}/terraform.tfstate"

    # Create bucket if needed
    try:
        run_output(["aws", "s3api", "head-bucket", "--bucket", bucket])
    except subprocess.CalledProcessError:
        create_cmd = ["aws", "s3api", "create-bucket", "--bucket", bucket]
        if region != "us-east-1":
            create_cmd += ["--create-bucket-configuration", f"LocationConstraint={region}"]
        run(create_cmd, quiet=True)

    run(["aws", "s3api", "put-bucket-versioning", "--bucket", bucket,
         "--versioning-configuration", "Status=Enabled"], quiet=True)
    run(["aws", "s3api", "put-bucket-encryption", "--bucket", bucket,
         "--server-side-encryption-configuration",
         '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'], quiet=True)

    # Create DynamoDB table if needed
    try:
        run_output(["aws", "dynamodb", "describe-table", "--table-name", table, "--region", region])
    except subprocess.CalledProcessError:
        run(["aws", "dynamodb", "create-table",
             "--table-name", table,
             "--attribute-definitions", "AttributeName=LockID,AttributeType=S",
             "--key-schema", "AttributeName=LockID,KeyType=HASH",
             "--billing-mode", "PAY_PER_REQUEST",
             "--region", region], quiet=True)
        run(["aws", "dynamodb", "wait", "table-exists", "--table-name", table, "--region", region], quiet=True)

    Path(backend_path).write_text(
        f'bucket         = "{bucket}"\n'
        f'key            = "{key}"\n'
        f'region         = "{region}"\n'
        f"encrypt        = true\n"
        f'dynamodb_table = "{table}"\n'
    )


def _prepare_gcp_backend(info, backend_path):
    project_id = info["project_id"]
    region = info["region"]
    vm_name = info["vm_name"]
    env_name = info["env"]

    bucket = sanitize_name(f"rc-tfstate-{project_id}")
    prefix = f"gcp-vm/{vm_name}/{env_name}/{region}"

    try:
        run_output(["gcloud", "storage", "buckets", "describe", f"gs://{bucket}", "--project", project_id])
    except subprocess.CalledProcessError:
        run(["gcloud", "storage", "buckets", "create", f"gs://{bucket}",
             "--project", project_id, "--location", region, "--uniform-bucket-level-access"], quiet=True)

    run(["gcloud", "storage", "buckets", "update", f"gs://{bucket}", "--versioning"], quiet=True)

    Path(backend_path).write_text(
        f'bucket = "{bucket}"\n'
        f'prefix = "{prefix}"\n'
    )


def _prepare_azure_backend(info, backend_path):
    subscription_id = info["subscription_id"]
    region = info["region"]
    vm_name = info["vm_name"]
    env_name = info["env"]

    rg = sanitize_name(f"rc-tfstate-rg-{region}")
    sa = f"rctf{hash8(f'{subscription_id}-{region}')}"
    container = "tfstate"
    key = f"azure-vm/{vm_name}/{env_name}/{region}/terraform.tfstate"

    run(["az", "group", "create", "--name", rg, "--location", region], quiet=True)

    try:
        run_output(["az", "storage", "account", "show", "--name", sa, "--resource-group", rg])
    except subprocess.CalledProcessError:
        run(["az", "storage", "account", "create",
             "--name", sa, "--resource-group", rg, "--location", region,
             "--sku", "Standard_LRS", "--kind", "StorageV2",
             "--allow-blob-public-access", "false", "--min-tls-version", "TLS1_2"], quiet=True)

    run(["az", "storage", "container", "create", "--name", container,
         "--account-name", sa, "--auth-mode", "login"], quiet=True)

    Path(backend_path).write_text(
        f'resource_group_name  = "{rg}"\n'
        f'storage_account_name = "{sa}"\n'
        f'container_name       = "{container}"\n'
        f'key                  = "{key}"\n'
    )


# ─── Terraform Wrappers ──────────────────────────────────────────────────────


def terraform_init(tf_dir, backend_file):
    run(["terraform", "init", "-reconfigure", f"-backend-config={backend_file}"], timeout=300)


def terraform_apply(tf_dir, tfvars_file, timeout=1800):
    run(["terraform", "apply", "-auto-approve", "-input=false", f"-var-file={tfvars_file}"], timeout=timeout)


def terraform_destroy(tf_dir, timeout=1800):
    run(["terraform", "destroy", "-auto-approve", "-input=false"], timeout=timeout)


def terraform_output(tf_dir, name, raw=False):
    cmd = ["terraform", "output"]
    if raw:
        cmd += ["-raw", name]
    else:
        cmd += ["-json", name]
    return run_output(cmd, check=False)


# ─── Display Helpers ──────────────────────────────────────────────────────────


def display_ssh_info(tf_dir, ssh_key_path, cloud):
    """Display connection info for all VMs."""
    original_dir = os.getcwd()
    os.chdir(tf_dir)

    try:
        ssh_user = terraform_output(tf_dir, "ssh_user", raw=True) or "ubuntu"
        os_type = terraform_output(tf_dir, "os_type", raw=True) or "ubuntu"
        public_ips_json = terraform_output(tf_dir, "public_ips")
        is_windows = os_type == "windows"

        print()
        print("=" * 63)
        print(f"  VM INSTANCES READY ({os_type})")
        print("=" * 63)
        print()

        if public_ips_json:
            ips = json.loads(public_ips_json)

            # For Windows, also fetch instance IDs/names for password retrieval
            instance_ids = {}
            instance_names = {}
            zone = ""
            if is_windows:
                if cloud == "aws":
                    ids_json = terraform_output(tf_dir, "instance_ids")
                    if ids_json:
                        instance_ids = json.loads(ids_json)
                elif cloud == "gcp":
                    names_json = terraform_output(tf_dir, "instance_names")
                    if names_json:
                        instance_names = json.loads(names_json)
                    zone = terraform_output(tf_dir, "zone", raw=True) or ""

            for key, ip in sorted(ips.items()):
                print(f"  Instance: {key}")
                print(f"    Public IP: {ip}")

                if is_windows:
                    print(f"    RDP:       {ip}:3389")
                    print(f"    User:      {ssh_user}")
                    if cloud == "aws" and key in instance_ids:
                        print(f"    Password:  (run after ~4 min)")
                        print(f"               aws ec2 get-password-data --instance-id {instance_ids[key]} \\")
                        print(f"                 --priv-launch-key {ssh_key_path} --query PasswordData --output text \\")
                        print(f"                 | base64 -d | openssl pkeyutl -decrypt -inkey {ssh_key_path}")
                    elif cloud == "gcp" and key in instance_names and zone:
                        print(f"    Password:  gcloud compute reset-windows-password {instance_names[key]} --zone {zone}")
                    elif cloud == "azure":
                        print(f"    Password:  VMcreator2024!")
                else:
                    print(f"    SSH:       ssh -i {ssh_key_path} {ssh_user}@{ip}")
                print()

        print("=" * 63)
        if is_windows:
            print(f"  Connect via: Remote Desktop (RDP) client to <ip>:3389")
            print(f"  User:        {ssh_user}")
        else:
            print(f"  SSH Key:     {ssh_key_path}")
            print(f"  User:        {ssh_user}")
            print(f"  Connect:     ssh -i {ssh_key_path} {ssh_user}@<ip>")
        print()
        print("  WARNING: These VMs have OPEN security groups for learning.")
        print("  See README.md for production hardening guidance.")
        print("=" * 63)

    finally:
        os.chdir(original_dir)
