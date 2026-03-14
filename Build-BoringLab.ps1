#Requires -RunAsAdministrator
#Requires -Version 7.0

<#
.SYNOPSIS
    BoringLab Builder - Automated Hyper-V DevOps Lab (Cloud Image Edition)

.DESCRIPTION
    Creates a 14-VM DevOps lab on Hyper-V using cloud images (no ISOs needed).
    VMs boot in 2-3 minutes instead of 25-30 with traditional ISO installs.

    Uses PowerShell 7 parallel execution for fast VM creation and boot monitoring.
    Post-install configuration is handled by Install-BoringLab.ps1 (called automatically).

.NOTES
    Run as Administrator on the Hyper-V host. Requires PowerShell 7+.
#>

param(
    [switch]$SkipPostInstall
)

$ErrorActionPreference = "Continue"
$script:StartTime = Get-Date

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts] $Message" -ForegroundColor $Color
}

# ============================================================
# Banner
# ============================================================
Clear-Host
Write-Host @"

    ____             _             __          __
   / __ )____  _____(_)___  ____ _/ /   ____ _/ /_
  / __  / __ \/ ___/ / __ \/ __ `/ /   / __ `/ __ \
 / /_/ / /_/ / /  / / / / / /_/ / /___/ /_/ / /_/ /
/_____/\____/_/  /_/_/ /_/\__, /_____/\__,_/_.___/
                         /____/
    Automated Hyper-V DevOps Lab Builder
    [Cloud Image Edition - Parallel Deploy]

"@ -ForegroundColor Cyan

# ============================================================
# Phase 0: Prerequisite Checks
# ============================================================
Write-Log "Phase 0: Checking prerequisites..." "Cyan"

# Check Hyper-V PowerShell module
$hypervModule = Get-Module -ListAvailable -Name "Hyper-V" -ErrorAction SilentlyContinue
if (-not $hypervModule) {
    Write-Log "Hyper-V PowerShell module not found. Attempting to enable..." "Yellow"
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V-Management-PowerShell" -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Log "Hyper-V PowerShell module enabled. A reboot may be required." "Green"
    }
    catch {
        Write-Log "ERROR: Could not enable Hyper-V PowerShell module." "Red"
        Write-Host "  Fix manually:" -ForegroundColor Yellow
        Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Cyan
        Write-Host "  Then reboot and re-run this script." -ForegroundColor Yellow
        exit 1
    }
}

# Check Hyper-V service
$vmms = Get-Service -Name "vmms" -ErrorAction SilentlyContinue
if (-not $vmms -or $vmms.Status -ne 'Running') {
    Write-Log "ERROR: Hyper-V Virtual Machine Management service is not running." "Red"
    Write-Host "  Enable Hyper-V:" -ForegroundColor Yellow
    Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Cyan
    Write-Host "  Then reboot and re-run this script." -ForegroundColor Yellow
    exit 1
}
Write-Log "Hyper-V is available and running." "Green"

# Check for qemu-img (needed for qcow2 conversion)
$qemuAvailable = (Get-Command "qemu-img.exe" -ErrorAction SilentlyContinue) -or
    (Test-Path "$env:ProgramFiles\qemu\qemu-img.exe") -or
    (Test-Path "$env:ProgramFiles\QEMU\qemu-img.exe") -or
    (Test-Path "C:\qemu\qemu-img.exe")
$convertVHDAvailable = Get-Command "Convert-VHD" -ErrorAction SilentlyContinue

if (-not $qemuAvailable -and -not $convertVHDAvailable) {
    Write-Log "WARNING: Neither qemu-img nor Convert-VHD found." "Yellow"
    Write-Host "  qemu-img is needed to convert RHEL .qcow2 images to .vhdx" -ForegroundColor Yellow
    $installQemu = Read-Host "Install qemu-img via winget now? (Y/N)"
    if ($installQemu -in @("Y", "y", "Yes", "yes")) {
        try {
            Write-Log "Installing QEMU via winget..." "Cyan"
            & winget install SoftwareFreedomConservancy.QEMU --accept-source-agreements --accept-package-agreements 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "QEMU installed successfully." "Green"
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            }
            else {
                Write-Log "winget returned exit code $LASTEXITCODE. Install manually." "Yellow"
            }
        }
        catch {
            Write-Log "Failed to install QEMU: $_" "Yellow"
        }
    }
    else {
        Write-Host "  Install manually: winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor Cyan
        Write-Host "  Continuing without it -- will fail if .qcow2 conversion is needed." -ForegroundColor Yellow
    }
}
else {
    if ($qemuAvailable) { Write-Log "qemu-img is available." "Green" }
    if ($convertVHDAvailable) { Write-Log "Convert-VHD (Hyper-V) is available." "Green" }
}

