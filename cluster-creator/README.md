# cluster-creator

One command creates a real Kubernetes cluster on AWS, GCP, or Azure. Networking, node pools, ingress, metrics, storage — all set up and tested before you get the kubeconfig back.

```bash
./scripts/create-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
```

That's it. About fifteen minutes later you have an EKS cluster that's ready to use.

## Why this exists

Setting up a real Kubernetes cluster by hand is a lot of work. You need private subnets, NAT gateways, the right IAM roles, an ingress controller that actually routes traffic, metrics, autoscaling, and a default storage class. Doing all of that correctly takes hours the first time. Doing it the same way on AWS, GCP, and Azure takes even longer.

This repo is the script I wish I had the first ten times I did it by hand. It picks sensible defaults, names everything in a predictable way so two people can't accidentally overwrite each other's clusters, and — importantly — it cleans up after itself when you're done.

## What you get

| Layer         | AWS (EKS)                              | GCP (GKE)                          | Azure (AKS)                    |
|---------------|----------------------------------------|------------------------------------|--------------------------------|
| Networking    | VPC, 3× private + 3× public subnets, NAT GW | Custom VPC, subnet, Cloud Router + NAT | Resource group, VNet, subnet   |
| Control plane | Managed EKS, KMS-encrypted secrets     | Regional GKE, private nodes        | Managed AKS, OIDC + workload identity |
| Node pools    | `on-demand` + `spot`                   | `ondemand` + `spot`                | `system` + `spot`              |
| Addons        | CoreDNS, kube-proxy, VPC CNI, EBS/EFS CSI, NGINX ingress, metrics-server, cluster-autoscaler | NGINX ingress, metrics-server (GKE handles autoscaling natively) | NGINX ingress, metrics-server (AKS handles autoscaling natively) |
| Storage       | `gp3-encrypted`                        | `pd-balanced-encrypted`            | `managed-csi-premium`          |
| K8s version   | 1.34                                   | 1.34                               | 1.34                           |

On top of that, every cluster gets the same basic setup applied: namespaces, network policies, priority classes, resource quotas, limit ranges, and pod disruption budgets — so `dev` and `prod` behave the same across clouds.

## Prerequisites

You need these installed locally:

