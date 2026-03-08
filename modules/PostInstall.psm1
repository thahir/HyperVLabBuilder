function Invoke-SSHCommand {
    <#
    .SYNOPSIS
        Executes a script on a Linux VM via SSH key-based auth.
        Uses the BoringLab SSH key injected via cloud-init.
        Falls back to Hyper-V Guest Services if SSH unavailable.
    #>
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$SSHKeyPath,
        [Parameter(Mandatory)][string]$ScriptContent,
        [string]$ScriptName = "postinstall",
        [string]$ServicePassword = "",
        [int]$MaxRetries = 20,
        [int]$RetryDelaySeconds = 30
    )

    $tempScript = "/tmp/boringlab-$ScriptName.sh"
    $localTemp = Join-Path $env:TEMP "$VMName-$ScriptName.sh"
    $scriptContent | Out-File -FilePath $localTemp -Encoding ASCII -Force -NoNewline

    # Build the run command - pass service password as argument if provided
    $svcPassArg = ""
    if ($ServicePassword) { $svcPassArg = " '$ServicePassword'" }

    # Common SSH options
    # ServerAliveInterval/CountMax = kill session if server stops responding for 5 min (60s * 5)
    $sshOpts = @(
        "-i", $SSHKeyPath,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=5"
    )

    $success = $false

    # Method 1: SSH with key-based auth (Windows OpenSSH client)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "[SSH ] Attempting SSH to $IP (try $i/$MaxRetries)..." -ForegroundColor Gray

        # Remove stale host key
        ssh-keygen -R $IP 2>&1 | Out-Null

        # SCP the script to the VM
        & scp @sshOpts $localTemp "root@${IP}:$tempScript" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # Check RHEL subscription now that SSH is confirmed working
            $subStatus = & ssh @sshOpts "root@$IP" "subscription-manager status 2>&1 | head -1" 2>$null
            if ($subStatus -match "Current|Valid") {
                Write-Host "[OK  ] '$VMName' RHEL subscription active." -ForegroundColor Green
            }
            else {
                Write-Warning "'$VMName' RHEL subscription not active. Post-install may fail for packages requiring RHEL repos."
            }

            # Execute the script synchronously and check exit code.
            # Scripts use `exec > logfile 2>&1` so stdout goes to their own log.
            # We capture exit code via a separate echo after the script completes.
            Write-Host "[SSH ] Script deployed to '$VMName'. Executing (this may take several minutes)..." -ForegroundColor Cyan
            & ssh @sshOpts "root@$IP" "chmod +x $tempScript && bash $tempScript$svcPassArg; echo BORINGLAB_EXIT=`$? > /tmp/boringlab-$ScriptName.exit" 2>&1 | Out-Null

            # Check exit code
            $exitResult = & ssh @sshOpts "root@$IP" "cat /tmp/boringlab-$ScriptName.exit 2>/dev/null" 2>&1
            $scriptExitCode = if ($exitResult -match 'BORINGLAB_EXIT=(\d+)') { [int]$Matches[1] } else { -1 }

            if ($scriptExitCode -eq 0) {
                Write-Host "[OK  ] Post-install completed on '$VMName' (exit code 0)." -ForegroundColor Green
            }
            elseif ($scriptExitCode -gt 0) {
                Write-Warning "Post-install on '$VMName' exited with code $scriptExitCode. Check logs on the VM."
            }
            else {
                Write-Host "[OK  ] Script ran on '$VMName' (exit code unknown — check logs)." -ForegroundColor Yellow
            }
            $success = $true
            break
        }

        if ($i -lt $MaxRetries) {
            Write-Host "[SSH ] Connection failed. Retrying in ${RetryDelaySeconds}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    # Method 2: Fallback to Hyper-V Guest Services
    if (-not $success) {
        Write-Host "[INFO] SSH unavailable. Trying Hyper-V Guest Services for '$VMName'..." -ForegroundColor Yellow
        try {
            Copy-VMFile -Name $VMName -SourcePath $localTemp -DestinationPath $tempScript `
                -CreateFullPath -FileSource Host -Force -ErrorAction Stop

            # Create a systemd oneshot service to execute the script
            $serviceContent = @"
[Unit]
Description=BoringLab Post-Install ($ScriptName)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $tempScript
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"@
            $serviceLocal = Join-Path $env:TEMP "$VMName-boringlab.service"
            $serviceContent | Out-File -FilePath $serviceLocal -Encoding ASCII -Force -NoNewline
            Copy-VMFile -Name $VMName -SourcePath $serviceLocal -DestinationPath "/etc/systemd/system/boringlab-postinstall.service" `
                -CreateFullPath -FileSource Host -Force -ErrorAction SilentlyContinue

            $triggerContent = "#!/bin/bash`nchmod +x $tempScript`nsystemctl daemon-reload`nsystemctl start boringlab-postinstall.service"
            $triggerLocal = Join-Path $env:TEMP "$VMName-trigger.sh"
            $triggerContent | Out-File -FilePath $triggerLocal -Encoding ASCII -Force -NoNewline
            Copy-VMFile -Name $VMName -SourcePath $triggerLocal -DestinationPath "/tmp/trigger-postinstall.sh" `
                -CreateFullPath -FileSource Host -Force -ErrorAction SilentlyContinue

            Remove-Item $serviceLocal, $triggerLocal -Force -ErrorAction SilentlyContinue
            $success = $true
            Write-Host "[OK  ] Script deployed via Guest Services to '$VMName'." -ForegroundColor Green
            Write-Host "[INFO] NOTE: You may need to SSH in and run: bash /tmp/trigger-postinstall.sh" -ForegroundColor Yellow
        }
        catch {
            Write-Warning "Guest Services copy also failed for '$VMName': $_"
        }
    }

    Remove-Item $localTemp -Force -ErrorAction SilentlyContinue

    if (-not $success) {
        Write-Warning "Could not deploy post-install script to '$VMName'."
        Write-Host "[INFO] Manual fallback: Copy and run the script on $VMName (${IP}):" -ForegroundColor Yellow
        Write-Host "       scp -i <keypath> post-scripts/$ScriptName.sh root@${IP}:/tmp/" -ForegroundColor Yellow
        Write-Host "       ssh -i <keypath> root@$IP 'bash /tmp/$ScriptName.sh'" -ForegroundColor Yellow
    }

    return $success
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

    # Scripts that accept service password as $1
    $needsPassword = @("setup-database.sh", "setup-monitoring.sh", "setup-docker-harbor.sh", "setup-vault.sh")
    if ($scriptFile -in $needsPassword) {
        $scriptContent = $scriptContent + "`n# Service password is passed as argument `$1"
    }

    Invoke-SSHCommand -VMName $vmName -IP $ip -SSHKeyPath $SSHKeyPath `
        -ScriptContent $scriptContent -ScriptName $scriptFile.Replace(".sh", "") `
        -ServicePassword $svcPass
}

function Invoke-AllPostInstall {
    <#
    .SYNOPSIS
        Orchestrates post-install using wave-based parallel execution.
        Dependency chain:
          Wave 1: DC01 (must complete first — domain + DNS + DHCP)
          Wave 2: ALL remaining VMs in parallel. K8s workers poll for
                  the master join command themselves, so they start as
                  soon as K8S-MASTER finishes (no separate wave).
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
    $modulesPath = $PSScriptRoot

    # Build domain credential
    $domainUser = "$($Config.DomainNetBIOS)\$($Config.DomainAdminUser)"
    $domainCred = New-Object PSCredential($domainUser, $WinCredential.Password)

    # ============================================================
    # Wave 1: Domain Controller (sequential - everything depends on it)
    # ============================================================
    Write-Host ""
    Write-Host "=== Wave 1/2: Domain Controller ===" -ForegroundColor Magenta
    $dc = $vms | Where-Object { $_.Role -eq "DomainController" }
    if ($dc) {
        Invoke-WindowsPostInstall -VMDef $dc -Config $Config -LocalCredential $WinCredential -DomainCredential $domainCred
    }

    # ============================================================
    # Wave 2: ALL remaining VMs in parallel (including K8s workers)
    # ============================================================
    Write-Host ""
    Write-Host "=== Wave 2/2: All Remaining VMs (parallel) ===" -ForegroundColor Magenta

    # Wave 2: ALL remaining VMs in a single parallel batch (including K8s workers).
    # K8s workers poll for the join command from master — they start as soon as
    # the master finishes instead of waiting for the entire wave to complete.
    # Using ForEach-Object -Parallel (Start-ThreadJob can't auto-load Hyper-V CDXML module)
    $wave2VMs = @($vms | Where-Object { $_.Role -ne "DomainController" })

    if ($wave2VMs.Count -gt 0) {
        Write-Host "[PARA] Running $($wave2VMs.Count) post-install jobs in parallel:" -ForegroundColor Cyan
        foreach ($v in $wave2VMs) {
            Write-Host "       - Post-$($v.Name)" -ForegroundColor Gray
        }

        $wave2VMs | ForEach-Object -ThrottleLimit 11 -Parallel {
            $vmDef     = $_
            $config    = $using:Config
            $localCred = $using:WinCredential
            $domCred   = $using:domainCred
            $keyPath   = $using:SSHKeyPath
            $modDir    = $using:modulesPath

            Import-Module (Join-Path $modDir "PostInstall.psm1") -Force
            Import-Module (Join-Path $modDir "LabVM.psm1") -Force

            try {
                if ($vmDef.Role -eq "K8sWorker") {
                    # Workers poll for the join command from K8S-MASTER (runs in parallel)
                    $masterIP = ($config.VMs | Where-Object { $_.Role -eq "K8sMaster" }).IP
                    $sshOpts = @("-i", $keyPath, "-o", "StrictHostKeyChecking=no",
                                 "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes")
                    $joinCmd = $null

                    Write-Host "[K8S ] $($vmDef.Name): Waiting for master join command..." -ForegroundColor Cyan
                    for ($try = 1; $try -le 40; $try++) {
                        Start-Sleep -Seconds 30
                        $result = & ssh @sshOpts "root@$masterIP" "cat /root/k8s-join-command.txt 2>/dev/null" 2>$null
                        if ($result -match "kubeadm join") {
                            $joinCmd = $result
                            Write-Host "[K8S ] $($vmDef.Name): Join command retrieved from master." -ForegroundColor Green
                            break
                        }
                    }
                    if (-not $joinCmd) {
                        Write-Warning "$($vmDef.Name): Could not get join command after 20 min. Trying kubeadm token create..."
                        $joinCmd = & ssh @sshOpts "root@$masterIP" "kubeadm token create --print-join-command 2>/dev/null" 2>$null
                    }

                    Invoke-LinuxPostInstall -VMDef $vmDef -Config $config -SSHKeyPath $keyPath -K8sJoinCommand $joinCmd
                }
                elseif ($vmDef.OS -eq "Windows") {
                    Invoke-WindowsPostInstall -VMDef $vmDef -Config $config -LocalCredential $localCred -DomainCredential $domCred
                }
                else {
                    Invoke-LinuxPostInstall -VMDef $vmDef -Config $config -SSHKeyPath $keyPath
                }
                Write-Host "[OK  ] Post-$($vmDef.Name) completed." -ForegroundColor Green
            }
            catch {
                Write-Warning "Post-install for $($vmDef.Name) failed: $_"
            }
        }
    }

    # ============================================================
    # Summary
    # ============================================================
    Write-Host ""
    Write-Host "[OK  ] RHEL01 and RHEL02 are ready as general-purpose servers." -ForegroundColor Green

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
