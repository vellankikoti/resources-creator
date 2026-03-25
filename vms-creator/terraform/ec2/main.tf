# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  env_config = {
    dev     = { instance_type = "t3.medium", cidr = "10.50.0.0/16" }
    qa      = { instance_type = "t3.medium", cidr = "10.50.0.0/16" }
    staging = { instance_type = "t3.large", cidr = "10.50.0.0/16" }
    prod    = { instance_type = "t3.xlarge", cidr = "10.50.0.0/16" }
  }

  selected = { for env in var.environments : env => local.env_config[env] }

  effective_instance_type = {
    for env, cfg in local.selected :
    env => var.instance_type != "" ? var.instance_type : cfg.instance_type
  }

  is_windows = var.os_type == "windows"
  is_linux   = !local.is_windows

  # Select the correct AMI based on os_type
  effective_ami = (
    var.ami_id != "" ? var.ami_id :
    var.os_type == "ubuntu" ? data.aws_ami.ubuntu.id :
    var.os_type == "rocky" ? data.aws_ami.rocky.id :
    data.aws_ami.windows.id
  )

  # Select the correct startup script
  startup_script = (
    var.os_type == "ubuntu" ? file("${path.module}/../../scripts/startup/ubuntu-setup.sh") :
    var.os_type == "rocky" ? file("${path.module}/../../scripts/startup/rocky-setup.sh") :
    file("${path.module}/../../scripts/startup/windows-setup.ps1")
  )

  # SSH user depends on OS
  ssh_user = (
    var.os_type == "ubuntu" ? "ubuntu" :
    var.os_type == "rocky" ? "rocky" :
    "Administrator"
  )

  common_tags = merge(var.tags, {
    account_id = data.aws_caller_identity.current.account_id
    os_type    = var.os_type
  })

  # Ports open for learning (SSH, HTTP, HTTPS, dev servers, K8s)
  ingress_rules = [
    { port = 22, description = "SSH" },
    { port = 80, description = "HTTP" },
    { port = 443, description = "HTTPS" },
    { port = 3000, description = "Dev server (Node/Grafana)" },
    { port = 3389, description = "RDP (Windows)" },
    { port = 5000, description = "Dev server (Flask/Registry)" },
    { port = 5985, description = "WinRM HTTP" },
    { port = 5986, description = "WinRM HTTPS" },
    { port = 6443, description = "Kubernetes API" },
    { port = 8080, description = "Alt HTTP" },
    { port = 8443, description = "Alt HTTPS" },
  ]
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "rocky" {
  most_recent = true
  owners      = ["792107900819"] # Rocky Linux official

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9.*.x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["801119661308"] # Amazon (Microsoft Windows)

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  for_each = local.selected

  cidr_block           = each.value.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-vpc"
    env  = each.key
  })
}

resource "aws_internet_gateway" "main" {
  for_each = local.selected

  vpc_id = aws_vpc.main[each.key].id

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-igw"
    env  = each.key
  })
}

resource "aws_subnet" "public" {
  for_each = local.selected

  vpc_id                  = aws_vpc.main[each.key].id
  cidr_block              = cidrsubnet(each.value.cidr, 8, 1)
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-public"
    env  = each.key
  })
}

resource "aws_route_table" "public" {
  for_each = local.selected

  vpc_id = aws_vpc.main[each.key].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[each.key].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-rt"
    env  = each.key
  })
}

resource "aws_route_table_association" "public" {
  for_each = local.selected

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[each.key].id
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "vm" {
  for_each = local.selected

  name        = "${var.base_name}-${each.key}-vm-sg"
  description = "Open ports for learning VMs - NOT for production"
  vpc_id      = aws_vpc.main[each.key].id

  # Individual port rules
  dynamic "ingress" {
    for_each = local.ingress_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = ingress.value.description
    }
  }

  # NodePort range
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kubernetes NodePort range"
  }

  # ICMP (ping)
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ICMP ping"
  }

  # All egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-sg"
    env  = each.key
  })
}

# ─── SSH Key Pair ─────────────────────────────────────────────────────────────
# Created for all OS types: Linux uses it for SSH, Windows needs it for password decryption

resource "aws_key_pair" "vm" {
  for_each = var.ssh_public_key != "" ? local.selected : {}

  key_name   = "${var.base_name}-${each.key}-vm-key"
  public_key = var.ssh_public_key

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.key}-vm-key"
    env  = each.key
  })
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────

resource "aws_instance" "vm" {
  for_each = {
    for pair in flatten([
      for env, cfg in local.selected : [
        for i in range(var.instance_count) : {
          key = "${env}-${i}"
          env = env
          idx = i
        }
      ]
    ]) : pair.key => pair
  }

  ami                    = local.effective_ami
  instance_type          = local.effective_instance_type[each.value.env]
  subnet_id              = aws_subnet.public[each.value.env].id
  vpc_security_group_ids = [aws_security_group.vm[each.value.env].id]
  key_name               = var.ssh_public_key != "" ? aws_key_pair.vm[each.value.env].key_name : null

  user_data = local.startup_script

  root_block_device {
    volume_size           = local.is_windows ? 50 : 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.base_name}-${each.value.env}-vm-${each.value.idx}"
    env  = each.value.env
  })
}

# ─── Elastic IPs (stable across stop/start) ──────────────────────────────────

resource "aws_eip" "vm" {
  for_each = aws_instance.vm

  instance = each.value.id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${each.value.tags["Name"]}-eip"
    env  = each.value.tags["env"]
  })
}