# Check for SSH client (required for key-based Linux VM access)
$sshAvailable = Get-Command "ssh.exe" -ErrorAction SilentlyContinue
if (-not $sshAvailable) {
    Write-Log "ERROR: OpenSSH client not found. Required for Linux VM post-install." "Red"
    Write-Host "  Install: Settings > Apps > Optional Features > OpenSSH Client" -ForegroundColor Cyan
    exit 1
}
Write-Log "OpenSSH client is available." "Green"

# Check powershell-yaml module (needed for config.yaml)
$yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml'
if (-not $yamlModule) {
    Write-Log "powershell-yaml module not found. Installing..." "Yellow"
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
        Write-Log "powershell-yaml module installed." "Green"
    }
    catch {
        Write-Log "ERROR: Could not install powershell-yaml module." "Red"
        Write-Host "  Install manually: Install-Module -Name powershell-yaml -Scope CurrentUser -Force" -ForegroundColor Cyan
        exit 1
    }
}
else {
    Write-Log "powershell-yaml module is available." "Green"
}

Write-Log "Prerequisite checks complete." "Green"
Write-Host ""

# ============================================================
# Phase 1: Load Config, Validate, Collect Credentials
# ============================================================
Write-Log "Phase 1: Loading configuration..." "Cyan"

$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module (Join-Path $modulePath "ConfigLoader.psm1") -Force

$configPath = Join-Path $PSScriptRoot "config.yaml"
if (-not (Test-Path $configPath)) {
    Write-Log "ERROR: config.yaml not found at $configPath" "Red"
    exit 1
}
$Config = Import-LabConfig -Path $configPath

# Import modules
Import-Module (Join-Path $modulePath "LabNetwork.psm1") -Force
Import-Module (Join-Path $modulePath "LabVM.psm1") -Force
Import-Module (Join-Path $modulePath "CloudImage.psm1") -Force
Import-Module (Join-Path $modulePath "CloudInit.psm1") -Force
Import-Module (Join-Path $modulePath "WindowsUnattend.psm1") -Force
# Validate config
Write-Log "Validating configuration..." "Cyan"
$allIPs = $Config.VMs | ForEach-Object { $_.IP }
$uniqueIPs = $allIPs | Select-Object -Unique
if ($allIPs.Count -ne $uniqueIPs.Count) {
    Write-Log "ERROR: Duplicate IP addresses in config!" "Red"
    exit 1
}
$allNames = $Config.VMs | ForEach-Object { $_.Name }
$uniqueNames = $allNames | Select-Object -Unique
if ($allNames.Count -ne $uniqueNames.Count) {
    Write-Log "ERROR: Duplicate VM names in config!" "Red"
    exit 1
}
Write-Log "Configuration validated: $($Config.VMs.Count) VMs defined." "Green"

# --- Collect credentials BEFORE transcript (and before downloads) ---
Write-Host ""
Write-Host "Enter the password for Windows Administrator and Linux root accounts." -ForegroundColor Yellow
$winPassword = Read-Host -Prompt "Admin/Root Password" -AsSecureString
$winCredential = New-Object PSCredential("Administrator", $winPassword)

$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($winPassword)
$rootPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

Write-Host ""
Write-Host "A credential dialog will appear for your Red Hat subscription." -ForegroundColor Yellow
$rhelCred = Get-Credential -Message "Enter Red Hat Subscription credentials (username & password)"
if (-not $rhelCred) {
    Write-Log "ERROR: RHEL credentials are required." "Red"
    exit 1
}
$rhelUser = $rhelCred.UserName
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($rhelCred.Password)
$rhelPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

Write-Log "Credentials collected (not logged)." "Green"

