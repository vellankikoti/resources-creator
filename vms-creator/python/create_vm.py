#!/usr/bin/env python3
"""Create VMs on AWS, GCP, or Azure with one command."""

import argparse
import os
import sys
import tempfile

from vm_lib import (
    ROOT_DIR,
    TF_STACK,
    derive_vm_info,
    display_ssh_info,
    generate_ssh_keypair,
    prepare_backend,
    require_cmd,
    terraform_apply,
    terraform_init,
    write_tfvars,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Create VMs on AWS, GCP, or Azure")
    parser.add_argument("--cloud", required=True, choices=["aws", "gcp", "azure"])
    parser.add_argument("--name", required=True, help="Logical VM group name")
    parser.add_argument("--env", required=True, choices=["dev", "qa", "staging", "prod"])
    parser.add_argument("--region", required=True, help="Cloud region")
    parser.add_argument("--count", type=int, default=1, help="Number of VMs (default: 1)")
    parser.add_argument("--instance-type", default="", help="Instance type override")
    parser.add_argument("--os", default="ubuntu", choices=["ubuntu", "rocky", "windows"], help="OS type (default: ubuntu)")
    return parser.parse_args()


def main():
    args = parse_args()

    require_cmd("terraform")
    if args.cloud == "aws":
        require_cmd("aws")
    elif args.cloud == "gcp":
        require_cmd("gcloud")
    elif args.cloud == "azure":
        require_cmd("az")

    # Derive naming
    info = derive_vm_info(args.cloud, args.name, args.env, args.region)
    print(f"VM name: {info['vm_name']}")

    # SSH key
    ssh_key_path, ssh_pub_path = generate_ssh_keypair(args.name, args.env)
    ssh_pub_key = open(ssh_pub_path).read().strip()

    # Temp dir for tfvars and backend config
    tmp_dir = tempfile.mkdtemp()
    tfvars_path = os.path.join(tmp_dir, "vars.tfvars")
    backend_path = os.path.join(tmp_dir, "backend.hcl")

    try:
        # Write tfvars
        write_tfvars(args.cloud, info, args.count, args.instance_type, ssh_pub_key, tfvars_path, os_type=args.os)

        # Prepare backend
        prepare_backend(args.cloud, info, backend_path)

        # Terraform
        tf_dir = str(ROOT_DIR / "terraform" / TF_STACK[args.cloud])
        os.chdir(tf_dir)

        print(f"\nCreating {args.count} {args.os} VM(s): {info['vm_name']} in {args.region} ({args.cloud})\n")

        terraform_init(tf_dir, backend_path)
        terraform_apply(tf_dir, tfvars_path)

        # Display results
        display_ssh_info(tf_dir, ssh_key_path, args.cloud)

        print(f"\nVM name:  {info['vm_name']}")
        print(f"Region:   {args.region}")
        print(f"Cloud:    {args.cloud}")
        print(f"Count:    {args.count}")
        print(f"SSH key:  {ssh_key_path}")
        print(f"\nTo destroy: python3 destroy_vm.py --cloud {args.cloud} --name {args.name} --env {args.env} --region {args.region}")

    finally:
        import shutil
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
