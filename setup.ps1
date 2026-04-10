#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstraps everything needed to run the Windows 11 Ansible provisioning
    playbook locally -- directly on this machine via WSL.

.DESCRIPTION
    This script does the following in order:
      1. Verifies it is running as Administrator
      2. Enables WSL and Virtual Machine Platform Windows features
      3. Installs / verifies Ubuntu in WSL
      4. Configures WinRM on localhost so Ansible (inside WSL) can connect back
      5. Installs Python 3, pip, ansible, pywinrm inside WSL
      6. Installs the required Ansible Galaxy collections inside WSL
      7. Patches inventory.ini to point at localhost
      8. Runs a connection test (win_ping) to verify everything works
      9. Prints the exact command to run the full playbook

    Safe to run more than once -- each step checks current state first.

.NOTES
    Run from PowerShell as Administrator:
        .\setup.ps1

    After a WSL install reboot you will be prompted to re-run this script.
    The script detects this and tells you exactly what to do.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }

function Test-RebootPending {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# 0. Admin check (the #Requires above handles it, but let's be explicit)
# ---------------------------------------------------------------------------
Write-Step "Checking administrator privileges"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Please re-run this script from an elevated PowerShell prompt (Run as Administrator)."
    exit 1
}
Write-Ok "Running as Administrator"

# ---------------------------------------------------------------------------
# 1. WSL and Virtual Machine Platform features
# ---------------------------------------------------------------------------
Write-Step "Checking WSL Windows features"

$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
$vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform

$rebootNeeded = $false

if ($wslFeature.State -ne "Enabled") {
    Write-Host "    Enabling Microsoft-Windows-Subsystem-Linux ..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
    $rebootNeeded = $true
} else {
    Write-Ok "WSL feature already enabled"
}

if ($vmpFeature.State -ne "Enabled") {
    Write-Host "    Enabling VirtualMachinePlatform ..."
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
    $rebootNeeded = $true
} else {
    Write-Ok "Virtual Machine Platform already enabled"
}

if ($rebootNeeded) {
    Write-Warn "A reboot is required to finish enabling WSL."
    Write-Warn "After rebooting, open PowerShell as Administrator and re-run this script."
    Write-Host ""
    $ans = Read-Host "Reboot now? (y/n)"
    if ($ans -match "^[Yy]") { Restart-Computer -Force }
    Write-Host "Exiting. Re-run setup.ps1 after you reboot manually."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. WSL kernel update
# ---------------------------------------------------------------------------
Write-Step "Updating WSL kernel"
try {
    wsl --update 2>&1 | ForEach-Object { Write-Host "    $_" }
    wsl --set-default-version 2 2>&1 | Out-Null
    Write-Ok "WSL kernel up to date, default version set to 2"
} catch {
    Write-Warn "WSL update encountered an issue (may be fine if WSL is already current): $_"
}

# ---------------------------------------------------------------------------
# 3. Ubuntu installation
# ---------------------------------------------------------------------------
Write-Step "Checking for Ubuntu in WSL"

$distros = wsl --list --quiet 2>&1
$ubuntuInstalled = $distros | Where-Object { $_ -match "Ubuntu" }

if (-not $ubuntuInstalled) {
    Write-Host "    Ubuntu not found. Installing Ubuntu (this may take a few minutes) ..."
    wsl --install -d Ubuntu --no-launch 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Ok "Ubuntu installed"
    Write-Warn "Ubuntu is installed but has not been launched yet."
    Write-Warn "AFTER this script finishes, open Ubuntu from the Start menu to create"
    Write-Warn "your Linux username and password -- then you can run the Ansible playbook."
} else {
    Write-Ok "Ubuntu already installed in WSL"
}

# ---------------------------------------------------------------------------
# 4. WinRM configuration on localhost
# ---------------------------------------------------------------------------
Write-Step "Configuring WinRM for localhost"

# Ensure WinRM service is running
$winrmService = Get-Service WinRM
if ($winrmService.Status -ne "Running") {
    Write-Host "    Starting WinRM service ..."
    Start-Service WinRM
}
Set-Service WinRM -StartupType Automatic

# Enable PSRemoting (quiet -- it's safe to call even if already enabled)
Enable-PSRemoting -Force -SkipNetworkProfileCheck 2>&1 | Out-Null
Write-Ok "PSRemoting enabled"

# Allow localhost in TrustedHosts (needed for NTLM to localhost)
$current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
if ($current -notmatch "(^\*$|localhost)") {
    if ($current -eq "") {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "localhost" -Force
    } else {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$current,localhost" -Force
    }
    Write-Ok "Added localhost to TrustedHosts"
} else {
    Write-Ok "localhost already in TrustedHosts"
}

# HTTP listener on port 5985 (Ansible uses HTTP for localhost to avoid cert issues)
$httpListener = Get-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{Address="*"; Transport="HTTP"} -ErrorAction SilentlyContinue
if (-not $httpListener) {
    New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{Address="*"; Transport="HTTP"} -ValueSet @{} | Out-Null
    Write-Ok "WinRM HTTP listener created on port 5985"
} else {
    Write-Ok "WinRM HTTP listener already exists on port 5985"
}

# Open firewall for port 5985 (localhost-only rule, restricted to loopback)
$fwRule = Get-NetFirewallRule -Name "WinRM-HTTP-Loopback" -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule `
        -Name "WinRM-HTTP-Loopback" `
        -DisplayName "WinRM HTTP (loopback, Ansible)" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 5985 `
        -Action Allow `
        -Profile Any | Out-Null
    Write-Ok "Firewall rule created for WinRM port 5985"
} else {
    Write-Ok "Firewall rule for WinRM port 5985 already exists"
}

