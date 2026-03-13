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

.PARAMETER Sequential
    Run VMs one at a time instead of in parallel. Slower but much easier to
    troubleshoot — clean output, clear per-VM pass/fail, no interleaved logs.

.EXAMPLE
    .\Install-BoringLab.ps1
    # Full post-install on all VMs (wave-based: DC first, then all others in parallel)

.EXAMPLE
    .\Install-BoringLab.ps1 -Sequential
    # Same as above but one VM at a time — ideal for first run / troubleshooting

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
    [switch]$SkipWindows,
    [switch]$Sequential
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

$modeLabel = if ($Sequential) { "SEQUENTIAL (one at a time)" } else { "PARALLEL" }
Write-Host "    Mode: $modeLabel" -ForegroundColor $(if ($Sequential) { "Yellow" } else { "Green" })
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

# Build domain credential once (used by both modes)
$domainCred = $null
if ($WinCredential) {
    $domainUser = "$($Config.DomainNetBIOS)\$($Config.DomainAdminUser)"
    $domainCred = New-Object PSCredential($domainUser, $WinCredential.Password)
}

# Track results for summary
$script:results = @()

function Invoke-LinuxVMInstall {
    <# Runs post-install on a single Linux VM. Used by sequential mode. #>
    param([hashtable]$VMDef)

    $vmStart = Get-Date
    $vmName = $VMDef.Name
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Log "[$vmName] Starting post-install ($($VMDef.Role))..." "Cyan"
    Write-Host ("=" * 60) -ForegroundColor Cyan

    try {
        if ($VMDef.Role -eq "K8sWorker") {
            $masterIP = ($Config.VMs | Where-Object { $_.Role -eq "K8sMaster" }).IP
            $sshOpts = @("-i", $SSHKeyPath, "-o", "StrictHostKeyChecking=no",
                         "-o", "UserKnownHostsFile=/dev/null",
                         "-o", "ConnectTimeout=10", "-o", "BatchMode=yes")
            $joinCmd = & ssh @sshOpts "root@$masterIP" `
                "cat /root/k8s-join-command.txt 2>/dev/null || kubeadm token create --print-join-command 2>/dev/null" 2>$null

            if (-not ($joinCmd -match "kubeadm join")) {
                Write-Warning "[$vmName] Could not get join command. Worker will try to fetch it directly."
                $joinCmd = $null
            }

            Invoke-LinuxPostInstall -VMDef $VMDef -Config $Config `
                -SSHKeyPath $SSHKeyPath -K8sJoinCommand $joinCmd
        }
        else {
            Invoke-LinuxPostInstall -VMDef $VMDef -Config $Config -SSHKeyPath $SSHKeyPath
        }

        $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
        Write-Host "[PASS] $vmName completed in ${elapsed}m" -ForegroundColor Green
        $script:results += @{ Name = $vmName; Status = "PASS"; Time = "${elapsed}m" }
    }
    catch {
        $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
        Write-Host "[FAIL] $vmName failed after ${elapsed}m: $_" -ForegroundColor Red
        $script:results += @{ Name = $vmName; Status = "FAIL"; Time = "${elapsed}m"; Error = "$_" }
    }
}

