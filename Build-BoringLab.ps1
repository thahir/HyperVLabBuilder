#Requires -RunAsAdministrator
#Requires -Version 7.0

<#
.SYNOPSIS
    BoringLab Builder - Automated Hyper-V DevOps Lab (Cloud Image Edition)

.DESCRIPTION
    Creates a 14-VM DevOps lab on Hyper-V using cloud images (no ISOs needed).
    VMs boot in 2-3 minutes instead of 25-30 with traditional ISO installs.

    Uses PowerShell 7 parallel execution for fast VM creation, boot monitoring,
    and post-install configuration.

    Set AutoDownload = $false in config.psd1 to disable auto-download.

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

# Check for SSH client (needed for Linux post-install)
$sshAvailable = Get-Command "ssh.exe" -ErrorAction SilentlyContinue
if (-not $sshAvailable) {
    Write-Log "WARNING: OpenSSH client not found. Linux post-install will use Hyper-V Guest Services fallback." "Yellow"
    Write-Host "  Install: Settings > Apps > Optional Features > OpenSSH Client" -ForegroundColor Cyan
}

Write-Log "Prerequisite checks complete." "Green"
Write-Host ""

# ============================================================
# Phase 1: Load Config, Validate, Collect Credentials
# ============================================================
Write-Log "Phase 1: Loading configuration..." "Cyan"

$configPath = Join-Path $PSScriptRoot "config.psd1"
if (-not (Test-Path $configPath)) {
    Write-Log "ERROR: config.psd1 not found at $configPath" "Red"
    exit 1
}
$Config = Import-PowerShellDataFile $configPath

# Import modules
$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module (Join-Path $modulePath "LabNetwork.psm1") -Force
Import-Module (Join-Path $modulePath "LabVM.psm1") -Force
Import-Module (Join-Path $modulePath "ImageDownload.psm1") -Force
Import-Module (Join-Path $modulePath "CloudImage.psm1") -Force
Import-Module (Join-Path $modulePath "CloudInit.psm1") -Force
Import-Module (Join-Path $modulePath "WindowsUnattend.psm1") -Force
Import-Module (Join-Path $modulePath "PostInstall.psm1") -Force

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

# Download Windows VHD if missing, check RHEL image exists
if ($Config.AutoDownload -ne $false) {
    Write-Log "Checking cloud image availability..." "Cyan"
    Invoke-LabImageDownload -Config $Config
}

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

# --- Windows VMs: sequential (Mount-VHD for unattend injection needs exclusive access) ---
foreach ($vmDef in $windowsVMs) {
    $vmFolder = Join-Path $Config.VMPath $vmDef.Name
    $vhdxPath = Join-Path $vmFolder "$($vmDef.Name).vhdx"

    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }

    Copy-TemplateVHDX -TemplatePath $templates.WindowsTemplate `
                      -DestinationPath $vhdxPath `
                      -SizeBytes ([int64]$vmDef.DiskGB * 1GB)

    Inject-WindowsUnattend -VMDef $vmDef -Config $Config `
                           -AdminPassword $winPassword -VHDXPath $vhdxPath

    New-LabVM -VMDef $vmDef -Config $Config -TemplateVHDX $vhdxPath
}

# --- Linux VMs: create cloud-init ISOs sequentially (COM objects are not thread-safe) ---
$linuxISOMap = @{}
foreach ($vmDef in $linuxVMs) {
    $vmFolder = Join-Path $Config.VMPath $vmDef.Name
    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }
    $ciISO = New-CloudInitISO -VMDef $vmDef -Config $Config `
        -RootPassword $rootPassword -RHELUsername $rhelUser -RHELPassword $rhelPass
    $linuxISOMap[$vmDef.Name] = $ciISO
}

# --- Linux VMs: clone VHDX + create VM (PARALLEL) ---
$linuxVMs | ForEach-Object -ThrottleLimit 5 -Parallel {
    $vmDef    = $_
    $config   = $using:Config
    $rhelTpl  = $using:templates
    $isoMap   = $using:linuxISOMap
    $modPath  = $using:modulePath

    Import-Module (Join-Path $modPath "CloudImage.psm1") -Force
    Import-Module (Join-Path $modPath "LabVM.psm1") -Force

    $vmFolder = Join-Path $config.VMPath $vmDef.Name
    $vhdxPath = Join-Path $vmFolder "$($vmDef.Name).vhdx"

    Copy-TemplateVHDX -TemplatePath $rhelTpl.RHELTemplate `
                      -DestinationPath $vhdxPath `
                      -SizeBytes ([int64]$vmDef.DiskGB * 1GB)

    $ciISO = $isoMap[$vmDef.Name]
    New-LabVM -VMDef $vmDef -Config $config -TemplateVHDX $vhdxPath -CloudInitISO $ciISO
}

Write-Log "All VMs created." "Green"

# ============================================================
# Phase 4: Start All VMs
# ============================================================
Write-Host ""
Write-Log "Phase 4: Starting all VMs..." "Cyan"

# Start DC01 first (needs head start for AD)
Start-LabVM -VMName "DC01"
Start-Sleep -Seconds 3

# Start all others in parallel
$Config.VMs | Where-Object { $_.Name -ne "DC01" } | ForEach-Object -ThrottleLimit 12 -Parallel {
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

# Wait for DC01 first (everything depends on it)
Wait-LabVMReady -VMName "DC01" -OS "Windows" -Credential $winCredential -TimeoutMinutes 15

# Wait for all other VMs in parallel using thread jobs
$waitJobs = @()

foreach ($vmDef in ($windowsVMs | Where-Object { $_.Name -ne "DC01" })) {
    $waitJobs += Start-ThreadJob -Name "Wait-$($vmDef.Name)" -ScriptBlock {
        param($vmName, $modPath, $cred)
        Import-Module (Join-Path $modPath "LabVM.psm1") -Force
        Wait-LabVMReady -VMName $vmName -OS "Windows" -Credential $cred -TimeoutMinutes 15
    } -ArgumentList $vmDef.Name, $modulePath, $winCredential
}

foreach ($vmDef in $linuxVMs) {
    $waitJobs += Start-ThreadJob -Name "Wait-$($vmDef.Name)" -ScriptBlock {
        param($vmName, $modPath)
        Import-Module (Join-Path $modPath "LabVM.psm1") -Force
        Wait-LabVMReady -VMName $vmName -OS "RHEL" -TimeoutMinutes 10
    } -ArgumentList $vmDef.Name, $modulePath
}

if ($waitJobs.Count -gt 0) {
    Write-Log "Monitoring $($waitJobs.Count) VMs in parallel..." "Cyan"
    $waitJobs | Wait-Job | ForEach-Object {
        Receive-Job $_ | Out-Null
        Remove-Job $_
    }
}

Write-Log "All VMs are booted and responsive." "Green"

# ============================================================
# Phase 6: Post-Install Configuration (WAVE-BASED PARALLEL)
# ============================================================
if (-not $SkipPostInstall) {
    Write-Host ""
    Write-Log "Phase 6: Running post-install configuration (wave-based parallel)..." "Cyan"
    Invoke-AllPostInstall -Config $Config -WinCredential $winCredential -RootPassword $rootPassword
}
else {
    Write-Log "Phase 6: SKIPPED (-SkipPostInstall)" "Yellow"
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
$svcPass = if ($Config.ServicePassword) { $Config.ServicePassword } else { "BoringLab123!" }

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
