================================================================================
  WINDOWS 11 ANSIBLE PROVISIONER
  Plain-English Guide: What It Does, What It Sets Up, How to Deploy
================================================================================

This is an Ansible project that automatically configures a fresh Windows 11
machine from scratch. You run one command and it handles everything --
updates, apps, browser extensions, settings, and optional features.

It is safe to re-run at any time. If something is already installed or
configured, it skips it. Nothing gets broken or doubled up.


--------------------------------------------------------------------------------
  WHAT IT DOES (THE SIX STAGES)
--------------------------------------------------------------------------------

1. WINDOWS UPDATES  (tag: updates)
   - Runs Windows Update in up to 3 passes, rebooting the machine between
     each pass if needed.
   - Multiple passes are necessary because Windows often hides some updates
     behind other updates -- a single pass is rarely enough on a fresh install.
   - Each pass has a 2-hour timeout. Total update time on a clean machine is
     typically 1-2 hours depending on your internet speed.

2. APPLICATIONS  (tag: apps)
   - Installs 8 applications silently using Chocolatey (a Windows package
     manager similar to apt or brew).
   - Applications installed:
       - Brave Browser     (web browser)
       - Obsidian          (note-taking app)
       - Steam             (gaming platform)
       - Discord           (voice/text chat)
       - Tailscale         (VPN / mesh networking)
       - Sysinternals      (Microsoft system tools suite)
       - Microsoft PowerToys (productivity utilities)
       - Spotify           (music streaming)
   - Chocolatey itself is installed automatically if not present.
   - If an app is already installed, it is skipped.

3. BRAVE EXTENSIONS  (tag: brave_extensions)
   - Force-installs 10 extensions into Brave using Windows Group Policy
     (the official enterprise method for Chromium-based browsers).
   - Extensions installed:
       - Bitwarden               (password manager)
       - Linkwarden              (bookmark manager)
       - uBlock Origin Lite      (ad blocker)
       - Decentraleyes           (CDN privacy protection)
       - Obsidian Web Clipper    (save pages to Obsidian)
       - Privacy Badger          (tracker blocker)
       - Return YouTube Dislike  (restores dislike count)
       - SponsorBlock            (skips YouTube sponsorships)
       - Terms of Service;DR     (summarises ToS agreements)
       - Chromebook Recovery Utility
   - Extensions install automatically the next time Brave is opened.
     If Brave is already running, restart it.
   - Extensions are locked in -- users cannot uninstall them through
     the browser. To remove one, delete its entry from group_vars/windows.yml
     and re-run the playbook.

4. DARK MODE  (tag: darkmode)
   - Sets both the system theme and app theme to dark mode via the registry.
   - Takes effect after a logout/login, though most UI elements update
     immediately due to a settings-change broadcast the playbook sends.
   - Note: applies to the user account Ansible connects as. If that is a
     separate admin account from your daily-use account, you may need to run
     this step manually as your daily-use user.

5. HYPER-V  (tag: hyperv)
   - Checks whether the machine supports Hyper-V before doing anything:
       - Windows edition must be Pro, Enterprise, or Education
         (Home edition does not support Hyper-V)
       - CPU must have virtualisation enabled (VT-x / AMD-V in BIOS)
       - CPU must support SLAT (Second Level Address Translation)
       - Machine must have at least 4 GB RAM
   - If all checks pass, Hyper-V is enabled and the machine is rebooted.
   - If any check fails, the step is skipped with a clear message -- the
     rest of the playbook continues normally.
   - If Hyper-V is skipped due to BIOS virtualisation being off, you need
     to enable it manually in your BIOS/UEFI settings and re-run this step.

6. WSL  (tag: wsl)
   - Enables the Windows Subsystem for Linux and the Virtual Machine Platform
     Windows features.
   - Installs the WSL 2 kernel.
   - Sets WSL 2 as the default version.
   - Installs Ubuntu (configurable -- see CUSTOMISATION below).
   - Does NOT launch the distro automatically. You must open Ubuntu from the
     Start menu the first time to create your Linux username and password.
   - A reboot occurs after enabling the Windows features (required by Windows).


--------------------------------------------------------------------------------
  PROJECT FILE LAYOUT
--------------------------------------------------------------------------------

