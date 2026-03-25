#!/usr/bin/env python3
"""Destroy VMs on AWS, GCP, or Azure."""

import argparse
import os
import shutil
import sys
import tempfile
import time

from vm_lib import (
    ROOT_DIR,
    TF_STACK,
    derive_vm_info,
    prepare_backend,
    require_cmd,
    terraform_destroy,
    terraform_init,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Destroy VMs on AWS, GCP, or Azure")
    parser.add_argument("--cloud", required=True, choices=["aws", "gcp", "azure"])
    parser.add_argument("--name", required=True, help="Logical VM group name")
    parser.add_argument("--env", required=True, choices=["dev", "qa", "staging", "prod"])
    parser.add_argument("--region", required=True, help="Cloud region")
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

    info = derive_vm_info(args.cloud, args.name, args.env, args.region)

    tmp_dir = tempfile.mkdtemp()
    backend_path = os.path.join(tmp_dir, "backend.hcl")

    try:
        prepare_backend(args.cloud, info, backend_path)

        tf_dir = str(ROOT_DIR / "terraform" / TF_STACK[args.cloud])
        os.chdir(tf_dir)

        print(f"\nDestroying VMs: {info['vm_name']} in {args.region} ({args.cloud})\n")

        terraform_init(tf_dir, backend_path)

        max_retries = 3
        for attempt in range(1, max_retries + 1):
            print(f"Destroy attempt {attempt}/{max_retries}")
            try:
                terraform_destroy(tf_dir)
                print(f"\nVMs destroyed successfully: {info['vm_name']}")
                return
            except Exception as e:
                if attempt < max_retries:
                    print(f"Destroy failed, retrying in 30s... ({e})")
                    time.sleep(30)
                else:
                    print(f"Destroy failed after {max_retries} attempts")
                    sys.exit(1)

    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
