#!/usr/bin/env python3
"""Update VMs on AWS, GCP, or Azure (change count or instance type)."""

import argparse
import os
import shutil
import sys
import tempfile

from vm_lib import (
    ROOT_DIR,
    TF_STACK,
    derive_vm_info,
    display_ssh_info,
    prepare_backend,
    require_cmd,
    terraform_apply,
    terraform_init,
    write_tfvars,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Update VMs on AWS, GCP, or Azure")
    parser.add_argument("--cloud", required=True, choices=["aws", "gcp", "azure"])
    parser.add_argument("--name", required=True, help="Logical VM group name")
    parser.add_argument("--env", required=True, choices=["dev", "qa", "staging", "prod"])
    parser.add_argument("--region", required=True, help="Cloud region")
    parser.add_argument("--count", type=int, default=None, help="New instance count")
    parser.add_argument("--instance-type", default="", help="New instance type")
    parser.add_argument("--os", default="ubuntu", choices=["ubuntu", "rocky", "windows"], help="OS type (default: ubuntu)")
    return parser.parse_args()


def main():
    args = parse_args()

    if args.count is None and not args.instance_type:
        print("At least one of --count or --instance-type must be specified")
        sys.exit(1)

    require_cmd("terraform")

    # SSH key must exist from create
    ssh_key_name = f"vm-creator-{args.name}-{args.env}"
    ssh_pub_path = os.path.expanduser(f"~/.ssh/{ssh_key_name}.pub")
    ssh_key_path = os.path.expanduser(f"~/.ssh/{ssh_key_name}")
    if not os.path.exists(ssh_pub_path):
        print(f"SSH key not found: {ssh_pub_path}")
        print("Run create_vm.py first to create the VMs and SSH key.")
        sys.exit(1)
    ssh_pub_key = open(ssh_pub_path).read().strip()

    info = derive_vm_info(args.cloud, args.name, args.env, args.region)

    tmp_dir = tempfile.mkdtemp()
    tfvars_path = os.path.join(tmp_dir, "vars.tfvars")
    backend_path = os.path.join(tmp_dir, "backend.hcl")

    try:
        prepare_backend(args.cloud, info, backend_path)

        tf_dir = str(ROOT_DIR / "terraform" / TF_STACK[args.cloud])
        os.chdir(tf_dir)

        terraform_init(tf_dir, backend_path)

        # Determine effective count
        if args.count is not None:
            count = args.count
        else:
            # Read current count from state
            from vm_lib import terraform_output
            import json
            ips_json = terraform_output(tf_dir, "public_ips")
            count = len(json.loads(ips_json)) if ips_json else 1

        write_tfvars(args.cloud, info, count, args.instance_type, ssh_pub_key, tfvars_path, os_type=args.os)

        print(f"\nUpdating VMs: {info['vm_name']} in {args.region} ({args.cloud})")
        if args.count is not None:
            print(f"  New count: {args.count}")
        if args.instance_type:
            print(f"  New instance type: {args.instance_type}")
        print()

        terraform_apply(tf_dir, tfvars_path)

        display_ssh_info(tf_dir, ssh_key_path, args.cloud)

    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
