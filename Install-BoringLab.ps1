#Requires -RunAsAdministrator
#Requires -Version 7.0

<#
.SYNOPSIS
    BoringLab Installer — Runs post-install configuration on existing VMs.

.DESCRIPTION
    Deploys and executes post-install scripts on BoringLab VMs via SSH (Linux) or
    PowerShell Direct (Windows). All scripts are idempotent — safe to re-run.

    Can target all VMs (wave-based parallel) or specific VMs by name.
    Called automatically by Build-BoringLab.ps1, or run standalone to re-install.

.PARAMETER VMNames
    Target specific VMs by name. If omitted, runs post-install on ALL VMs
    using wave-based parallel execution (DC first, then everything else).

.PARAMETER WinCredential
    Windows Administrator credential. If not provided, will prompt.
    Passed automatically when called from Build-BoringLab.ps1.

.PARAMETER SSHKeyPath
    Path to SSH private key for Linux VMs. If not provided, uses default location.
    Passed automatically when called from Build-BoringLab.ps1.

.PARAMETER SkipWindows
    Skip Windows VMs (DC01, WS01, WS02). Useful when only Linux services need fixing.

.EXAMPLE
    .\Install-BoringLab.ps1
    # Full post-install on all VMs (sequential: DC first, then each VM one at a time)

.EXAMPLE
    .\Install-BoringLab.ps1 -VMNames GITLAB01, DOCKER01, VAULT01
    # Re-install only the specified VMs

.EXAMPLE
    .\Install-BoringLab.ps1 -SkipWindows
    # Post-install on all Linux VMs only
#>

