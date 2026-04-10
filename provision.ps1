#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provisions a Windows 11 machine from scratch: updates, apps, Brave extensions,
    dark mode, Hyper-V, and WSL. No Ansible or WSL required to run this.

.DESCRIPTION
    Direct PowerShell replacement for the Ansible playbook in this directory.
    Run this script once on the target machine as Administrator and it handles
    everything automatically, including reboots.

    Progress is saved to provision_state.json so re-running after a reboot
    continues from where it left off. A scheduled task re-runs the script
    automatically after reboot-requiring stages.

.PARAMETER Only
    Run only specific stage(s). Accepts one or more of:
      updates, apps, brave_extensions, darkmode, hyperv, wsl
    Default: all stages in order.

.PARAMETER Force
    Re-run a stage even if it is already marked complete in the state file.

.PARAMETER WslDistro
    Linux distribution to install with WSL. Default: Ubuntu
    See available distros: wsl --list --online

.PARAMETER SkipUpdates
    Skip the Windows Update stage entirely.

.EXAMPLE
    # Full provisioning run
    .\provision.ps1

    # Only install apps
    .\provision.ps1 -Only apps

    # Hyper-V and WSL only
    .\provision.ps1 -Only hyperv,wsl

    # Re-run dark mode even if already marked done
    .\provision.ps1 -Only darkmode -Force

    # Everything except updates
    .\provision.ps1 -SkipUpdates

.NOTES
    Must be run as Administrator.
    Expected total time on a fresh Windows 11 install: 1-3 hours (mostly Windows Update).
#>

