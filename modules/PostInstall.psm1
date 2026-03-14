function Invoke-SSHCommand {
    <#
    .SYNOPSIS
        Executes a script on a Linux VM via SSH using nohup + poll pattern.
        Script runs detached (survives SSH disconnect / Ctrl+C), and the build
        polls for the exit-code file to appear. This prevents:
          - Infinite hangs (Linux timeout kills the script)
          - Killed scripts on SSH disconnect (nohup keeps it running)
          - Orphaned PowerShell pipelines
    #>
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$SSHKeyPath,
        [Parameter(Mandatory)][string]$ScriptContent,
        [string]$ScriptName = "postinstall",
        [string]$ServicePassword = "",
        [int]$MaxRetries = 20,
        [int]$RetryDelaySeconds = 30,
        [int]$ExecutionTimeoutMinutes = 30,
        [int]$PollIntervalSeconds = 30
    )

    $tempScript = "/tmp/boringlab-$ScriptName.sh"
    $exitFile   = "/tmp/boringlab-$ScriptName.exit"
    $pidFile    = "/tmp/boringlab-$ScriptName.pid"
    $localTemp  = Join-Path $env:TEMP "$VMName-$ScriptName.sh"
    $scriptContent | Out-File -FilePath $localTemp -Encoding ASCII -Force -NoNewline

    # Build the run command - pass service password as argument if provided
    $svcPassArg = ""
    if ($ServicePassword) { $svcPassArg = " '$ServicePassword'" }

    # Common SSH options
    $sshOpts = @(
        "-i", $SSHKeyPath,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes"
    )

    $deployed = $false

    # Remove stale host key once before retrying
    ssh-keygen -R $IP 2>&1 | Out-Null

    # --- Phase 1: Deploy script via SCP ---
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "[SSH ] Attempting SSH to $IP (try $i/$MaxRetries)..." -ForegroundColor Gray

        & scp @sshOpts $localTemp "root@${IP}:$tempScript" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $deployed = $true
            break
        }

        if ($i -lt $MaxRetries) {
            Write-Host "[SSH ] Connection failed. Retrying in ${RetryDelaySeconds}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    # Fallback: Hyper-V Guest Services
    if (-not $deployed) {
        Write-Host "[INFO] SSH unavailable. Trying Hyper-V Guest Services for '$VMName'..." -ForegroundColor Yellow
        try {
            Copy-VMFile -Name $VMName -SourcePath $localTemp -DestinationPath $tempScript `
                -CreateFullPath -FileSource Host -Force -ErrorAction Stop
            $deployed = $true
        }
        catch {
            Write-Warning "Guest Services copy also failed for '$VMName': $_"
        }
    }

    Remove-Item $localTemp -Force -ErrorAction SilentlyContinue

    if (-not $deployed) {
        Write-Warning "Could not deploy post-install script to '$VMName'."
        Write-Host "[INFO] Manual fallback: scp post-scripts/$ScriptName.sh root@${IP}:/tmp/ && ssh root@$IP 'bash /tmp/$ScriptName.sh'" -ForegroundColor Yellow
        return $false
    }

    # Check RHEL subscription
    $subStatus = & ssh @sshOpts "root@$IP" "subscription-manager status 2>&1" 2>$null
    if ($subStatus -match "Overall Status:\s*(Current|Valid|Registered)") {
        Write-Host "[OK  ] '$VMName' RHEL subscription active." -ForegroundColor Green
    }
    else {
        Write-Warning "'$VMName' RHEL subscription not active. Post-install may fail for packages requiring RHEL repos."
    }

    # --- Phase 2: Launch script detached via nohup ---
    # The wrapper: run the actual script with timeout, write exit code to file, record PID.
    # nohup ensures the script survives SSH disconnect / Ctrl+C.
    $timeoutSec = $ExecutionTimeoutMinutes * 60
    # Note: nohup backgrounds with &, so we use ; (not &&) to chain echo $!
    # because & terminates the command and && after & is a bash syntax error.
    $launchCmd = "rm -f $exitFile $pidFile && chmod +x $tempScript && nohup bash -c 'timeout --signal=TERM --kill-after=30 $timeoutSec bash $tempScript$svcPassArg; echo BORINGLAB_EXIT=`$`? > $exitFile' > /tmp/boringlab-$ScriptName-nohup.log 2>&1 & echo `$! > $pidFile"

    Write-Host "[SSH ] Script deployed to '$VMName'. Launching detached (timeout: ${ExecutionTimeoutMinutes}m)..." -ForegroundColor Cyan
    $launchOutput = & ssh @sshOpts "root@$IP" $launchCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "SSH launch command failed for '$VMName' (exit code: $LASTEXITCODE). Output: $launchOutput"
    }

    # --- Phase 3: Poll for completion ---
    $deadline = (Get-Date).AddMinutes($ExecutionTimeoutMinutes + 5)  # Extra 5 min grace
    $lastProgress = ""

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds

        # Check if exit file exists (script finished)
        $exitResult = & ssh @sshOpts "root@$IP" "cat $exitFile 2>/dev/null" 2>$null
        if ($exitResult -match 'BORINGLAB_EXIT=(\d+)') {
            $scriptExitCode = [int]$Matches[1]

            if ($scriptExitCode -eq 0) {
                Write-Host "[OK  ] Post-install completed on '$VMName' (exit code 0)." -ForegroundColor Green
            }
            elseif ($scriptExitCode -eq 124) {
                Write-Warning "Post-install on '$VMName' TIMED OUT after ${ExecutionTimeoutMinutes}m. Check /root/*-setup.log on the VM."
            }
            elseif ($scriptExitCode -gt 0) {
                Write-Warning "Post-install on '$VMName' exited with code $scriptExitCode. Check logs on the VM."
            }
            return $true
        }

        # Script still running — show progress (last line of setup log)
        $progress = & ssh @sshOpts "root@$IP" "tail -1 /root/*-setup.log 2>/dev/null | head -c 120" 2>$null
        if ($progress -and $progress -ne $lastProgress) {
            $elapsed = [math]::Round(((Get-Date) - $deadline.AddMinutes(-($ExecutionTimeoutMinutes + 5))).TotalMinutes)
            Write-Host "[POLL] '$VMName' (${elapsed}m): $progress" -ForegroundColor Gray
            $lastProgress = $progress
        }
    }

    Write-Warning "Post-install on '$VMName' did not complete within $($ExecutionTimeoutMinutes + 5)m. Script may still be running on the VM."
    return $false
}

