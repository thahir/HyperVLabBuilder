function New-LabVM {
    <#
    .SYNOPSIS
        Creates a Hyper-V VM from a cloned template VHDX.
        For Linux VMs, attaches a cloud-init ISO.
        For Windows VMs, unattend.xml is already injected into the VHDX.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VMDef,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$TemplateVHDX,

        [string]$CloudInitISO  # Cloud-init ISO for Linux VMs
    )

    $vmName    = $VMDef.Name
    $vmPath    = $Config.VMPath
    $vmFolder  = Join-Path $vmPath $vmName
    $vhdxPath  = Join-Path $vmFolder "$vmName.vhdx"
    $diskSizeBytes = [int64]$VMDef.DiskGB * 1GB

    # --- Skip if VM already exists ---
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "[SKIP] VM '$vmName' already exists." -ForegroundColor Yellow
        return
    }

    Write-Host "[VM  ] Creating VM '$vmName' (RAM: $($VMDef.RAM / 1GB)GB, vCPU: $($VMDef.vCPU), Disk: $($VMDef.DiskGB)GB)..." -ForegroundColor Cyan

    # Create VM folder
    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }

    # Clone template VHDX
    Copy-TemplateVHDX -TemplatePath $TemplateVHDX -DestinationPath $vhdxPath -SizeBytes $diskSizeBytes

    # Windows eval VHDs are MBR (Gen1), RHEL cloud images are GPT (Gen2/UEFI)
    $generation = if ($VMDef.OS -eq "Windows") { 1 } else { 2 }

    New-VM -Name $vmName `
           -MemoryStartupBytes $VMDef.RAM `
           -Generation $generation `
           -VHDPath $vhdxPath `
           -SwitchName $Config.SwitchName `
           -Path $vmPath | Out-Null

    # Set processor count
    Set-VMProcessor -VMName $vmName -Count $VMDef.vCPU

    # Disable dynamic memory
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false

    # Enable all integration services
    Get-VMIntegrationService -VMName $vmName | Where-Object { -not $_.Enabled } |
        Enable-VMIntegrationService -ErrorAction SilentlyContinue

    if ($generation -eq 2) {
        # Gen2: RHEL cloud images need secure boot disabled
        Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

        # Attach cloud-init ISO for Linux VMs
        if ($CloudInitISO -and (Test-Path $CloudInitISO)) {
            Add-VMDvdDrive -VMName $vmName -Path $CloudInitISO
        }

        # Set boot order: hard drive first
        $hardDrive = Get-VMHardDiskDrive -VMName $vmName
        $dvdDrives = Get-VMDvdDrive -VMName $vmName
        $bootDevices = @($hardDrive)
        foreach ($dvd in $dvdDrives) { $bootDevices += $dvd }
        Set-VMFirmware -VMName $vmName -BootOrder $bootDevices
    }
    else {
        # Gen1: Attach cloud-init ISO if needed (via IDE DVD)
        if ($CloudInitISO -and (Test-Path $CloudInitISO)) {
            Set-VMDvdDrive -VMName $vmName -Path $CloudInitISO
        }
    }

    # Disable automatic checkpoints
    Set-VM -VMName $vmName -AutomaticCheckpointsEnabled $false
    Set-VM -VMName $vmName -CheckpointType Standard

    Write-Host "[OK  ] VM '$vmName' created successfully." -ForegroundColor Green
}

function Start-LabVM {
    param(
        [Parameter(Mandatory)]
        [string]$VMName
    )

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "VM '$VMName' does not exist."
        return
    }

    if ($vm.State -eq 'Running') {
        Write-Host "[SKIP] VM '$VMName' is already running." -ForegroundColor Yellow
        return
    }

    Write-Host "[VM  ] Starting VM '$VMName'..." -ForegroundColor Cyan
    try {
        Start-VM -Name $VMName -ErrorAction Stop
        Write-Host "[OK  ] VM '$VMName' started." -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to start VM '$VMName': $_"
        Write-Host "[INFO] Check attached drives: Get-VM '$VMName' | Get-VMHardDiskDrive" -ForegroundColor Yellow
    }
}

function Wait-LabVMReady {
    <#
    .SYNOPSIS
        Waits for a VM to boot and become responsive.
        Cloud image VMs boot in 2-3 minutes (vs 25-30 with ISO install).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [string]$OS = "Windows",

        [int]$TimeoutMinutes = 15,  # Much shorter for cloud images

        [PSCredential]$Credential
    )

    Write-Host "[WAIT] Waiting for '$VMName' to become ready (timeout: ${TimeoutMinutes}m)..." -ForegroundColor Cyan

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $ready = $false
    $lastStatus = ""

    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Start-Sleep -Seconds 10
            continue
        }

        # Handle post-cloud-init reboot
        if ($vm.State -eq 'Off') {
            Write-Host "[WAIT] '$VMName' is off (cloud-init reboot). Restarting..." -ForegroundColor Yellow
            Start-VM -Name $VMName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
            continue
        }

        if ($vm.State -ne 'Running') {
            Start-Sleep -Seconds 10
            continue
        }

        $hb = $vm.Heartbeat
        $status = "Heartbeat: $hb"
        if ($status -ne $lastStatus) {
            Write-Host "[WAIT] '$VMName' -$status" -ForegroundColor Gray
            $lastStatus = $status
        }

        if ($hb -eq 'OkApplicationsHealthy' -or $hb -eq 'OkApplicationsUnknown') {
            if ($OS -eq "Windows" -and $Credential) {
                try {
                    $result = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                        return @{
                            ComputerName = $env:COMPUTERNAME
                            WinRM        = (Get-Service WinRM -ErrorAction SilentlyContinue).Status
                        }
                    } -ErrorAction Stop

                    if ($result -and $result.ComputerName) {
                        Write-Host "[WAIT] '$VMName' responded ($($result.ComputerName)). Stabilizing..." -ForegroundColor Gray
                        Start-Sleep -Seconds 20
                        $ready = $true
                        break
                    }
                }
                catch { }
            }
            else {
                # Linux: check for IPv4 + SSH
                $netAdapter = Get-VMNetworkAdapter -VMName $VMName
                $vmIP = $netAdapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

                if ($vmIP) {
                    $sshReady = Test-NetConnection -ComputerName $vmIP -Port 22 `
                        -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
                    if ($sshReady) {
                        Write-Host "[WAIT] '$VMName' SSH reachable at $vmIP. Waiting for cloud-init..." -ForegroundColor Gray
                        # Wait for cloud-init to finish
                        Start-Sleep -Seconds 30
                        $ready = $true
                        break
                    }
                    else {
                        $newStatus = "IP: $vmIP, SSH: waiting..."
                        if ($newStatus -ne $lastStatus) {
                            Write-Host "[WAIT] '$VMName' -$newStatus" -ForegroundColor Gray
                            $lastStatus = $newStatus
                        }
                    }
                }
            }
        }

        Start-Sleep -Seconds 10
    }

    if ($ready) {
        Write-Host "[OK  ] VM '$VMName' is ready." -ForegroundColor Green
    }
    else {
        Write-Warning "VM '$VMName' did not become ready within ${TimeoutMinutes} minutes."
    }

    return $ready
}

Export-ModuleMember -Function New-LabVM, Start-LabVM, Wait-LabVMReady