# Validate Red Hat subscription credentials via RHSM API (basic auth)
Write-Log "Validating Red Hat subscription credentials..." "Cyan"
try {
    $pair = "${rhelUser}:${rhelPass}"
    $base64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Authorization = "Basic $base64" }
    $null = Invoke-RestMethod -Uri "https://subscription.rhsm.redhat.com/subscription/users/$rhelUser/owners" `
        -Headers $headers -ErrorAction Stop
    Write-Log "Red Hat credentials validated successfully." "Green"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        Write-Log "ERROR: Red Hat credentials are invalid. Please check your username/password." "Red"
        exit 1
    } else {
        Write-Log "WARNING: Could not validate Red Hat credentials online (status: $statusCode). Proceeding anyway..." "Yellow"
        Write-Log "  Detail: $($_.Exception.Message)" "Yellow"
    }
}

# Generate SSH key pair for Linux VM access (key-based auth, no sshpass needed)
$sshDir = Join-Path $Config.VMPath ".ssh"
$sshKeyPath = Join-Path $sshDir "boringlab_ed25519"
$sshPubKeyPath = "$sshKeyPath.pub"

if (-not (Test-Path $sshKeyPath)) {
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    Write-Log "Generating SSH key pair for lab access..." "Cyan"
    & ssh-keygen -t ed25519 -f $sshKeyPath -N "" -C "boringlab-automation" 2>&1 | Out-Null
    if (-not (Test-Path $sshPubKeyPath)) {
        Write-Log "ERROR: SSH key generation failed. Ensure OpenSSH is installed." "Red"
        exit 1
    }
    Write-Log "SSH key pair generated at $sshKeyPath" "Green"
}
else {
    Write-Log "SSH key pair already exists at $sshKeyPath" "Green"
}
$sshPubKey = (Get-Content $sshPubKeyPath -Raw).Trim()

# Prepare templates (validate cloud images exist, convert if needed)
Write-Log "Preparing cloud image templates..." "Cyan"
try {
    $templates = Initialize-LabTemplates -Config $Config
}
catch {
    Write-Log "ERROR: $_" "Red"
    exit 1
}

# Create directories
if (-not (Test-Path $Config.VMPath)) {
    New-Item -ItemType Directory -Path $Config.VMPath -Force | Out-Null
}

# Start transcript AFTER credentials and downloads
$logFile = Join-Path $Config.VMPath "BoringLab-Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile -Append | Out-Null
Write-Log "Logging to: $logFile" "Green"

# ============================================================
# Phase 2: Network Setup
# ============================================================
Write-Host ""
Write-Log "Phase 2: Setting up lab network..." "Cyan"
New-LabNetwork -Config $Config

# ============================================================
# Phase 3: Clone VHDXs & Create VMs (PARALLEL)
# ============================================================
Write-Host ""
Write-Log "Phase 3: Creating VMs from cloud images (parallel)..." "Cyan"

$windowsVMs = $Config.VMs | Where-Object { $_.OS -eq "Windows" }
$linuxVMs   = $Config.VMs | Where-Object { $_.OS -eq "RHEL" }

# --- Step 1: Create cloud-init ISOs sequentially (COM objects are not thread-safe) ---
$linuxISOMap = @{}
foreach ($vmDef in $linuxVMs) {
    $vmFolder = Join-Path $Config.VMPath $vmDef.Name
    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }
    $ciISO = New-CloudInitISO -VMDef $vmDef -Config $Config `
        -RootPassword $rootPassword -RHELUsername $rhelUser -RHELPassword $rhelPass `
        -SSHPublicKey $sshPubKey
    $linuxISOMap[$vmDef.Name] = $ciISO
}

# --- Step 2: Clone VHDX + inject config + create ALL VMs (PARALLEL) ---
# Windows and Linux VMs in a single parallel batch. Each VM operates on its
# own VHDX copy — no shared resource contention (Mount-VHD is per-disk).
$Config.VMs | ForEach-Object -ThrottleLimit 5 -Parallel {
    $vmDef    = $_
    $config   = $using:Config
    $tpls     = $using:templates
    $isoMap   = $using:linuxISOMap
    $modPath  = $using:modulePath
    $adminPwd = $using:winPassword

    Import-Module (Join-Path $modPath "CloudImage.psm1") -Force
    Import-Module (Join-Path $modPath "LabVM.psm1") -Force
    Import-Module (Join-Path $modPath "WindowsUnattend.psm1") -Force

    $vmFolder = Join-Path $config.VMPath $vmDef.Name
    $vhdxPath = Join-Path $vmFolder "$($vmDef.Name).vhdx"
    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }

    if ($vmDef.OS -eq "Windows") {
        Copy-TemplateVHDX -TemplatePath $tpls.WindowsTemplate `
                          -DestinationPath $vhdxPath `
                          -SizeBytes ([int64]$vmDef.DiskGB * 1GB)
        Inject-WindowsUnattend -VMDef $vmDef -Config $config `
                               -AdminPassword $adminPwd -VHDXPath $vhdxPath
        New-LabVM -VMDef $vmDef -Config $config -TemplateVHDX $vhdxPath
    }
    else {
        Copy-TemplateVHDX -TemplatePath $tpls.RHELTemplate `
                          -DestinationPath $vhdxPath `
                          -SizeBytes ([int64]$vmDef.DiskGB * 1GB)
        $ciISO = $isoMap[$vmDef.Name]
        New-LabVM -VMDef $vmDef -Config $config -TemplateVHDX $vhdxPath -CloudInitISO $ciISO
    }
}