[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$Force,
    [string]$WslDistro   = 'Ubuntu',
    [switch]$SkipUpdates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration -- edit these to customise what gets installed
# ---------------------------------------------------------------------------

$ChocolateyPackages = @(
    'brave',
    'obsidian',
    'steam',
    'discord',
    'tailscale',
    'sysinternals',
    'powertoys',
    'spotify'
)

# Extension IDs from the Chrome Web Store.
# To add an extension: find its ID in the CWS URL and add an entry below.
$BraveExtensions = @(
    @{ id = 'nngceckbapebfimnlniiiahkandclblb'; name = 'Bitwarden' },
    @{ id = 'pnidmkljnhbjfffciajlcpeldoljnidn'; name = 'Linkwarden' },
    @{ id = 'ddkjiahejlhfcafbddmgiahcphecmpfh'; name = 'uBlock Origin Lite' },
    @{ id = 'ldpochfccmkkmhdbclfhpagapcfdljkj'; name = 'Decentraleyes' },
    @{ id = 'cnjifjpddelmedmihgijeibhnjfabmlf'; name = 'Obsidian Web Clipper' },
    @{ id = 'pkehgijcmpdhfbdbbnkijodmdjhbjlgp'; name = 'Privacy Badger' },
    @{ id = 'gebbhagfogifgggkldgodflihgfeippi'; name = 'Return YouTube Dislike' },
    @{ id = 'mnjggcdmjocbbbhaepdhchncahnbgone'; name = 'SponsorBlock for YouTube' },
    @{ id = 'hjdoplcnndgiblooccencgcggcoihigg'; name = "Terms of Service; Didn't Read" },
    @{ id = 'pocpnlppkickgojjlmhdmidojbmbodfm'; name = 'Chromebook Recovery Utility' }
)

# Chrome Web Store update endpoint -- all CWS extensions share this URL
$BraveExtUpdateUrl = 'https://clients2.google.com/service/update2/crx'
$BraveExtRegPath   = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist'

# How many Windows Update passes to run.
# Multiple passes are needed because updates often unlock further updates.
$UpdateMaxCycles = 3

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------
$ScriptPath        = $MyInvocation.MyCommand.Path
$StateFile         = Join-Path $PSScriptRoot 'provision_state.json'
$ScheduledTaskName = 'Provision-Windows11-Continue'
$AllStages         = @('updates', 'apps', 'brave_extensions', 'darkmode', 'hyperv', 'wsl')

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Stage([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)  { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Info([string]$msg)  { Write-Host "           $msg" -ForegroundColor White }
function Write-Skip([string]$msg)  { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# State management
# Tracks completed stages and update cycle count across reboots via a JSON file.
# ---------------------------------------------------------------------------
function Get-State {
    if (Test-Path $StateFile) {
        try {
            $raw = Get-Content $StateFile -Raw | ConvertFrom-Json
            # Ensure required properties exist
            if ($null -eq $raw.PSObject.Properties['completed'])           { $raw | Add-Member -NotePropertyName 'completed'           -NotePropertyValue @() }
            if ($null -eq $raw.PSObject.Properties['updateCyclesDone'])    { $raw | Add-Member -NotePropertyName 'updateCyclesDone'    -NotePropertyValue 0 }
            return $raw
        } catch { }
    }
    return [PSCustomObject]@{
        completed        = @()
        updateCyclesDone = 0
    }
}

function Save-State([PSCustomObject]$state) {
    $state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8
}

function Test-StageComplete([string]$stage) {
    if ($Force) { return $false }
    $s = Get-State
    return ($s.completed -contains $stage)
}

function Set-StageComplete([string]$stage) {
    $s = Get-State
    if ($s.completed -notcontains $stage) {
        # ConvertFrom-Json returns arrays as fixed-size; convert to resizable list
        $list = [System.Collections.Generic.List[string]]$s.completed
        $list.Add($stage)
        $s.completed = $list.ToArray()
    }
    Save-State $s
}

# ---------------------------------------------------------------------------
# Scheduled task: re-run this script elevated after reboot
# ---------------------------------------------------------------------------
function Register-ContinuationTask {
    if (Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue) {
        return  # Already registered
    }

    $action    = New-ScheduledTaskAction `
                     -Execute   'PowerShell.exe' `
                     -Argument  "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal `
                     -UserId    "$env:USERDOMAIN\$env:USERNAME" `
                     -RunLevel  Highest
    $settings  = New-ScheduledTaskSettingsSet `
                     -AllowStartIfOnBatteries `
                     -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    Register-ScheduledTask `
        -TaskName  $ScheduledTaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Principal $principal `
        -Settings  $settings `
        -Force | Out-Null

    Write-Info "Continuation task registered -- script will resume after reboot."
}

function Remove-ContinuationTask {
    if (Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false
        Write-Ok "Continuation scheduled task removed."
    }
}

# Register continuation task, then reboot. Script exits here.
# On next logon the scheduled task re-runs provision.ps1 from the beginning;
# the state file ensures already-completed stages are skipped.
function Invoke-RebootWithContinuation([string]$reason) {
    Register-ContinuationTask
    Write-Host ""
    Write-Warn "Reboot required: $reason"
    Write-Warn "Script will resume automatically after you log in."
    Write-Host ""
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 0
}

# ---------------------------------------------------------------------------
# STAGE 1: Windows Updates
# Uses PSWindowsUpdate (PSGallery module) -- the standard PowerShell way to
# drive Windows Update programmatically. Runs up to $UpdateMaxCycles passes
# because updates frequently unlock further updates.
# ---------------------------------------------------------------------------
function Invoke-WindowsUpdates {
    Write-Stage "Windows Updates (up to $UpdateMaxCycles passes)"

    # Install PSWindowsUpdate from PSGallery if not already present
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Info "Installing PSWindowsUpdate module from PSGallery ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers
        Write-Ok "PSWindowsUpdate installed"
    }
    Import-Module PSWindowsUpdate -Force

    $state = Get-State

    while ($state.updateCyclesDone -lt $UpdateMaxCycles) {
        $cycle = $state.updateCyclesDone + 1
        Write-Info "Update cycle $cycle of $UpdateMaxCycles ..."

        $pending = Get-WindowsUpdate -AcceptAll -Verbose:$false 2>$null
        if (-not $pending -or $pending.Count -eq 0) {
            Write-Ok "No more updates found after $($state.updateCyclesDone) completed cycle(s)."
            break
        }

        Write-Info "Found $($pending.Count) update(s). Installing ..."
        Install-WindowsUpdate -AcceptAll -IgnoreReboot -Verbose:$false | Out-Null

        $state.updateCyclesDone = $cycle
        Save-State $state

        $rebootNeeded = (Get-WURebootStatus -Silent -ErrorAction SilentlyContinue).RebootRequired
        if ($rebootNeeded) {
            if ($cycle -lt $UpdateMaxCycles) {
                Invoke-RebootWithContinuation "Applying Windows Updates (completed $cycle of $UpdateMaxCycles cycles)"
                # Script exits above; execution never reaches here
            } else {
                Write-Info "Max cycles reached. Rebooting to apply final updates."
                Invoke-RebootWithContinuation "Applying final Windows Updates"
            }
        }
    }

    Set-StageComplete 'updates'
    Write-Ok "Windows Updates complete."
}

# ---------------------------------------------------------------------------
# STAGE 2: Application Installation via Chocolatey
# Chocolatey is used over WinGet because it has a mature idempotent Ansible
# module and reliable silent install support for all listed packages.
# ---------------------------------------------------------------------------
function Invoke-AppInstall {
    Write-Stage "Application Installation (Chocolatey)"

    # Bootstrap Chocolatey if not installed
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Info "Installing Chocolatey ..."
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression (
            (New-Object System.Net.WebClient).DownloadString(
                'https://community.chocolatey.org/install.ps1'))
        # Refresh PATH so choco is available in this session
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        Write-Ok "Chocolatey installed"
    } else {
        Write-Ok "Chocolatey already present"
    }

    foreach ($pkg in $ChocolateyPackages) {
        Write-Info "Installing $pkg ..."
        $output = choco install $pkg -y --no-progress 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($output -match 'already installed') {
                Write-Skip "$pkg is already installed"
            } else {
                Write-Ok "$pkg installed"
            }
        } else {
            Write-Warn "$pkg returned exit code $LASTEXITCODE -- check Chocolatey output above"
        }
    }

    Set-StageComplete 'apps'
    Write-Ok "Application installation complete."
}

# ---------------------------------------------------------------------------
# STAGE 3: Brave Browser Extensions
# Uses the Chromium ExtensionInstallForcelist enterprise registry policy.
# This is the official method used by IT departments for Chrome/Brave/Edge.
# Extensions install silently on next Brave launch; users cannot remove them
# through the browser UI (only by removing the registry entry).
# ---------------------------------------------------------------------------
function Invoke-BraveExtensions {
    Write-Stage "Brave Browser Extensions"

    # Create the policy registry key if it does not exist
    if (-not (Test-Path $BraveExtRegPath)) {
        New-Item -Path $BraveExtRegPath -Force | Out-Null
        Write-Ok "Created Brave policy registry path"
    }

    # Write each extension as a numbered registry value (1-indexed, required by Chromium)
    for ($i = 0; $i -lt $BraveExtensions.Count; $i++) {
        $ext      = $BraveExtensions[$i]
        $regName  = "$($i + 1)"
        $regValue = "$($ext.id);$BraveExtUpdateUrl"

        $current = (Get-ItemProperty -Path $BraveExtRegPath -Name $regName -ErrorAction SilentlyContinue).$regName
        if ($current -eq $regValue) {
            Write-Skip "$($ext.name) already configured"
        } else {
            Set-ItemProperty -Path $BraveExtRegPath -Name $regName -Value $regValue -Type String
            Write-Ok "Configured: $($ext.name)"
        }
    }

    # Remove stale entries if the extension list was shortened since last run.
    # Chromium silently ignores missing extensions, but clean up anyway.
    $cleanupLimit = $BraveExtensions.Count + 20
    for ($i = $BraveExtensions.Count + 1; $i -le $cleanupLimit; $i++) {
        $stale = (Get-ItemProperty -Path $BraveExtRegPath -Name "$i" -ErrorAction SilentlyContinue)."$i"
        if ($stale) {
            Remove-ItemProperty -Path $BraveExtRegPath -Name "$i" -ErrorAction SilentlyContinue
            Write-Info "Removed stale extension entry $i"
        }
    }

    Set-StageComplete 'brave_extensions'
    Write-Ok "Extensions configured. Restart Brave to install them."
    Write-Info "Verify via brave://policy in the address bar."
}

# ---------------------------------------------------------------------------
# STAGE 4: Dark Mode
# Sets HKCU registry values for both app and system dark theme, then
# broadcasts WM_SETTINGCHANGE so most UI elements update immediately.
# Full refresh requires a logout/login.
# Note: HKCU applies to the user running this script (the admin account).
# ---------------------------------------------------------------------------
function Invoke-DarkMode {
    Write-Stage "Dark Mode"

    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    Set-ItemProperty -Path $regPath -Name 'AppsUseLightTheme'    -Value 0 -Type DWord
    Set-ItemProperty -Path $regPath -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
    Write-Ok "Registry: AppsUseLightTheme = 0, SystemUsesLightTheme = 0"

    # Broadcast WM_SETTINGCHANGE with ImmersiveColorSet -- the same Win32 call
    # the Settings app makes when you toggle dark mode in the UI.
    # Causes Explorer and other listeners to refresh their theme immediately.
    if (-not ([System.Management.Automation.PSTypeName]'ThemeRefresh').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ThemeRefresh {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public static void Refresh() {
        UIntPtr result;
        // HWND_BROADCAST=0xffff, WM_SETTINGCHANGE=0x001A, SMTO_ABORTIFHUNG=0x0002
        SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero,
            "ImmersiveColorSet", 0x0002, 5000, out result);
    }
}
'@
    }
    [ThemeRefresh]::Refresh()
    Write-Ok "Settings change broadcast sent -- UI updating now."
    Write-Info "Log out and back in for a complete visual refresh."

    Set-StageComplete 'darkmode'
}

