#!/usr/bin/env python3
"""Destroy a Kubernetes cluster — equivalent to scripts/destroy-cluster.sh.

Usage:
    python destroy_cluster.py --cloud aws|gcp|azure --name <name> \
        --env dev|qa|staging|prod --region <region>
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import time

from cluster_lib import (
    ROOT_DIR,
    TF_STACK,
    derive_cluster_info,
    post_destroy_verify,
    prepare_backend,
    pre_destroy_cleanup,
    retry_cleanup,
    run,
    terraform_destroy,
    terraform_init,
    write_tfvars,
)

VALID_ENVS = ("dev", "qa", "staging", "prod")
MAX_RETRIES = 3


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Destroy a Kubernetes cluster")
    p.add_argument("--cloud", required=True, choices=["aws", "gcp", "azure"])
    p.add_argument("--name", required=True, help="Cluster base name")
    p.add_argument("--env", required=True, choices=VALID_ENVS,
                   dest="env_name")
    p.add_argument("--region", required=True)
    p.add_argument("--yes", "-y", action="store_true", default=False,
                   help="Non-interactive mode")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    cloud = args.cloud
    name = args.name
    env_name = args.env_name
    region = args.region

    if args.yes:
        os.environ["ASSUME_YES"] = "1"

    info = derive_cluster_info(cloud, name, env_name, region)
    cluster_name = info["cluster_name"]
    base_name = info["base_name"]

    print(f"Destroying {cloud.upper()} cluster: {cluster_name} "
          f"in {region} (env={env_name})")

    with tempfile.TemporaryDirectory() as tmp:
        vars_file = os.path.join(tmp, "vars.tfvars")
        backend_file = os.path.join(tmp, "backend.hcl")

        # Generate tfvars (needed for terraform destroy)
        write_tfvars(vars_file, cloud, info, env_name, region)
        prepare_backend(cloud, cluster_name, env_name, region, info,
                        backend_file)

        tf_dir = ROOT_DIR / "terraform" / TF_STACK[cloud]
        os.chdir(tf_dir)

        terraform_init(cloud, backend_file)

        # Pre-destroy cleanup
        print(f"\n{'='*60}")
        print(f"Executing proactive cleanup for {cloud.upper()} cluster...")
        print(f"{'='*60}\n")
        try:
            pre_destroy_cleanup(cloud, cluster_name, region)
        except Exception as e:
            print(f"Pre-cleanup warning (non-fatal): {e}")

        # Terraform destroy with retries
        destroy_ok = False
        for attempt in range(1, MAX_RETRIES + 1):
            print(f"\n=== Terraform destroy attempt {attempt}/{MAX_RETRIES} ===")
            if terraform_destroy(vars_file):
                destroy_ok = True
                break

            if attempt == MAX_RETRIES:
                print(f"Terraform destroy failed after {attempt} attempts.")
                break

            print("Terraform destroy failed. Waiting 30s, then running "
                  "cleanup sweep...")
            time.sleep(30)
            try:
                retry_cleanup(cloud, cluster_name, region)
            except Exception as e:
                print(f"Retry cleanup warning: {e}")

    # Post-destroy verification: confirm network resources are actually gone.
    print("\n=== Post-destroy verification ===")
    if not post_destroy_verify(cloud, cluster_name, region):
        sys.exit(1)

    if not destroy_ok:
        print("Terraform destroy did not complete cleanly, but verification "
              "passed — resources are gone.")

    print(f"\nDestroyed {cloud.upper()} cluster: {cluster_name} "
          f"(name={name} env={env_name} region={region})")


if __name__ == "__main__":
    main()