windows-pc/
  README.txt                  <-- this file
  README.md                   <-- original technical reference
  site.yml                    <-- main playbook (the entry point)
  ansible.cfg                 <-- Ansible configuration
  inventory.ini               <-- defines which machine(s) to target
  requirements.yml            <-- Ansible collections to install
  group_vars/
    windows.yml               <-- all variables / settings (edit this to customise)
  roles/
    windows_updates/          <-- Stage 1: Windows Update
    chocolatey_apps/          <-- Stage 2: Application installation
    brave_extensions/         <-- Stage 3: Browser extensions
    dark_mode/                <-- Stage 4: Dark mode
    hyperv/                   <-- Stage 5: Hyper-V
    wsl/                      <-- Stage 6: WSL

The only files you normally need to edit are:
  - inventory.ini             (set your target machine's hostname or IP)
  - group_vars/windows.yml    (change which apps/extensions/distro/etc.)


--------------------------------------------------------------------------------
  CUSTOMISATION (group_vars/windows.yml)
--------------------------------------------------------------------------------

Add or remove applications:
  Edit the 'chocolatey_packages' list. Package names come from
  https://community.chocolatey.org/packages

Add or remove Brave extensions:
  Edit the 'brave_extensions' list. You need the extension's ID from the
  Chrome Web Store URL. Example:
    https://chromewebstore.google.com/detail/bitwarden/nngceckbapebfimnlniiiahkandclblb
    The ID is the last part: nngceckbapebfimnlniiiahkandclblb

Change the WSL distro:
  Set 'wsl_default_distro' to any name shown by: wsl --list --online
  Common options: Ubuntu, Debian, kali-linux, openSUSE-42

Disable dark mode:
  Set 'enable_dark_mode: false'

Change how many Windows Update passes to run:
  Set 'windows_update_max_cycles' (default is 3)


--------------------------------------------------------------------------------
  PREREQUISITES (ONE-TIME SETUP)
--------------------------------------------------------------------------------

You need a control machine (the machine you run Ansible FROM).
This can be Linux, macOS, or Windows with WSL. It does NOT need to be the
same machine as the target.

On the control machine, install:

  pip install ansible pywinrm
  cd /path/to/windows-pc
  ansible-galaxy collection install -r requirements.yml

That is the only software you need on the control side.


================================================================================
  DEPLOYMENT: REMOTE (running Ansible from another machine over the network)
================================================================================

This is the standard method. Ansible runs on your control machine and
connects to the Windows target over WinRM (Windows Remote Management),
which is similar to SSH but for Windows.

--------
STEP 1: Enable WinRM on the target Windows 11 machine
--------

On the Windows machine you want to configure, open PowerShell as Administrator
and run:

  $url = "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
  $file = "$env:temp\ConfigureRemotingForAnsible.ps1"
  (New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)
  powershell.exe -ExecutionPolicy ByPass -File $file

This script:
  - Enables the WinRM service
  - Creates a self-signed HTTPS certificate
  - Opens port 5986 in the Windows Firewall
  - Configures NTLM authentication

To verify it worked, run this on the Windows machine:
  winrm quickconfig

--------
STEP 2: Edit inventory.ini
--------

Open inventory.ini and replace "windows-pc" with either:
  - The hostname of the target machine (e.g. DESKTOP-ABC123)
  - Its IP address (e.g. 192.168.1.50)

Example:
  [windows]
  192.168.1.50

--------
STEP 3: Run the playbook
--------

From your control machine, in the windows-pc directory:

  Full run (all stages):
    ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass

  Just install apps:
    ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --tags apps

  Just run updates:
    ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --tags updates

  Just set up WSL and Hyper-V:
    ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --tags "hyperv,wsl"

  Dry run (shows what would change, makes no changes):
    ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --check

Replace "Administrator" with whatever admin account exists on the target.
You will be prompted for the password.

--------
STEP 4: Available tags (run only parts of the playbook)
--------

  --tags updates           Windows Update only
  --tags apps              Install applications only
  --tags brave_extensions  Brave extensions only
  --tags darkmode          Dark mode only
  --tags hyperv            Hyper-V only
  --tags wsl               WSL only

  Combine with commas: --tags "apps,brave_extensions"

--------
Troubleshooting remote connections:
--------

  Test that Ansible can reach the machine before running the full playbook:
    ansible windows -m ansible.windows.win_ping -i inventory.ini -u Administrator --ask-pass

  If you get a 401 Unauthorized error, try adding this to inventory.ini:
    ansible_winrm_transport = credssp
  And install: pip install pywinrm[credssp]

  If you get certificate errors, confirm this is in inventory.ini:
    ansible_winrm_server_cert_validation = ignore

  If the connection times out, check the Windows Firewall allows port 5986.


================================================================================
  DEPLOYMENT: LOCAL (running Ansible directly on the Windows machine via WSL)
================================================================================

Use this method if you do not have a separate control machine, or if the
target is not reachable over the network.

In this mode, Ansible runs inside WSL (Windows Subsystem for Linux) on the
same Windows machine it is configuring. It connects to Windows by calling
PowerShell/WinRM on localhost.

--------
STEP 1: Install WSL on the target Windows machine
--------

Open PowerShell as Administrator and run:
  wsl --install

Restart when prompted, then open Ubuntu and create your Linux user.

--------
STEP 2: Install Ansible inside WSL
--------

Inside your WSL terminal:
  sudo apt update && sudo apt install -y python3-pip
  pip install ansible pywinrm
  ansible-galaxy collection install -r requirements.yml

--------
STEP 3: Copy the project into WSL (or work from the Windows filesystem)
--------

Option A -- copy into the Linux filesystem (faster):
  cp -r /mnt/c/path/to/windows-pc ~/windows-pc
  cd ~/windows-pc

Option B -- work directly from the Windows path (slower but simpler):
  cd /mnt/c/Users/YourName/path/to/windows-pc

--------
STEP 4: Configure inventory.ini for local connection
--------

Edit inventory.ini and change the [windows] section to:

  [windows]
  localhost

  [windows:vars]
  ansible_connection = winrm
  ansible_host = localhost
  ansible_port = 5985
  ansible_winrm_transport = ntlm
  ansible_winrm_server_cert_validation = ignore

Note: port 5985 (HTTP) is used for localhost; port 5986 (HTTPS) is for remote.

--------
STEP 5: Enable WinRM on localhost
--------

In PowerShell as Administrator on the same machine:
  Enable-PSRemoting -Force
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value "localhost" -Force

--------
STEP 6: Run the playbook
--------

From inside WSL, in the windows-pc directory:

  Full run:
    ansible-playbook site.yml -i inventory.ini -u YourWindowsUsername --ask-pass

  Enter your Windows account password when prompted.

  All the same tag options from the remote section apply here too.


--------------------------------------------------------------------------------
  AFTER THE PLAYBOOK COMPLETES
--------------------------------------------------------------------------------

A few things require a manual step after the playbook finishes:

1. DARK MODE
   Log out and back in to see the full dark mode effect everywhere.

2. BRAVE EXTENSIONS
   Open (or restart) Brave Browser. The extensions will install automatically
   within a minute or two. Check brave://extensions to confirm.
   Each extension's settings (e.g. Bitwarden login, uBlock filter lists,
   SponsorBlock skip categories) need to be configured manually.