# ---------------------------------------------------------------------------
# STAGE 5: Hyper-V
# Checks edition and hardware before enabling. Skips gracefully if not
# supported rather than failing, so the rest of the script continues.
# ---------------------------------------------------------------------------
function Invoke-HyperV {
    Write-Stage "Hyper-V"

    # --- Edition check ---
    $edition   = (Get-CimInstance Win32_OperatingSystem).Caption
    $editionOk = $edition -match 'Pro|Enterprise|Education'
    Write-Info "Windows edition: $edition"

    if (-not $editionOk) {
        Write-Warn "Hyper-V requires Windows 11 Pro, Enterprise, or Education."
        Write-Warn "Detected: $edition -- skipping Hyper-V."
        Set-StageComplete 'hyperv'
        return
    }

    # --- Hardware checks ---
    $cpu    = Get-CimInstance Win32_Processor
    $vtxOk  = [bool]$cpu.VirtualizationFirmwareEnabled
    $slatOk = [bool]$cpu.SecondLevelAddressTranslationExtensions
    $ramGB  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $ramOk  = $ramGB -ge 4

    Write-Info "Virtualisation (VT-x/AMD-V): $vtxOk"
    Write-Info "SLAT support:                $slatOk"
    Write-Info "RAM:                         $ramGB GB (minimum 4 GB required)"

    if (-not $vtxOk) {
        Write-Warn "CPU virtualisation is disabled in BIOS/UEFI firmware."
        Write-Warn "Enable Intel VT-x or AMD-V in your BIOS settings, then re-run:"
        Write-Warn "  .\provision.ps1 -Only hyperv -Force"
        Set-StageComplete 'hyperv'
        return
    }
    if (-not $slatOk) {
        Write-Warn "CPU does not support SLAT (Second Level Address Translation). Cannot enable Hyper-V."
        Set-StageComplete 'hyperv'
        return
    }
    if (-not $ramOk) {
        Write-Warn "Only $ramGB GB RAM detected. Hyper-V requires at least 4 GB."
        Set-StageComplete 'hyperv'
        return
    }

    # --- Already enabled? ---
    $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction SilentlyContinue
    if ($hvFeature -and $hvFeature.State -eq 'Enabled') {
        Write-Ok "Hyper-V is already enabled."
        Set-StageComplete 'hyperv'
        return
    }

    # --- Enable all Hyper-V components ---
    $features = @(
        'Microsoft-Hyper-V-All',
        'Microsoft-Hyper-V',
        'Microsoft-Hyper-V-Tools-All',
        'Microsoft-Hyper-V-Management-PowerShell',
        'Microsoft-Hyper-V-Hypervisor',
        'Microsoft-Hyper-V-Management-Clients'
    )
    Write-Info "Enabling Hyper-V features ..."
    foreach ($f in $features) {
        Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }

    Set-StageComplete 'hyperv'
    Write-Ok "Hyper-V features enabled."
    Invoke-RebootWithContinuation "Completing Hyper-V installation"
}