function Invoke-WindowsPostInstall {
    <#
    .SYNOPSIS
        Runs post-install configuration on a Windows VM via PowerShell Direct.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VMDef,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [PSCredential]$LocalCredential,

        [PSCredential]$DomainCredential
    )

    $vmName = $VMDef.Name
    $role   = $VMDef.Role
    $scriptBase = Join-Path (Split-Path $PSScriptRoot -Parent) "post-scripts"

    switch ($role) {
        "DomainController" {
            Write-Host "[POST] Configuring DC01 as Active Directory Domain Controller..." -ForegroundColor Cyan
            $dcScript = Get-Content (Join-Path $scriptBase "Configure-DC.ps1") -Raw
            $params = @{
                DomainName    = $Config.DomainName
                DomainNetBIOS = $Config.DomainNetBIOS
                SafeModePass  = $LocalCredential.GetNetworkCredential().Password
                DNSForwarders = $Config.DNSForwarders
            }

            Invoke-Command -VMName $vmName -Credential $LocalCredential -ScriptBlock {
                param($script, $p)
                $scriptBlock = [ScriptBlock]::Create($script)
                & $scriptBlock @p
            } -ArgumentList $dcScript, $params

            # Wait for DC reboot after promotion (AD promotion forces reboot)
            Write-Host "[WAIT] Waiting for DC01 to reboot after AD promotion..." -ForegroundColor Cyan
            Start-Sleep -Seconds 60  # Give time for shutdown to initiate

            # After promotion, local admin becomes domain admin.
            # Try domain credential first, fall back to local credential.
            $dcCredential = $DomainCredential
            $dcReady = $false
            for ($retry = 1; $retry -le 20; $retry++) {
                # Try domain credential
                try {
                    Invoke-Command -VMName $vmName -Credential $DomainCredential -ScriptBlock {
                        Get-ADDomain | Out-Null
                    } -ErrorAction Stop
                    $dcCredential = $DomainCredential
                    $dcReady = $true
                    Write-Host "[OK  ] DC01 AD services ready (domain credential)." -ForegroundColor Green
                    break
                }
                catch { }

                # Try local credential (may work briefly during reboot)
                try {
                    $result = Invoke-Command -VMName $vmName -Credential $LocalCredential -ScriptBlock {
                        $adReady = $false
                        try { Get-ADDomain | Out-Null; $adReady = $true } catch { }
                        return @{ ComputerName = $env:COMPUTERNAME; ADReady = $adReady }
                    } -ErrorAction Stop

                    if ($result.ADReady) {
                        $dcCredential = $LocalCredential
                        $dcReady = $true
                        Write-Host "[OK  ] DC01 AD services ready (local credential)." -ForegroundColor Green
                        break
                    }
                    else {
                        Write-Host "[WAIT] DC01 reachable but AD not ready yet (attempt $retry/20)..." -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Host "[WAIT] DC01 not reachable yet (attempt $retry/20)..." -ForegroundColor Gray
                }

                Start-Sleep -Seconds 30
            }

            if (-not $dcReady) {
                Write-Warning "AD services did not become ready on DC01 after 10 minutes. DHCP and DNS config may fail."
            }

            # Configure DNS forwarders
            Write-Host "[POST] Configuring DNS forwarders on DC01..." -ForegroundColor Cyan
            Invoke-Command -VMName $vmName -Credential $dcCredential -ScriptBlock {
                param($forwarders)
                Set-DnsServerForwarder -IPAddress $forwarders -ErrorAction SilentlyContinue
            } -ArgumentList (,$Config.DNSForwarders)

            # Configure DHCP after DC is back
            Write-Host "[POST] Configuring DHCP on DC01..." -ForegroundColor Cyan
            $dcIP = ($Config.VMs | Where-Object { $_.Role -eq "DomainController" } | Select-Object -First 1).IP
            $dcFQDN = "DC01.$($Config.DomainName)"
            $domainName = $Config.DomainName
            $labName = $Config.LabName
            $labGateway = $Config.Gateway

            Invoke-Command -VMName $vmName -Credential $dcCredential -ScriptBlock {
                param($dcFQDN, $dcIP, $domainName, $labName, $labGateway)
                Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null

                Add-DhcpServerInDC -DnsName $dcFQDN -IPAddress $dcIP -ErrorAction SilentlyContinue

                # Only create scope if it doesn't exist
                $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq "10.10.10.0" }
                if (-not $existing) {
                    Add-DhcpServerv4Scope -Name $labName `
                        -StartRange 10.10.10.100 `
                        -EndRange 10.10.10.200 `
                        -SubnetMask 255.255.255.0 `
                        -State Active

                    Set-DhcpServerv4OptionValue -ScopeId 10.10.10.0 `
                        -DnsDomain $domainName `
                        -DnsServer $dcIP `
                        -Router $labGateway
                }

                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue
            } -ArgumentList $dcFQDN, $dcIP, $domainName, $labName, $labGateway
            Write-Host "[OK  ] DC01 fully configured (AD + DNS + DHCP)." -ForegroundColor Green
        }

        "MemberServer" {
            Write-Host "[POST] Joining '$vmName' to domain and installing features..." -ForegroundColor Cyan
            $joinScript = Get-Content (Join-Path $scriptBase "Join-Domain.ps1") -Raw

            $dcIPAddr = ($Config.VMs | Where-Object { $_.Role -eq "DomainController" } | Select-Object -First 1).IP
            Invoke-Command -VMName $vmName -Credential $LocalCredential -ScriptBlock {
                param($script, $domain, $domainCred, $features, $dcip)
                $scriptBlock = [ScriptBlock]::Create($script)
                & $scriptBlock -DomainName $domain -Credential $domainCred -Features $features -DCIP $dcip
            } -ArgumentList $joinScript, $Config.DomainName, $DomainCredential, $VMDef.Features, $dcIPAddr

            # Wait for reboot after domain join
            Start-Sleep -Seconds 30
            Wait-LabVMReady -VMName $vmName -OS "Windows" -Credential $DomainCredential -IP $VMDef.IP -TimeoutMinutes 15
            Write-Host "[OK  ] '$vmName' joined to domain and configured." -ForegroundColor Green
        }
    }
}

function Invoke-LinuxPostInstall {
    <#
    .SYNOPSIS
        Runs post-install configuration on a Linux VM via SSH key-based auth.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VMDef,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$SSHKeyPath,

        [string]$K8sJoinCommand
    )

    $vmName    = $VMDef.Name
    $role      = $VMDef.Role
    $ip        = $VMDef.IP
    $svcPass   = $Config.ServicePassword

    Write-Host "[POST] Running post-install for '$vmName' (role: $role)..." -ForegroundColor Cyan

    # Determine which script to run
    $scriptFile = switch ($role) {
        "Ansible"    { "setup-ansible.sh" }
        "K8sMaster"  { "setup-k8s-master.sh" }
        "K8sWorker"  { "setup-k8s-worker.sh" }
        "GitLab"     { "setup-gitlab.sh" }
        "Docker"     { "setup-docker-harbor.sh" }
        "Monitoring" { "setup-monitoring.sh" }
        "Database"   { "setup-database.sh" }
        "Vault"      { "setup-vault.sh" }
        "General"    { $null }
        default      { $null }
    }

    if (-not $scriptFile) {
        Write-Host "[SKIP] No post-install script for '$vmName' (role: $role)." -ForegroundColor Yellow
        return
    }

    # Use $PSScriptRoot (modules/) to reliably find post-scripts/
    $scriptBase = Join-Path (Split-Path $PSScriptRoot -Parent) "post-scripts"
    $scriptPath = Join-Path $scriptBase $scriptFile
    if (-not (Test-Path $scriptPath)) {
        Write-Warning "Post-install script not found: $scriptPath"
        return
    }

    $scriptContent = Get-Content $scriptPath -Raw

    # For K8s workers, inject the join command
    if ($role -eq "K8sWorker" -and $K8sJoinCommand) {
        $scriptContent = $scriptContent -replace "##K8S_JOIN_COMMAND##", $K8sJoinCommand
    }

    Invoke-SSHCommand -VMName $vmName -IP $ip -SSHKeyPath $SSHKeyPath `
        -ScriptContent $scriptContent -ScriptName $scriptFile.Replace(".sh", "") `
        -ServicePassword $svcPass
}

function Invoke-AllPostInstall {
    <#
    .SYNOPSIS
        Orchestrates post-install sequentially with detailed per-VM logging.
        VM deployment is parallel (Phase 3-5), but post-install runs one VM
        at a time for clean output, clear pass/fail, and easy troubleshooting.

        Execution order (dependency-aware):
          1. DC01             — AD + DNS + DHCP (everything depends on this)
          2. WS01, WS02       — Domain join + features
          3. K8S-MASTER       — Cluster init + Calico + join command
          4. ANSIBLE01, GITLAB01, DOCKER01, MONITOR01, DB01, VAULT01, RHEL01, RHEL02
          5. K8S-WORKER1, K8S-WORKER2  — Join cluster (needs master done)
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [PSCredential]$WinCredential,

        [Parameter(Mandatory)]
        [string]$SSHKeyPath
    )

    $vms = $Config.VMs
    $results = @()

    # Build domain credential
    $domainUser = "$($Config.DomainNetBIOS)\$($Config.DomainAdminUser)"
    $domainCred = New-Object PSCredential($domainUser, $WinCredential.Password)

    # ── Build execution order ──
    # 1. DC first, 2. Windows member servers, 3. K8s master, 4. Other Linux, 5. K8s workers
    $dc          = @($vms | Where-Object { $_.Role -eq "DomainController" })
    $winMembers  = @($vms | Where-Object { $_.OS -eq "Windows" -and $_.Role -ne "DomainController" })
    $k8sMaster   = @($vms | Where-Object { $_.Role -eq "K8sMaster" })
    $k8sWorkers  = @($vms | Where-Object { $_.Role -eq "K8sWorker" })
    $otherLinux  = @($vms | Where-Object { $_.OS -eq "RHEL" -and $_.Role -notin @("K8sMaster", "K8sWorker") })
    $orderedVMs  = $dc + $winMembers + $k8sMaster + $otherLinux + $k8sWorkers

    $totalVMs = $orderedVMs.Count
    Write-Host ""
    Write-Host "=== Sequential Post-Install ($totalVMs VMs) ===" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Execution order:" -ForegroundColor Cyan
    $seq = 1
    foreach ($v in $orderedVMs) {
        $pad = ($v.Name).PadRight(14)
        Write-Host "    $seq. $pad $($v.IP)  ($($v.Role))" -ForegroundColor White
        $seq++
    }
    Write-Host ""

    # ── Run each VM sequentially ──
    $vmIndex = 0
    foreach ($vmDef in $orderedVMs) {
        $vmIndex++
        $vmName = $vmDef.Name
        $vmStart = Get-Date
        $ts = $vmStart.ToString("HH:mm:ss")

        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor Cyan
        Write-Host "[$ts] [$vmIndex/$totalVMs] $vmName — $($vmDef.Role) ($($vmDef.OS)) @ $($vmDef.IP)" -ForegroundColor Cyan
        Write-Host ("=" * 70) -ForegroundColor Cyan

        try {
            if ($vmDef.OS -eq "Windows") {
                Invoke-WindowsPostInstall -VMDef $vmDef -Config $Config `
                    -LocalCredential $WinCredential -DomainCredential $domainCred
            }
            elseif ($vmDef.Role -eq "K8sWorker") {
                # Fetch join command from master (master already completed at this point)
                $masterIP = ($vms | Where-Object { $_.Role -eq "K8sMaster" }).IP
                $sshOpts = @("-i", $SSHKeyPath, "-o", "StrictHostKeyChecking=no",
                             "-o", "UserKnownHostsFile=/dev/null",
                             "-o", "ConnectTimeout=10", "-o", "BatchMode=yes")

                Write-Host "[K8S ] Fetching join command from master ($masterIP)..." -ForegroundColor Cyan
                $joinCmd = & ssh @sshOpts "root@$masterIP" `
                    "cat /root/k8s-join-command.txt 2>/dev/null || kubeadm token create --print-join-command 2>/dev/null" 2>$null

                if ($joinCmd -match "kubeadm join") {
                    Write-Host "[K8S ] Join command retrieved." -ForegroundColor Green
                }
                else {
                    Write-Warning "[$vmName] Could not get join command from master."
                    $joinCmd = $null
                }

                Invoke-LinuxPostInstall -VMDef $vmDef -Config $Config `
                    -SSHKeyPath $SSHKeyPath -K8sJoinCommand $joinCmd
            }
            else {
                Invoke-LinuxPostInstall -VMDef $vmDef -Config $Config -SSHKeyPath $SSHKeyPath
            }

            $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
            $ts = (Get-Date).ToString("HH:mm:ss")
            Write-Host "[$ts] [PASS] $vmName completed in ${elapsed}m" -ForegroundColor Green
            $results += @{ Name = $vmName; Status = "PASS"; Time = "${elapsed}m" }
        }
        catch {
            $elapsed = [math]::Round(((Get-Date) - $vmStart).TotalMinutes, 1)
            $ts = (Get-Date).ToString("HH:mm:ss")
            Write-Host "[$ts] [FAIL] $vmName failed after ${elapsed}m: $_" -ForegroundColor Red
            $results += @{ Name = $vmName; Status = "FAIL"; Time = "${elapsed}m"; Error = "$_" }
        }
    }

    # ============================================================
    # Results Table
    # ============================================================
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host " Post-Install Results" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
    foreach ($r in $results) {
        $statusColor = if ($r.Status -eq "PASS") { "Green" } else { "Red" }
        $pad = ($r.Name).PadRight(14)
        $line = "  $pad $($r.Status)  ($($r.Time))"
        if ($r.Error) { $line += "  — $($r.Error)" }
        Write-Host $line -ForegroundColor $statusColor
    }
    $passed = ($results | Where-Object { $_.Status -eq "PASS" }).Count
    $failed = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
    Write-Host ""
    Write-Host "  Passed: $passed  |  Failed: $failed  |  Total: $($results.Count)" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })

    # ============================================================
    # Summary
    # ============================================================
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " BoringLab Post-Install Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Lab Access Summary:" -ForegroundColor Cyan
    foreach ($vm in $vms) {
        $pad = ($vm.Name).PadRight(14)
        Write-Host "  $pad : $($vm.IP)  ($($vm.Role))" -ForegroundColor White
    }
    Write-Host ""
    $gitlabIP = ($vms | Where-Object { $_.Role -eq "GitLab" } | Select-Object -First 1).IP
    $monitorIP = ($vms | Where-Object { $_.Role -eq "Monitoring" } | Select-Object -First 1).IP
    $harborIP = ($vms | Where-Object { $_.Role -eq "Docker" } | Select-Object -First 1).IP
    $vaultIP = ($vms | Where-Object { $_.Role -eq "Vault" } | Select-Object -First 1).IP
    $svcPass = $Config.ServicePassword

    Write-Host "  Domain:  $($Config.DomainName)" -ForegroundColor White
    Write-Host "  Windows: mstsc /v:<ip>  or  Invoke-Command -VMName <name>" -ForegroundColor White
    Write-Host "  Linux:   ssh root@<ip>" -ForegroundColor White
    if ($gitlabIP) { Write-Host "  GitLab:  http://$gitlabIP" -ForegroundColor White }
    if ($monitorIP) { Write-Host "  Grafana: http://${monitorIP}:3000  (admin/$svcPass)" -ForegroundColor White }
    if ($harborIP) { Write-Host "  Harbor:  http://$harborIP       (admin/$svcPass)" -ForegroundColor White }
    if ($vaultIP) { Write-Host "  Vault:   http://${vaultIP}:8200   (keys in /root/vault-keys.txt)" -ForegroundColor White }
}

Export-ModuleMember -Function Invoke-WindowsPostInstall, Invoke-LinuxPostInstall, Invoke-AllPostInstall