3. WSL / UBUNTU
   Open Ubuntu from the Start menu. The first launch asks you to create a
   Linux username and password. This step cannot be automated.

4. TAILSCALE
   Open Tailscale from the system tray and sign in to your Tailscale account.

5. HYPER-V (if enabled)
   A reboot is required. The playbook handles this automatically, but if you
   skipped the hyperv step earlier, reboot the machine after running it.


--------------------------------------------------------------------------------
  KNOWN LIMITATIONS
--------------------------------------------------------------------------------

- Brave extension SETTINGS are not automated. The extensions themselves are
  installed, but you must sign in to Bitwarden, configure uBlock lists, etc.

- Dark mode applies to the Ansible connection account. If you use a separate
  admin account for Ansible and a different daily-use account, run the
  darkmode tag again while logged in as your daily-use account.

- WSL first launch is always manual. Windows requires it for user account
  creation and it cannot be scripted safely.

- Hyper-V on Windows Home is not possible. This is a Microsoft restriction.
  The playbook detects this and skips gracefully.

- Chromebook Recovery Utility may have reduced functionality on Windows
  since it is designed primarily for ChromeOS recovery tasks.

- A complete provisioning run (all stages) on a fresh Windows 11 machine
  takes approximately 1-3 hours, mostly due to Windows Update.


--------------------------------------------------------------------------------
  QUICK REFERENCE: MOST COMMON COMMANDS
--------------------------------------------------------------------------------

Install prerequisites (control machine):
  pip install ansible pywinrm
  ansible-galaxy collection install -r requirements.yml

Test connection to target:
  ansible windows -m ansible.windows.win_ping -i inventory.ini -u Administrator --ask-pass

Full provisioning run:
  ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass

Run one stage only (replace TAG with: updates, apps, brave_extensions, darkmode, hyperv, wsl):
  ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --tags TAG

Dry run (no changes made):
  ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass --check

Verbose output (for debugging):
  ansible-playbook site.yml -i inventory.ini -u Administrator --ask-pass -vvv

================================================================================