# ---------------------------------------------------------------------------
# STAGE 6: WSL (Windows Subsystem for Linux)
# Enables the required Windows features, installs the WSL 2 kernel, sets
# WSL 2 as default, and installs the chosen Linux distro without launching it
# interactively. The user must open the distro from the Start menu once to
# create their Linux username and password.
# ---------------------------------------------------------------------------
function Invoke-WSL {
    Write-Stage "WSL (Windows Subsystem for Linux)"

    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    $needsReboot = $false

    if ($vmpFeature.State -ne 'Enabled') {
        Write-Info "Enabling VirtualMachinePlatform ..."
        Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -NoRestart | Out-Null
        $needsReboot = $true
    } else {
        Write-Ok "VirtualMachinePlatform already enabled"
    }

    if ($wslFeature.State -ne 'Enabled') {
        Write-Info "Enabling Microsoft-Windows-Subsystem-Linux ..."
        Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -NoRestart | Out-Null
        $needsReboot = $true
    } else {
        Write-Ok "WSL feature already enabled"
    }

    if ($needsReboot) {
        Set-StageComplete 'wsl'   # Mark done so we skip feature enablement on re-run,
        Remove-StageComplete 'wsl' # but NOT fully done -- kernel/distro still needed.
        # We use a trick: don't mark complete, just reboot. On re-run the features
        # will be Enabled so we skip past them to the kernel/distro section.
        Invoke-RebootWithContinuation "Completing WSL feature installation"
    }

    # Install / update WSL kernel
    Write-Info "Updating WSL kernel ..."
    wsl --update 2>&1 | Out-Null
    Write-Ok "WSL kernel up to date"

    # Set WSL 2 as default version
    wsl --set-default-version 2 2>&1 | Out-Null
    Write-Ok "WSL default version set to 2"

    # Check if the target distro is already installed
    $installedRaw    = wsl --list --quiet 2>&1
    $distroInstalled = $installedRaw | Where-Object { $_ -match [regex]::Escape($WslDistro) }

    if ($distroInstalled) {
        Write-Ok "$WslDistro is already installed"
    } else {
        Write-Info "Installing $WslDistro (may take a few minutes) ..."
        wsl --install -d $WslDistro --no-launch 2>&1 | ForEach-Object { Write-Host "           $_" }
        Write-Ok "$WslDistro installed."
        Write-Info "Open $WslDistro from the Start menu to complete first-time setup"
        Write-Info "(create your Linux username and password)."
    }

    Set-StageComplete 'wsl'
    Write-Ok "WSL setup complete."
}