Write-Log "All VMs created." "Green"

# ============================================================
# Phase 4: Start All VMs
# ============================================================
Write-Host ""
Write-Log "Phase 4: Starting all VMs..." "Cyan"

# Start DC first (needs head start for AD)
$dcVM = $Config.VMs | Where-Object { $_.Role -eq "DomainController" } | Select-Object -First 1
Start-LabVM -VMName $dcVM.Name
Start-Sleep -Seconds 3

# Start all others in parallel
$Config.VMs | Where-Object { $_.Role -ne "DomainController" } | ForEach-Object -ThrottleLimit 12 -Parallel {
    $vmName = $_.Name
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -ne 'Running') {
        Start-VM -Name $vmName -ErrorAction SilentlyContinue
    }
}

Write-Log "All VMs started. Cloud-init / OOBE running..." "Green"

# ============================================================
# Phase 5: Wait for VMs to Boot (PARALLEL)
# ============================================================
Write-Host ""
Write-Log "Phase 5: Waiting for VMs to boot (parallel monitoring)..." "Cyan"

# Wait for DC first (everything depends on it)
Wait-LabVMReady -VMName $dcVM.Name -OS "Windows" -Credential $winCredential -IP $dcVM.IP -TimeoutMinutes 15

# Wait for all other VMs in parallel using ForEach-Object -Parallel
# (Start-ThreadJob runspaces cannot auto-load Hyper-V CDXML module; -Parallel can)
$otherVMs = @($Config.VMs | Where-Object { $_.Role -ne "DomainController" })
if ($otherVMs.Count -gt 0) {
    Write-Log "Monitoring $($otherVMs.Count) VMs in parallel..." "Cyan"
    $otherVMs | ForEach-Object -ThrottleLimit 13 -Parallel {
        $vmDef   = $_
        $modPath = $using:modulePath
        $cred    = $using:winCredential

        Import-Module (Join-Path $modPath "LabVM.psm1") -Force

        if ($vmDef.OS -eq "Windows") {
            Wait-LabVMReady -VMName $vmDef.Name -OS "Windows" -Credential $cred -IP $vmDef.IP -TimeoutMinutes 15
        }
        else {
            Wait-LabVMReady -VMName $vmDef.Name -OS "RHEL" -IP $vmDef.IP -TimeoutMinutes 15
        }
    }
}

# Report actual VM states from Hyper-V
$allVMNames = $Config.VMs | ForEach-Object { $_.Name }
$runningVMs = Get-VM | Where-Object { $_.Name -in $allVMNames -and $_.State -eq 'Running' }
$notRunning = Get-VM | Where-Object { $_.Name -in $allVMNames -and $_.State -ne 'Running' }
if ($notRunning) {
    Write-Log "$($runningVMs.Count)/$($allVMNames.Count) VMs running. Not running: $($notRunning.Name -join ', ')" "Yellow"
}
else {
    Write-Log "All $($allVMNames.Count) VMs are running." "Green"
}

