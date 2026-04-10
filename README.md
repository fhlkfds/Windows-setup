# Windows 11 Provisioning Playbook

Ansible automation for provisioning a Windows 11 workstation from scratch. This playbook handles Windows Updates, application installation, browser extension deployment, dark mode configuration, Hyper-V enablement, and WSL setup.

## What This Playbook Does

| Tag | Description |
|-----|-------------|
| `updates` | Installs all available Windows Updates (multiple passes with reboots) |
| `apps` | Installs applications via Chocolatey (Brave, Obsidian, Steam, Discord, Tailscale, Sysinternals, PowerToys, Spotify) |
| `brave_extensions` | Force-installs Brave browser extensions via Chromium enterprise policy |
| `darkmode` | Configures Windows system and app dark mode |
| `hyperv` | Detects hardware support and enables Hyper-V |
| `wsl` | Enables WSL 2 and installs Ubuntu (configurable) |

## Prerequisites

### On the Ansible Control Node (Linux/macOS/WSL)

```bash
# 1. Install Ansible (2.15+)
pip install ansible

# 2. Install pywinrm for WinRM connectivity
pip install pywinrm

# 3. Install required Ansible collections
ansible-galaxy collection install -r requirements.yml
```

### On the Target Windows 11 Machine

WinRM must be configured to allow Ansible to connect. Run this PowerShell script **as Administrator** on the target:

```powershell
# Option A: Quick setup (HTTPS with self-signed cert, suitable for lab/home use)
# Download and run the Ansible WinRM configuration script:
$url = "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
$file = "$env:temp\ConfigureRemotingForAnsible.ps1"
(New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)
powershell.exe -ExecutionPolicy ByPass -File $file

# Option B: Manual setup (if you prefer to understand each step)
# Enable WinRM service
Enable-PSRemoting -Force

# Set WinRM to start automatically
Set-Service WinRM -StartupType Automatic

# Configure WinRM for HTTPS (create self-signed cert)
$cert = New-SelfSignedCertificate -DnsName $(hostname) -CertStoreLocation Cert:\LocalMachine\My
New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force

# Open firewall for WinRM HTTPS
New-NetFirewallRule -Name "WinRM-HTTPS" -DisplayName "WinRM HTTPS" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow

# Set TrustedHosts (restrict in production to specific IPs)
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
```

Verify WinRM is working:

```powershell
winrm quickconfig
winrm get winrm/config
```

## Configuration

### Inventory

Edit `inventory.ini` to set your target hostname/IP:

```ini
[windows]
192.168.1.100

[windows:vars]
ansible_connection = winrm
ansible_port = 5986
ansible_winrm_transport = ntlm
ansible_winrm_server_cert_validation = ignore
```

### Variables

All configurable options are in `group_vars/windows.yml`:

- **chocolatey_packages**: List of applications to install
- **brave_extensions**: List of browser extensions (id + name)
- **windows_update_max_cycles**: How many update passes to run (default: 3)
- **wsl_default_distro**: Which Linux distro to install (default: Ubuntu)
- **enable_dark_mode**: Toggle dark mode on/off (default: true)

Override per-host by creating `host_vars/<hostname>.yml`.

### Credentials

Never put passwords in plaintext files. Use one of:

```bash
# Option 1: Command-line prompts
ansible-playbook site.yml --ask-pass

# Option 2: Environment variables
export ANSIBLE_WINRM_USER=Administrator
export ANSIBLE_WINRM_PASS=YourSecurePassword
ansible-playbook site.yml

# Option 3: Ansible Vault (recommended for automation)
ansible-vault create vault.yml
# Add: ansible_user: Administrator
#      ansible_password: YourSecurePassword
ansible-playbook site.yml --extra-vars @vault.yml --ask-vault-pass
```

## Usage

### Full Provisioning Run

```bash
ansible-playbook site.yml -i inventory.ini --ask-pass
```

### Run Specific Sections

```bash
# Only install Windows Updates
ansible-playbook site.yml -i inventory.ini --ask-pass --tags updates

# Only install applications
ansible-playbook site.yml -i inventory.ini --ask-pass --tags apps

# Only configure Brave extensions
ansible-playbook site.yml -i inventory.ini --ask-pass --tags brave_extensions

# Only set dark mode
ansible-playbook site.yml -i inventory.ini --ask-pass --tags darkmode

# Only enable Hyper-V
ansible-playbook site.yml -i inventory.ini --ask-pass --tags hyperv

# Only set up WSL
ansible-playbook site.yml -i inventory.ini --ask-pass --tags wsl

# Combine tags
ansible-playbook site.yml -i inventory.ini --ask-pass --tags "apps,darkmode"
```

### Dry Run (Check Mode)

```bash
ansible-playbook site.yml -i inventory.ini --ask-pass --check
```

### Verbose Output

```bash
ansible-playbook site.yml -i inventory.ini --ask-pass -vvv
```

## Post-Provisioning Manual Steps

1. **Dark mode**: Log out and back in for full visual refresh
2. **Brave extensions**: Launch Brave browser; extensions will install automatically within a few minutes. If Brave was already running, restart it.
3. **WSL / Ubuntu**: Launch Ubuntu from the Start menu to complete first-time setup (create UNIX user account)
4. **Tailscale**: Launch Tailscale and authenticate with your account
5. **Extension settings**: Individual extension configurations (uBlock filter lists, SponsorBlock categories, Bitwarden login, etc.) must be done manually within each extension

## Project Structure

```
windows-pc/
├── ansible.cfg                         # Ansible configuration
├── inventory.ini                       # Target hosts
├── requirements.yml                    # Galaxy collection dependencies
├── site.yml                            # Main playbook
├── group_vars/
│   └── windows.yml                     # Variables for all Windows hosts
├── host_vars/                          # Per-host variable overrides
└── roles/
    ├── windows_updates/
    │   └── tasks/main.yml              # Windows Update with multi-pass
    ├── chocolatey_apps/
    │   ├── tasks/main.yml              # Chocolatey package installation
    │   └── handlers/main.yml           # Post-install reboot handler
    ├── brave_extensions/
    │   └── tasks/main.yml              # Brave extension force-install
    ├── dark_mode/
    │   └── tasks/main.yml              # System + app dark mode
    ├── hyperv/
    │   ├── tasks/main.yml              # Hyper-V detection + enablement
    │   └── handlers/main.yml           # Post-enable reboot handler
    └── wsl/
        └── tasks/main.yml              # WSL 2 + distro setup
```

## Troubleshooting

### WinRM Connection Failures

```bash
# Test connectivity from control node
ansible windows -m ansible.windows.win_ping -i inventory.ini --ask-pass

# If using NTLM and getting 401 errors, try:
ansible_winrm_transport: credssp
# (requires 'pip install pywinrm[credssp]')
```

### Windows Update Hangs

The playbook sets a 2-hour timeout per update cycle. If updates consistently hang:
- Connect to the machine and check `C:\Windows\Logs\WindowsUpdate\` for errors
- Try running Windows Update manually once, then re-run the playbook

### Hyper-V Skipped

If Hyper-V reports unsupported:
- Check BIOS/UEFI settings: enable Intel VT-x or AMD-V
- Ensure Windows edition is Pro, Enterprise, or Education
- Verify with: `systeminfo | findstr /i "hyper-v"`

### Brave Extensions Not Appearing

- Close and reopen Brave completely
- Check policy is applied: navigate to `brave://policy` in Brave
- Run `gpupdate /force` on the target machine
- Verify registry: `Get-ItemProperty "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist"`