# Companion to Set-StageComplete: remove a stage from the completed list.
# Used by WSL to allow the reboot-then-continue pattern for feature enablement.
function Remove-StageComplete([string]$stage) {
    $s    = Get-State
    $list = [System.Collections.Generic.List[string]]$s.completed
    $list.Remove($stage) | Out-Null
    $s.completed = $list.ToArray()
    Save-State $s
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Build the list of stages to run this session
$stagesToRun = if ($Only) { $Only } else { $AllStages }
if ($SkipUpdates) { $stagesToRun = $stagesToRun | Where-Object { $_ -ne 'updates' } }

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  Windows 11 Provisioning' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host "  Stages : $($stagesToRun -join ', ')" -ForegroundColor White
Write-Host "  State  : $StateFile" -ForegroundColor DarkGray
Write-Host ''

# Register the continuation task up front.
# It will be removed at the bottom if no reboot is triggered this session.
Register-ContinuationTask

foreach ($stage in $AllStages) {
    if ($stage -notin $stagesToRun) {
        Write-Skip "Stage not in run list: $stage"
        continue
    }

    if (Test-StageComplete $stage) {
        Write-Skip "$stage already complete  (use -Force to re-run)"
        continue
    }

    switch ($stage) {
        'updates'          { Invoke-WindowsUpdates }
        'apps'             { Invoke-AppInstall }
        'brave_extensions' { Invoke-BraveExtensions }
        'darkmode'         { Invoke-DarkMode }
        'hyperv'           { Invoke-HyperV }
        'wsl'              { Invoke-WSL }
    }
}

# We only reach here if no reboot was triggered.
# Clean up the scheduled task.
Remove-ContinuationTask

Write-Host ''
Write-Host '==========================================' -ForegroundColor Green
Write-Host '  Provisioning Complete!' -ForegroundColor Green
Write-Host '==========================================' -ForegroundColor Green
Write-Host ''
Write-Host '  Manual steps still required:' -ForegroundColor White
Write-Host '    1. Log out and back in -- dark mode applies fully on re-login' -ForegroundColor White
Write-Host '    2. Open Brave Browser -- extensions install automatically on first launch' -ForegroundColor White
Write-Host "    3. Open $WslDistro from the Start menu -- create your Linux user/password" -ForegroundColor White
Write-Host '    4. Open Tailscale from the system tray and sign in' -ForegroundColor White
Write-Host ''
Write-Host '  To re-run a specific stage:' -ForegroundColor DarkGray
Write-Host '    .\provision.ps1 -Only apps' -ForegroundColor DarkGray
Write-Host '    .\provision.ps1 -Only darkmode -Force' -ForegroundColor DarkGray
Write-Host ''
