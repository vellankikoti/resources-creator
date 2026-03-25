# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  env_config = {
    dev     = { vm_size = "Standard_B2s", cidr = "10.52.0.0/16" }
    qa      = { vm_size = "Standard_B2s", cidr = "10.52.0.0/16" }
    staging = { vm_size = "Standard_D2s_v3", cidr = "10.52.0.0/16" }
    prod    = { vm_size = "Standard_D4s_v3", cidr = "10.52.0.0/16" }
  }

  selected = { for env in var.environments : env => local.env_config[env] }

  effective_vm_size = {
    for env, cfg in local.selected :
    env => var.vm_size != "" ? var.vm_size : cfg.vm_size
  }

  is_windows = var.os_type == "windows"
  is_linux   = !local.is_windows

  # Admin username per OS
  effective_admin_username = (
    var.admin_username != "" ? var.admin_username :
    var.os_type == "ubuntu" ? "azureuser" :
    var.os_type == "rocky" ? "azureuser" :
    "adminuser"
  )

  # Generate a password for Windows if not provided
  effective_admin_password = var.admin_password != "" ? var.admin_password : "VMcreator2024!"

  # Image reference per OS
  image_reference = {
    ubuntu = {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
    rocky = {
      publisher = "resf"
      offer     = "rockylinux-x86_64"
      sku       = "9-base"
      version   = "latest"
    }
    windows = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2022-datacenter-g2"
      version   = "latest"
    }
  }

  common_tags = merge(var.tags, {
    tenant_id = data.azurerm_client_config.current.tenant_id
    os_type   = var.os_type
  })

  # Ports open for learning
  ingress_rules = [
    { priority = 100, port = "22", name = "SSH" },
    { priority = 110, port = "80", name = "HTTP" },
    { priority = 120, port = "443", name = "HTTPS" },
    { priority = 130, port = "3000", name = "DevServer-3000" },
    { priority = 135, port = "3389", name = "RDP" },
    { priority = 140, port = "5000", name = "DevServer-5000" },
    { priority = 145, port = "5985-5986", name = "WinRM" },
    { priority = 150, port = "6443", name = "KubeAPI" },
    { priority = 160, port = "8080", name = "AltHTTP" },
    { priority = 170, port = "8443", name = "AltHTTPS" },
    { priority = 200, port = "30000-32767", name = "NodePort" },
  ]

  # Flatten instances for resource creation
  vm_instances = {
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
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

# ─── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  for_each = local.selected

  name     = "rg-${var.base_name}-${each.key}-vm"
  location = var.region

  tags = merge(local.common_tags, { env = each.key })
}

# ─── Networking ───────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  for_each = local.selected

  name                = "vnet-${var.base_name}-${each.key}-vm"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.key].name
  address_space       = [each.value.cidr]

  tags = merge(local.common_tags, { env = each.key })
}

resource "azurerm_subnet" "main" {
  for_each = local.selected

  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.main[each.key].name
  virtual_network_name = azurerm_virtual_network.main[each.key].name
  address_prefixes     = [cidrsubnet(each.value.cidr, 8, 1)]
}

# ─── Network Security Group ──────────────────────────────────────────────────

resource "azurerm_network_security_group" "main" {
  for_each = local.selected

  name                = "nsg-${var.base_name}-${each.key}-vm"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.key].name

  dynamic "security_rule" {
    for_each = local.ingress_rules
    content {
      name                       = "Allow-${security_rule.value.name}"
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }

  # ICMP
  security_rule {
    name                       = "Allow-ICMP"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = merge(local.common_tags, { env = each.key })
}

# ─── Public IPs ───────────────────────────────────────────────────────────────

resource "azurerm_public_ip" "vm" {
  for_each = local.vm_instances

  name                = "pip-${var.base_name}-${each.value.env}-vm-${each.value.idx}"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.value.env].name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = merge(local.common_tags, { env = each.value.env })
}

# ─── Network Interfaces ──────────────────────────────────────────────────────

resource "azurerm_network_interface" "vm" {
  for_each = local.vm_instances

  name                = "nic-${var.base_name}-${each.key}"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.value.env].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main[each.value.env].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }

  tags = merge(local.common_tags, { env = each.value.env })
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = azurerm_network_interface.vm

  network_interface_id      = each.value.id
  network_security_group_id = azurerm_network_security_group.main[split("-", each.key)[0]].id
}

# ─── Linux Virtual Machines ──────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.is_linux ? local.vm_instances : {}

  name                = "${var.base_name}-${each.key}-vm"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.value.env].name
  size                = local.effective_vm_size[each.value.env]

  admin_username                  = local.effective_admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = local.effective_admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = local.image_reference[var.os_type].publisher
    offer     = local.image_reference[var.os_type].offer
    sku       = local.image_reference[var.os_type].sku
    version   = local.image_reference[var.os_type].version
  }

  # Rocky Linux from marketplace requires plan
  dynamic "plan" {
    for_each = var.os_type == "rocky" ? [1] : []
    content {
      name      = local.image_reference["rocky"].sku
      publisher = local.image_reference["rocky"].publisher
      product   = local.image_reference["rocky"].offer
    }
  }

  custom_data = base64encode(
    var.os_type == "ubuntu"
    ? file("${path.module}/../../scripts/startup/ubuntu-setup.sh")
    : file("${path.module}/../../scripts/startup/rocky-setup.sh")
  )

  tags = merge(local.common_tags, {
    env  = each.value.env
    name = "${var.base_name}-${each.key}-vm"
  })
}

# ─── Windows Virtual Machines ─────────────────────────────────────────────────

resource "azurerm_windows_virtual_machine" "vm" {
  for_each = local.is_windows ? local.vm_instances : {}

  name                = "${var.base_name}-${each.key}-vm"
  location            = var.region
  resource_group_name = azurerm_resource_group.main[each.value.env].name
  size                = local.effective_vm_size[each.value.env]

  admin_username = local.effective_admin_username
  admin_password = local.effective_admin_password

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 50
  }

  source_image_reference {
    publisher = local.image_reference["windows"].publisher
    offer     = local.image_reference["windows"].offer
    sku       = local.image_reference["windows"].sku
    version   = local.image_reference["windows"].version
  }

  custom_data = base64encode(file("${path.module}/../../scripts/startup/windows-setup.ps1"))

  tags = merge(local.common_tags, {
    env  = each.value.env
    name = "${var.base_name}-${each.key}-vm"
  })
}