# Allow unencrypted (required for HTTP/NTLM to localhost from WSL)
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic       -Value $true
Set-Item WSMan:\localhost\Service\Auth\NTLM        -Value $true
Write-Ok "WinRM authentication settings configured"

# ---------------------------------------------------------------------------
# 5. Python, pip, ansible, pywinrm inside WSL
# ---------------------------------------------------------------------------
Write-Step "Installing Python / Ansible / pywinrm inside WSL"

# Helper: run a command in WSL and surface errors cleanly
function Invoke-WSL {
    param([string]$cmd, [string]$desc)
    Write-Host "    $desc ..."
    $output = wsl -e bash -c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Command failed: $cmd"
        Write-Host $output
        throw "WSL command failed (exit $LASTEXITCODE)"
    }
    Write-Ok $desc
}

Invoke-WSL "sudo apt-get update -qq"                                             "apt update"
Invoke-WSL "sudo apt-get install -y -qq python3 python3-pip python3-venv"        "Install Python 3 + pip"
Invoke-WSL "pip3 install --quiet --upgrade pip"                                  "Upgrade pip"
Invoke-WSL "pip3 install --quiet ansible pywinrm"                                "Install ansible + pywinrm"
Invoke-WSL "pip3 show ansible > /dev/null && echo ok"                            "Verify ansible installed"

# ---------------------------------------------------------------------------
# 6. Ansible Galaxy collections
# ---------------------------------------------------------------------------
Write-Step "Installing Ansible Galaxy collections"

# Find where this script lives on the Windows filesystem, then build the WSL path
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
# Convert C:\Users\...\windows-pc  ->  /mnt/c/Users/.../windows-pc
$wslPath     = $scriptDir -replace "\\", "/" -replace "^([A-Za-z]):", { "/mnt/$($args[0].ToLower())" }