# --- Safety: restart any VMs that went Off during cloud-init reboot ---
$stoppedVMs = Get-VM | Where-Object { $_.Name -in $allVMNames -and $_.State -eq 'Off' }
if ($stoppedVMs) {
    Write-Log "Restarting $($stoppedVMs.Count) VM(s) that rebooted during cloud-init..." "Yellow"
    foreach ($stopped in $stoppedVMs) {
        Write-Host "[VM  ] Restarting '$($stopped.Name)'..." -ForegroundColor Yellow
        Start-VM -Name $stopped.Name -ErrorAction SilentlyContinue
    }
    # Wait for them to come back up
    Start-Sleep -Seconds 60
    # Verify all are running now
    $stillStopped = Get-VM | Where-Object { $_.Name -in $allVMNames -and $_.State -eq 'Off' }
    if ($stillStopped) {
        foreach ($s in $stillStopped) {
            Write-Warning "VM '$($s.Name)' is still off after restart attempt."
        }
    }
    else {
        Write-Log "All VMs are now running." "Green"
    }
}

# ============================================================
# Phase 6: Post-Install Configuration (via Install-BoringLab.ps1)
# ============================================================
if (-not $SkipPostInstall) {
    Write-Host ""
    Write-Log "Phase 6: Handing off to Install-BoringLab.ps1 for post-install..." "Cyan"
    $installScript = Join-Path $PSScriptRoot "Install-BoringLab.ps1"
    $installParams = @{
        WinCredential = $winCredential
        SSHKeyPath    = $sshKeyPath
    }
    & $installScript @installParams
}
else {
    Write-Log "Phase 6: SKIPPED (-SkipPostInstall)" "Yellow"
    Write-Log "Run .\Install-BoringLab.ps1 later to configure VMs." "Yellow"
}

# ============================================================
# Summary
# ============================================================
$elapsed = (Get-Date) - $script:StartTime
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " BoringLab Build Complete!" -ForegroundColor Green
Write-Host " Total time: $($elapsed.Hours)h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host " VM Status:" -ForegroundColor Cyan
Get-VM | Where-Object { $_.Name -in ($Config.VMs | ForEach-Object { $_.Name }) } |
    Format-Table Name, State, @{N='CPU';E={$_.ProcessorCount}}, @{N='RAM(GB)';E={[math]::Round($_.MemoryAssigned/1GB,1)}}, Status -AutoSize
Write-Host ""
$dcIP = ($Config.VMs | Where-Object { $_.Role -eq "DomainController" } | Select-Object -First 1).IP
$ansibleIP = ($Config.VMs | Where-Object { $_.Role -eq "Ansible" } | Select-Object -First 1).IP
$gitlabIP = ($Config.VMs | Where-Object { $_.Role -eq "GitLab" } | Select-Object -First 1).IP
$grafanaIP = ($Config.VMs | Where-Object { $_.Role -eq "Monitoring" } | Select-Object -First 1).IP
$harborIP = ($Config.VMs | Where-Object { $_.Role -eq "Docker" } | Select-Object -First 1).IP
$vaultIP = ($Config.VMs | Where-Object { $_.Role -eq "Vault" } | Select-Object -First 1).IP
$svcPass = $Config.ServicePassword

Write-Host " Quick Access:" -ForegroundColor Cyan
Write-Host "   Windows VMs:  mstsc /v:$dcIP  (DC01)" -ForegroundColor White
Write-Host "   Linux VMs:    ssh root@$ansibleIP   (ANSIBLE01)" -ForegroundColor White
if ($gitlabIP) { Write-Host "   GitLab:       http://$gitlabIP" -ForegroundColor White }
if ($grafanaIP) { Write-Host "   Grafana:      http://${grafanaIP}:3000  (admin/$svcPass)" -ForegroundColor White }
if ($harborIP) { Write-Host "   Harbor:       http://$harborIP       (admin/$svcPass)" -ForegroundColor White }
if ($vaultIP) { Write-Host "   Vault:        http://${vaultIP}:8200   (keys: /root/vault-keys.txt)" -ForegroundColor White }
Write-Host "   Domain:       $($Config.DomainName)" -ForegroundColor White
Write-Host ""
Write-Host (" Log file: " + $logFile) -ForegroundColor Gray

Stop-Transcript | Out-Null

# Clear sensitive variables
$rootPassword = $null
$rhelPass = $null
$rhelUser = $null
[System.GC]::Collect()