param(
    [string[]]$VMNames,
    [PSCredential]$WinCredential,
    [string]$SSHKeyPath,
    [switch]$SkipWindows
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
    Post-Install Configuration
    [Idempotent — Safe to Re-Run]

"@ -ForegroundColor Cyan

Write-Host "    Mode: SEQUENTIAL (one VM at a time)" -ForegroundColor Green
Write-Host ""

# ============================================================
# Load Config & Modules
# ============================================================
Write-Log "Loading configuration..." "Cyan"

$yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml'
if (-not $yamlModule) {
    Write-Log "Installing powershell-yaml module..." "Yellow"
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}

$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module (Join-Path $modulePath "ConfigLoader.psm1") -Force
Import-Module (Join-Path $modulePath "PostInstall.psm1") -Force
Import-Module (Join-Path $modulePath "LabVM.psm1") -Force

$configPath = Join-Path $PSScriptRoot "config.yaml"
if (-not (Test-Path $configPath)) {
    Write-Log "ERROR: config.yaml not found at $configPath" "Red"
    exit 1
}
$Config = Import-LabConfig -Path $configPath
Write-Log "Configuration loaded: $($Config.VMs.Count) VMs defined." "Green"

# ============================================================
# Resolve SSH Key
# ============================================================
if (-not $SSHKeyPath) {
    $SSHKeyPath = Join-Path $Config.VMPath ".ssh\boringlab_ed25519"
}
if (-not (Test-Path $SSHKeyPath)) {
    Write-Log "ERROR: SSH key not found at $SSHKeyPath" "Red"
    Write-Log "Run Build-BoringLab.ps1 first, or provide -SSHKeyPath." "Red"
    exit 1
}
Write-Log "SSH key: $SSHKeyPath" "Green"

# ============================================================
# Resolve Windows Credential
# ============================================================
$needsWindows = $false
if ($VMNames) {
    $needsWindows = ($Config.VMs | Where-Object { $_.Name -in $VMNames -and $_.OS -eq "Windows" }).Count -gt 0
}
elseif (-not $SkipWindows) {
    $needsWindows = ($Config.VMs | Where-Object { $_.OS -eq "Windows" }).Count -gt 0
}

if ($needsWindows -and -not $WinCredential) {
    Write-Host ""
    Write-Host "Enter the Windows Administrator password:" -ForegroundColor Yellow
    $winPassword = Read-Host -Prompt "Admin Password" -AsSecureString
    $WinCredential = New-Object PSCredential("Administrator", $winPassword)
}

# ============================================================
# Determine Target VMs
# ============================================================
if ($VMNames) {
    # Targeted mode: specific VMs
    $targetVMs = @($Config.VMs | Where-Object { $_.Name -in $VMNames })
    $notFound = $VMNames | Where-Object { $_ -notin ($Config.VMs | ForEach-Object { $_.Name }) }
    if ($notFound) {
        Write-Log "WARNING: VMs not found in config: $($notFound -join ', ')" "Yellow"
    }
    if ($targetVMs.Count -eq 0) {
        Write-Log "No matching VMs found. Available: $($Config.VMs.Name -join ', ')" "Red"
        exit 1
    }
}
else {
    # Full mode: all VMs (optionally skip Windows)
    if ($SkipWindows) {
        $targetVMs = @($Config.VMs | Where-Object { $_.OS -ne "Windows" })
    }
    else {
        $targetVMs = @($Config.VMs)
    }
}

Write-Host ""
Write-Log "Target VMs ($($targetVMs.Count)):" "Cyan"
foreach ($vm in $targetVMs) {
    $pad = ($vm.Name).PadRight(14)
    Write-Host "  $pad $($vm.IP)  ($($vm.Role))" -ForegroundColor White
}

# ============================================================
# Start Logging
# ============================================================
$logFile = Join-Path $Config.VMPath "BoringLab-Install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile -Append | Out-Null
Write-Log "Logging to: $logFile" "Green"

# ============================================================
# Verify VMs are Running
# ============================================================
Write-Host ""
Write-Log "Checking VM state..." "Cyan"

$targetNames = $targetVMs | ForEach-Object { $_.Name }
$stoppedVMs = Get-VM | Where-Object { $_.Name -in $targetNames -and $_.State -ne 'Running' }
if ($stoppedVMs) {
    Write-Log "Starting $($stoppedVMs.Count) stopped VM(s)..." "Yellow"
    foreach ($vm in $stoppedVMs) {
        Write-Host "  Starting $($vm.Name)..." -ForegroundColor Yellow
        Start-VM -Name $vm.Name -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 30
}

$running = (Get-VM | Where-Object { $_.Name -in $targetNames -and $_.State -eq 'Running' }).Count
Write-Log "$running/$($targetNames.Count) target VMs are running." "Green"

# ============================================================
# Run Post-Install
# ============================================================
Write-Host ""

if (-not $VMNames) {
    # ── Full mode: all VMs via Invoke-AllPostInstall (sequential with per-VM results) ──
    Write-Log "=== Full Post-Install ===" "Magenta"

    # Build filtered config if SkipWindows
    $installConfig = $Config.Clone()
    if ($SkipWindows) {
        $installConfig.VMs = @($Config.VMs | Where-Object { $_.OS -ne "Windows" })
    }

    Invoke-AllPostInstall -Config $installConfig -WinCredential $WinCredential -SSHKeyPath $SSHKeyPath
}
else {
    # ── Targeted mode: specific VMs by name (sequential) ──
    Write-Log "=== Targeted Post-Install ===" "Magenta"

    # Build targeted config and run through the same sequential pipeline
    $installConfig = $Config.Clone()
    $installConfig.VMs = @($targetVMs)

    Invoke-AllPostInstall -Config $installConfig -WinCredential $WinCredential -SSHKeyPath $SSHKeyPath
}

# ============================================================
# Summary
# ============================================================
$elapsed = (Get-Date) - $script:StartTime
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " BoringLab Post-Install Complete!" -ForegroundColor Green
Write-Host " Total time: $($elapsed.Hours)h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Green
Write-Host " VMs processed: $($targetVMs.Count)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

# Service URLs
$gitlabIP = ($targetVMs | Where-Object { $_.Role -eq "GitLab" } | Select-Object -First 1).IP
$monitorIP = ($targetVMs | Where-Object { $_.Role -eq "Monitoring" } | Select-Object -First 1).IP
$harborIP = ($targetVMs | Where-Object { $_.Role -eq "Docker" } | Select-Object -First 1).IP
$vaultIP = ($targetVMs | Where-Object { $_.Role -eq "Vault" } | Select-Object -First 1).IP
$svcPass = $Config.ServicePassword

if ($gitlabIP -or $monitorIP -or $harborIP -or $vaultIP) {
    Write-Host " Service Access:" -ForegroundColor Cyan
    if ($gitlabIP) { Write-Host "   GitLab:  http://$gitlabIP" -ForegroundColor White }
    if ($monitorIP) { Write-Host "   Grafana: http://${monitorIP}:3000  (admin/$svcPass)" -ForegroundColor White }
    if ($harborIP) { Write-Host "   Harbor:  http://$harborIP       (admin/$svcPass)" -ForegroundColor White }
    if ($vaultIP) { Write-Host "   Vault:   http://${vaultIP}:8200   (keys: /root/vault-keys.txt)" -ForegroundColor White }
    Write-Host ""
}

Write-Host " Next steps:" -ForegroundColor Cyan
Write-Host "   Run .\Audit-BoringLab.ps1 to verify all services" -ForegroundColor White
Write-Host "   Check VM logs: ssh root@<ip> cat /root/*-setup.log" -ForegroundColor White
Write-Host ""
Write-Host (" Log file: " + $logFile) -ForegroundColor Gray

Stop-Transcript | Out-Null
