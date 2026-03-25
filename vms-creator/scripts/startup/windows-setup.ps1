<powershell>
Write-Output ">>> VM Creator - Windows Server Setup Script"
Write-Output ">>> Starting at $(Get-Date -Format u)"

# ─── Enable TLS 1.2 for downloads ────────────────────────────────────────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── Install Chocolatey package manager ───────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# ─── Common tools via Chocolatey ──────────────────────────────────────────────
choco install -y git curl wget vim jq unzip 7zip

# ─── Docker (Windows containers) ─────────────────────────────────────────────
Install-WindowsFeature -Name Containers
choco install -y docker-desktop

# ─── kubectl ──────────────────────────────────────────────────────────────────
choco install -y kubernetes-cli

# ─── Helm ─────────────────────────────────────────────────────────────────────
choco install -y kubernetes-helm

# ─── OpenSSH Server ───────────────────────────────────────────────────────────
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Allow SSH through Windows Firewall
New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# ─── Open firewall ports for learning ─────────────────────────────────────────
$ports = @(80, 443, 3000, 5000, 6443, 8080, 8443)
foreach ($port in $ports) {
    New-NetFirewallRule -Name "VMCreator-TCP-$port" -DisplayName "VM Creator Port $port" `
      -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $port
}
# NodePort range
New-NetFirewallRule -Name "VMCreator-NodePort" -DisplayName "VM Creator NodePort Range" `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 30000-32767

# ─── Welcome message ─────────────────────────────────────────────────────────
$motd = @"

  =====================================================================
  |              VM Creator Instance (Windows Server)                 |
  |                                                                   |
  |  Pre-installed: docker, kubectl, helm, git, jq, curl             |
  |  Package manager: choco (Chocolatey)                              |
  |                                                                   |
  |  WARNING: This VM has open security groups for learning.          |
  |  Do NOT use this configuration in production.                     |
  =====================================================================

"@
Set-Content -Path "C:\Users\Public\Desktop\VM-Creator-Info.txt" -Value $motd

Write-Output ">>> VM Creator - Windows Server setup completed at $(Get-Date -Format u)"
</powershell>