if ($Sequential) {
    # ── Sequential mode: one VM at a time, clear output ──
    Write-Log "=== Sequential Post-Install ===" "Magenta"

    # Windows VMs first (DC before member servers)
    $windowsTargets = @($targetVMs | Where-Object { $_.OS -eq "Windows" })
    if ($windowsTargets.Count -gt 0) {
        $dc = $windowsTargets | Where-Object { $_.Role -eq "DomainController" }
        if ($dc) {
            $vmStart = Get-Date
            Write-Host ""
            Write-Host ("=" * 60) -ForegroundColor Cyan
            Write-Log "[$($dc.Name)] Starting post-install (DomainController)..." "Cyan"
            Write-Host ("=" * 60) -ForegroundColor Cyan
            try {
                Invoke-WindowsPostInstall -VMDef $dc -Config $Config `
                    -LocalCredential $WinCredential -DomainCredential $domainCred
                $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
                Write-Host "[PASS] $($dc.Name) completed in ${elapsed}m" -ForegroundColor Green
                $script:results += @{ Name = $dc.Name; Status = "PASS"; Time = "${elapsed}m" }
            }
            catch {
                $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
                Write-Host "[FAIL] $($dc.Name) failed after ${elapsed}m: $_" -ForegroundColor Red
                $script:results += @{ Name = $dc.Name; Status = "FAIL"; Time = "${elapsed}m"; Error = "$_" }
            }
        }

        foreach ($vm in ($windowsTargets | Where-Object { $_.Role -ne "DomainController" })) {
            $vmStart = Get-Date
            Write-Host ""
            Write-Host ("=" * 60) -ForegroundColor Cyan
            Write-Log "[$($vm.Name)] Starting post-install ($($vm.Role))..." "Cyan"
            Write-Host ("=" * 60) -ForegroundColor Cyan
            try {
                Invoke-WindowsPostInstall -VMDef $vm -Config $Config `
                    -LocalCredential $WinCredential -DomainCredential $domainCred
                $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
                Write-Host "[PASS] $($vm.Name) completed in ${elapsed}m" -ForegroundColor Green
                $script:results += @{ Name = $vm.Name; Status = "PASS"; Time = "${elapsed}m" }
            }
            catch {
                $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
                Write-Host "[FAIL] $($vm.Name) failed after ${elapsed}m: $_" -ForegroundColor Red
                $script:results += @{ Name = $vm.Name; Status = "FAIL"; Time = "${elapsed}m"; Error = "$_" }
            }
        }
    }

    # Linux VMs: one at a time, K8s master before workers
    $linuxTargets = @($targetVMs | Where-Object { $_.OS -eq "RHEL" })
    if ($linuxTargets.Count -gt 0) {
        # Order: K8s master first, then workers, then everything else
        $k8sMaster  = @($linuxTargets | Where-Object { $_.Role -eq "K8sMaster" })
        $k8sWorkers = @($linuxTargets | Where-Object { $_.Role -eq "K8sWorker" })
        $others     = @($linuxTargets | Where-Object { $_.Role -notin @("K8sMaster", "K8sWorker") })

        $orderedLinux = $k8sMaster + $others + $k8sWorkers

        foreach ($vmDef in $orderedLinux) {
            Invoke-LinuxVMInstall -VMDef $vmDef
        }
    }

    # Print results table
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Log "=== Results ===" "Magenta"
    Write-Host ("=" * 60) -ForegroundColor Magenta
    foreach ($r in $script:results) {
        $statusColor = if ($r.Status -eq "PASS") { "Green" } else { "Red" }
        $pad = ($r.Name).PadRight(14)
        $line = "  $pad $($r.Status)  ($($r.Time))"
        if ($r.Error) { $line += "  — $($r.Error)" }
        Write-Host $line -ForegroundColor $statusColor
    }
    $passed = ($script:results | Where-Object { $_.Status -eq "PASS" }).Count
    $failed = ($script:results | Where-Object { $_.Status -eq "FAIL" }).Count
    Write-Host ""
    Write-Host "  Passed: $passed  |  Failed: $failed  |  Total: $($script:results.Count)" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })
}
elseif (-not $VMNames) {
    # ── Full mode (parallel): use wave-based orchestration from PostInstall.psm1 ──
    Write-Log "=== Full Post-Install (Wave-Based Parallel) ===" "Magenta"

    # Build filtered config if SkipWindows
    $installConfig = $Config.Clone()
    if ($SkipWindows) {
        $installConfig.VMs = @($Config.VMs | Where-Object { $_.OS -ne "Windows" })
    }

    Invoke-AllPostInstall -Config $installConfig -WinCredential $WinCredential -SSHKeyPath $SSHKeyPath
}
else {
    # ── Targeted mode (parallel): run specific VMs ──
    Write-Log "=== Targeted Post-Install ===" "Magenta"

    # Windows VMs: sequential (DC must complete before member servers)
    $windowsTargets = @($targetVMs | Where-Object { $_.OS -eq "Windows" })
    if ($windowsTargets.Count -gt 0) {
        Write-Log "Installing $($windowsTargets.Count) Windows VM(s)..." "Cyan"

        # DC first
        $dc = $windowsTargets | Where-Object { $_.Role -eq "DomainController" }
        if ($dc) {
            Invoke-WindowsPostInstall -VMDef $dc -Config $Config `
                -LocalCredential $WinCredential -DomainCredential $domainCred
        }

        # Then member servers
        foreach ($vm in ($windowsTargets | Where-Object { $_.Role -ne "DomainController" })) {
            Invoke-WindowsPostInstall -VMDef $vm -Config $Config `
                -LocalCredential $WinCredential -DomainCredential $domainCred
        }
    }

    # Linux VMs: parallel
    $linuxTargets = @($targetVMs | Where-Object { $_.OS -eq "RHEL" })
    if ($linuxTargets.Count -gt 0) {
        Write-Log "Installing $($linuxTargets.Count) Linux VM(s) in parallel..." "Cyan"
        foreach ($v in $linuxTargets) {
            Write-Host "  - $($v.Name) ($($v.Role))" -ForegroundColor Gray
        }

        $linuxTargets | ForEach-Object -ThrottleLimit 11 -Parallel {
            $vmDef   = $_
            $config  = $using:Config
            $keyPath = $using:SSHKeyPath
            $modDir  = $using:modulePath

            Import-Module (Join-Path $modDir "PostInstall.psm1") -Force
            Import-Module (Join-Path $modDir "LabVM.psm1") -Force

            try {
                if ($vmDef.Role -eq "K8sWorker") {
                    $masterIP = ($config.VMs | Where-Object { $_.Role -eq "K8sMaster" }).IP
                    $sshOpts = @("-i", $keyPath, "-o", "StrictHostKeyChecking=no",
                                 "-o", "UserKnownHostsFile=/dev/null",
                                 "-o", "ConnectTimeout=10", "-o", "BatchMode=yes")
                    $joinCmd = & ssh @sshOpts "root@$masterIP" `
                        "cat /root/k8s-join-command.txt 2>/dev/null || kubeadm token create --print-join-command 2>/dev/null" 2>$null

                    if (-not ($joinCmd -match "kubeadm join")) {
                        Write-Warning "$($vmDef.Name): Could not get join command. Worker will try to fetch it directly."
                        $joinCmd = $null
                    }

                    Invoke-LinuxPostInstall -VMDef $vmDef -Config $config `
                        -SSHKeyPath $keyPath -K8sJoinCommand $joinCmd
                }
                else {
                    Invoke-LinuxPostInstall -VMDef $vmDef -Config $config -SSHKeyPath $keyPath
                }
                Write-Host "[OK  ] Post-install completed for $($vmDef.Name)." -ForegroundColor Green
            }
            catch {
                Write-Warning "Post-install failed for $($vmDef.Name): $_"
            }
        }
    }
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