- `terraform` 1.7+
- `aws`, `gcloud`, and/or `az` CLIs (only the cloud you're using)
- `kubectl` 1.29+
- `helm` 3.14+
- `jq`

And you need to be authenticated:

```bash
aws sts get-caller-identity      # AWS
gcloud config get-value project  # GCP
az account show                  # Azure
```

If any of those commands come back empty, fix that first. The script will stop early if you're not logged in, but the error messages from the cloud CLIs are easier to read than the ones Terraform gives you.

## Creating a cluster

```bash
# AWS
./scripts/create-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1

# GCP
./scripts/create-cluster.sh --cloud gcp --name mycluster --env dev --region us-central1

# Azure
./scripts/create-cluster.sh --cloud azure --name mycluster --env dev --region eastus
```

Flags that matter:

| Flag | What |
|------|------|
| `--cloud`            | `aws`, `gcp`, or `azure` |
| `--name`             | A name for your cluster. The script adds a short hash of your account / project / subscription ID so two people running `--name mycluster` in different accounts can't clash. |
| `--env`              | `dev`, `qa`, `staging`, or `prod`. Controls size, network range, and whether NAT gateways are highly available. |
| `--region`           | Any region your cloud supports. |
| `--public-api`       | Make the API server reachable from the internet (limited to your own IP). Default is private. |
| `--full-validation`  | Run extra validation tests (PVC bind, ingress HTTP check, autoscaler scale up and down). |
| `--yes` / `-y`       | Non-interactive mode. If a preflight check fails, the script stops instead of asking you a question. |

When it finishes, you'll see a summary with the cluster name, kubeconfig context, ingress endpoint, and the default storage class. The kubeconfig context is already set up for you.

## Destroying a cluster

```bash
./scripts/destroy-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
```

Use the same name, env, and region as when you created it. The destroy flow is the reverse of create, but with some extra safety:

- It deletes Kubernetes `LoadBalancer` services *before* running `terraform destroy`. Those services create cloud load balancers that Terraform doesn't track, and if you leave them around they block the VPC from being deleted.
- It retries `terraform destroy` up to 3 times, running a cleanup sweep between each try.
- After Terraform finishes, it checks on its own that the VPC (or VNet or network) is actually gone. If something is still there, it runs the cleanup sweep again and retries. If it still can't clean everything up, it stops and tells you exactly what's left instead of pretending it worked.

## Features that save you from common problems

A few things are in here because I ran into them the hard way:

**VPC quota check before Terraform runs.** If your AWS region already has 5 VPCs (the default limit), `create-cluster.sh` notices this *before* Terraform starts and gives you three options: stop, clean up an old leftover VPC (with a simple picker), or print the link where you can request a higher limit. Same thing for Azure VNets and GCP networks. In non-interactive mode (`--yes` or CI), it stops with a clear message telling you what to do.

**Leftover resource cleanup.** When you pick "clean up an old VPC", it uses the same cleanup logic that the destroy flow uses — removing NAT gateways, load balancers, network interfaces, security groups, route tables, and finally the VPC itself.

**Double-checking after destroy.** The destroy command doesn't just trust Terraform. After `terraform destroy` finishes, it checks on its own whether the VPC, VNet, or network is really gone. This catches the cases where Terraform says it succeeded but actually left some leftover resources — usually because a Kubernetes LoadBalancer or an EKS-managed network interface was still holding on.

## Repository layout

```
cluster-creator/
├── scripts/              # The shell entrypoints (primary interface)
│   ├── create-cluster.sh
│   ├── destroy-cluster.sh
│   ├── preflight-check.sh
│   ├── bootstrap.sh        # Helm installs + common resources
│   ├── validation.sh       # Post-create health checks
│   ├── backend-lib.sh      # The big one — shared helpers, quota checks, cleanup
│   ├── cluster-upgrade.sh
│   └── ...
├── python/               # Same flow, Python entrypoint (if you prefer)
│   ├── create_cluster.py
│   ├── destroy_cluster.py
│   └── cluster_lib.py
├── terraform/
│   ├── eks/              # AWS root module
│   ├── gke/              # GCP root module
│   ├── aks/              # Azure root module
│   ├── vcluster/         # Run a vcluster on top of an existing cluster
│   └── modules/
├── addons/               # Helm values for ingress, observability, etc.
├── common-resources/     # Cluster-wide K8s manifests applied on every bootstrap
└── environments/         # Per-env variables (dev/qa/staging/prod)
```

## Environments

`dev`, `qa`, `staging`, and `prod` are not just labels. They actually change how the cluster is built:

- **Network ranges** are different for each environment, so two environments in the same account never clash.
- **Size** goes up with each step: `dev` runs with 1 on-demand node, `prod` starts with 2 or 3.
- **NAT gateways**: non-prod uses one NAT gateway (cheaper), prod uses one per availability zone (more reliable).
- **Log retention**: 7 days for non-prod, 14 days for prod.
- **Cluster name**: `<base>-<env>-<eks|gke|aks>` with a short hash of your account at the end to keep it unique.

Every environment is its own cluster. There is no shared control plane and no "dev namespace on the prod cluster" shortcut.

## Upgrading

```bash
./scripts/cluster-upgrade.sh --cloud aws --cluster <cluster-name> --region us-east-1 --version 1.34
```

It upgrades the control plane first, then the node pools, using the rolling-update settings in Terraform (`max_unavailable=25%` on EKS, `max_surge=1` on GKE, `max_surge=33%` on AKS). Run `validation.sh` again afterwards to make sure nothing broke.

## Before using this in production

This script gives you a working cluster. It does not make it safe for production traffic. Before you put anything important on it, please go through this list:

- [ ] Lock down the API server to specific IP ranges (especially on GKE — the default is open)
- [ ] Turn on control plane audit logging and send the logs somewhere central
- [ ] Review IAM roles and permissions, remove anything you don't need
- [ ] Pick and set up a backup strategy (etcd snapshots, Velero, or PV backups)
- [ ] Add policy guardrails (OPA/Gatekeeper or Kyverno)
- [ ] Add image scanning and signing to your CI
- [ ] Move Terraform state to the remote backend (there's a script: `scripts/render-backends.sh`)

This repo gives you a cluster you can use. Making it safe and compliant is your job.

## Things to know

- Cluster-autoscaler is set up for you on EKS using IRSA. GKE and AKS use their built-in autoscalers, which work fine but behave slightly differently across clouds.
- `create-cluster.sh` writes Terraform variables to a temporary folder at runtime. This is on purpose — it keeps sensitive values out of the repo — but it means you can't run `terraform plan` directly without going through the script.
- There's no automatic backup tool. Velero lives in `addons/` but is not installed by default.
- vCluster (running a Kubernetes cluster inside another cluster) is available under `terraform/vcluster/` but is not part of the main create flow.

## When something goes wrong

If something breaks, `RUNBOOK.md` has the step-by-step troubleshooting guide (preflight, terraform apply, ingress, autoscaler, PVC). The short version:

- **Preflight fails** → check that you are logged in to the cloud CLI first, then check tool versions.
- **Terraform apply fails partway through** → run the same command again. It is safe to re-run.
- **`VpcLimitExceeded` or a similar quota error** → the preflight should have caught this. If it didn't, you're probably on an older version of the repo. Pull the latest changes.
- **Destroy finished but left some resources behind** → run `create-cluster.sh` with the same name. The preflight will offer to clean up the leftover VPC for you.

---

I built this for myself. Sharing it in case it saves you some time too.
