# resources-creator

One-command cloud infrastructure for learning, experiments, and real work — across AWS, GCP, and Azure.

This repo gives you two tools:

| Tool | What it builds | Use it when you want… |
|------|----------------|-----------------------|
| [**cluster-creator**](./cluster-creator) | A real Kubernetes cluster (EKS, GKE, or AKS) with networking, node pools, ingress, metrics, and storage already set up | A production-shaped cluster you can actually deploy to |
| [**vms-creator**](./vms-creator) | Virtual machines on EC2, Compute Engine, or Azure VMs — Ubuntu, Rocky Linux, or Windows Server | Lab machines, tutorials, or a quick place to test something |

Both tools follow the same idea: you run one command, wait a few minutes, and you get something that works. When you're done, you run one destroy command and everything is cleaned up — including the leftover pieces that Terraform alone usually misses.

## Why this exists

Setting up cloud infrastructure correctly takes a lot of steps. Setting it up the same way on three different clouds takes even more. Every time I did it by hand I forgot something — a missing route, the wrong security group, a subnet tag that Kubernetes needed. After doing this too many times, I wrote these scripts so I wouldn't have to think about it again.

The goal is simple: one command in, one command out. Safe defaults. Predictable names so nothing clashes. And good cleanup so your cloud bill doesn't keep growing after you're done.

## Quick start

Pick the tool you need and follow the README in that folder.

**Create a Kubernetes cluster:**

```bash
cd cluster-creator
./scripts/create-cluster.sh --cloud aws --name mycluster --env dev --region us-east-1
```

**Create a virtual machine:**

```bash
cd vms-creator
./scripts/create-vm.sh --cloud aws --name myvm --env dev --region us-east-1
```

Both tools support `aws`, `gcp`, and `azure` with the same flag style.

## What you need

The same tools for both projects:

- [Terraform](https://developer.hashicorp.com/terraform/downloads) 1.7 or newer
- The CLI for the cloud you want to use:
  - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  - [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install)
  - [Azure CLI (`az`)](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- For clusters only: `kubectl` 1.29+, `helm` 3.14+, `jq`

You also need to be logged in to the cloud you plan to use:

```bash
aws sts get-caller-identity      # AWS
gcloud config get-value project  # GCP
az account show                  # Azure
```

If any of these come back empty, log in first. The scripts will stop early with a clear message if you're not authenticated.

## Repository layout

```
resources-creator/
├── cluster-creator/   # Kubernetes clusters on EKS, GKE, AKS
│   ├── scripts/         # Shell entry points (primary interface)
│   ├── python/          # Same flow in Python, if you prefer
│   ├── terraform/       # Terraform modules for each cloud
│   ├── addons/          # Helm values for ingress, metrics, etc.
│   ├── common-resources/# Kubernetes manifests applied to every cluster
│   └── environments/    # dev / qa / staging / prod variables
│
└── vms-creator/       # VMs on EC2, Compute Engine, Azure VMs
    ├── scripts/
    ├── python/
    ├── terraform/
    └── environments/
```

Each subproject has its own README with the full details and its own RUNBOOK with troubleshooting steps.

## Design choices

A few things are true for both tools, because they solved real problems:

- **Predictable names.** Every resource name includes a short hash of your cloud account or project ID, so two people running the same command in different accounts can't accidentally clash.
- **Separate environments.** `dev`, `qa`, `staging`, and `prod` get different network ranges and sizes. They are never the same cluster or VPC.
- **Pre-flight checks.** Before Terraform runs, the scripts check your cloud quotas. If you're about to hit a limit, you get a clear message and a few options — not a confusing error from Terraform 20 minutes into the apply.
- **Safe cleanup.** The destroy commands go through Terraform, then double-check that everything is actually gone. If Terraform missed something (a LoadBalancer service, a leftover network interface), the script finds it and cleans it up.
- **One version of Kubernetes and one default OS per cloud.** Less choice means fewer things to test and fewer surprises.

## Safety and cost notes

- These tools create real cloud resources that cost real money. Don't forget to run the destroy command when you're done.
- The defaults are chosen for learning and development, not for production compliance. Before using any cluster or VM for production workloads, please read the "Before using this in production" section of the relevant README.
- `cluster-creator` uses spot instances by default for non-prod environments. Spot saves money but can be taken away by the cloud provider at any time.
- `vms-creator` opens several ports by default (SSH, HTTP, HTTPS, Kubernetes NodePort, and others) so you can test things easily. This is fine for a lab but should be tightened before you run anything important.

## When something goes wrong

Each subproject has its own RUNBOOK:

- [`cluster-creator/RUNBOOK.md`](./cluster-creator/RUNBOOK.md) — for Kubernetes cluster issues
- [`vms-creator/RUNBOOK.md`](./vms-creator/RUNBOOK.md) — for VM issues

The short version: check that you're logged in to your cloud CLI, re-run the command (both tools are safe to re-run), and if you see a quota error, the pre-flight check should guide you through fixing it.

## License and contributing

This is a personal project shared openly. Feel free to use it, fork it, or open issues and pull requests if something isn't working. If you add a new feature or cloud, please also update the relevant RUNBOOK so the next person knows what to do when it breaks.

---

Built for my own sanity. Sharing it in case it saves you some time too.