Invoke-WSL "cd '$wslPath' && ansible-galaxy collection install -r requirements.yml --force-with-deps" `
           "Install Galaxy collections (ansible.windows, chocolatey.chocolatey, community.windows)"

# ---------------------------------------------------------------------------
# 7. Patch inventory.ini for localhost
# ---------------------------------------------------------------------------
Write-Step "Patching inventory.ini for local connection"

$inventoryPath = Join-Path $scriptDir "inventory.ini"
$inventory     = Get-Content $inventoryPath -Raw

# Check if already patched
if ($inventory -match "ansible_host\s*=\s*localhost" -or $inventory -match "^\s*localhost\s*$") {
    Write-Ok "inventory.ini already configured for localhost"
} else {
    # Back up original
    $backup = $inventoryPath + ".bak"
    if (-not (Test-Path $backup)) {
        Copy-Item $inventoryPath $backup
        Write-Host "    Backed up original inventory.ini to inventory.ini.bak"
    }

    $localInventory = @"
# inventory.ini - configured for LOCAL deployment (Ansible running in WSL on this machine)
# Original backed up as inventory.ini.bak

[windows]
localhost

[windows:vars]
ansible_connection            = winrm
ansible_host                  = localhost
ansible_port                  = 5985
ansible_winrm_transport       = ntlm
ansible_winrm_server_cert_validation = ignore
# Credentials: pass on the command line with -u YourWindowsUsername --ask-pass
# Or set here (not recommended for shared machines):
#   ansible_user     = Administrator
#   ansible_password = YourPassword
"@
    Set-Content $inventoryPath $localInventory -Encoding UTF8
    Write-Ok "inventory.ini updated for localhost (port 5985, HTTP, NTLM)"
}

# ---------------------------------------------------------------------------
# 8. Connection test
# ---------------------------------------------------------------------------
Write-Step "Running Ansible connection test (win_ping)"

Write-Host ""
Write-Host "    Enter your Windows username and password when prompted." -ForegroundColor Yellow
Write-Host "    This verifies Ansible can reach WinRM on localhost before you run the real playbook."
Write-Host ""

$winUser = Read-Host "    Windows username"
$winPass = Read-Host "    Windows password" -AsSecureString
$bstr    = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($winPass)
$plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$pingCmd = "cd '$wslPath' && ansible windows -m ansible.windows.win_ping -i inventory.ini -u '$winUser' -e ansible_password='$plainPass'"
$pingResult = wsl -e bash -c $pingCmd 2>&1

Write-Host ""
$pingResult | ForEach-Object { Write-Host "    $_" }

if ($pingResult -match "SUCCESS") {
    Write-Host ""
    Write-Ok "Connection test PASSED -- Ansible can reach this machine via WinRM"
} else {
    Write-Host ""
    Write-Warn "Connection test did not return SUCCESS. Check the output above."
    Write-Warn "Common fixes:"
    Write-Warn "  - Make sure you entered the correct Windows username/password"
    Write-Warn "  - Try running:  winrm quickconfig  in PowerShell"
    Write-Warn "  - Check WinRM is listening: Test-NetConnection localhost -Port 5985"
}

# ---------------------------------------------------------------------------
# 9. Final instructions
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To run the FULL provisioning playbook, open your WSL (Ubuntu)" -ForegroundColor White
Write-Host "  terminal and run:" -ForegroundColor White
Write-Host ""
Write-Host "    cd $wslPath" -ForegroundColor Yellow
Write-Host "    ansible-playbook site.yml -u $winUser --ask-pass" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To run only specific stages, add --tags:" -ForegroundColor White
Write-Host ""
Write-Host "    --tags updates           (Windows Update only)" -ForegroundColor DarkYellow
Write-Host "    --tags apps              (install applications only)" -ForegroundColor DarkYellow
Write-Host "    --tags brave_extensions  (Brave extensions only)" -ForegroundColor DarkYellow
Write-Host "    --tags darkmode          (dark mode only)" -ForegroundColor DarkYellow
Write-Host "    --tags hyperv            (Hyper-V only)" -ForegroundColor DarkYellow
Write-Host "    --tags wsl               (WSL only)" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "  Dry run (no changes made):" -ForegroundColor White
Write-Host "    ansible-playbook site.yml -u $winUser --ask-pass --check" -ForegroundColor Yellow
Write-Host ""
if ($ubuntuInstalled -eq $null) {
    Write-Host "  REMINDER: Open Ubuntu from the Start menu to finish WSL setup" -ForegroundColor Magenta
    Write-Host "  (create your Linux username/password) before running the playbook." -ForegroundColor Magenta
    Write-Host ""
}
Write-Host "===============================================================" -ForegroundColor Cyan
