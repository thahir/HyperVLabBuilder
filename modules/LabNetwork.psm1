function New-LabNetwork {
    <#
    .SYNOPSIS
        Creates the BoringLab internal vSwitch with NAT for internet access.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $switchName = $Config.SwitchName
    $natName    = $Config.NATName
    $gateway    = $Config.Gateway
    $prefix     = $Config.PrefixLength
    $subnet     = $Config.Subnet

    # --- Create Internal vSwitch ---
    $existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($existingSwitch) {
        Write-Host "[SKIP] vSwitch '$switchName' already exists." -ForegroundColor Yellow
    }
    else {
        Write-Host "[NET ] Creating Internal vSwitch '$switchName'..." -ForegroundColor Cyan
        New-VMSwitch -SwitchName $switchName -SwitchType Internal | Out-Null
        Write-Host "[OK  ] vSwitch '$switchName' created." -ForegroundColor Green
    }

    # --- Assign gateway IP to the host adapter ---
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$switchName*" }
    if (-not $adapter) {
        # Fallback: find adapter by interface description matching the switch
        $vmNic = Get-VMSwitch -Name $switchName
        $adapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Hyper-V Virtual Ethernet Adapter*" } |
            Where-Object {
                $ifIndex = $_.ifIndex
                $currentIP = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                (-not $currentIP) -or ($currentIP.IPAddress -eq $gateway)
            } | Select-Object -First 1

        if (-not $adapter) {
            # Last resort: get the adapter created most recently
            $adapter = Get-NetAdapter | Where-Object { $_.Name -like "vEthernet*" } |
                Sort-Object -Property ifIndex -Descending | Select-Object -First 1
        }
    }

    if ($adapter) {
        $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $gateway }

        if ($existingIP) {
            Write-Host "[SKIP] Gateway IP $gateway already assigned to adapter." -ForegroundColor Yellow
        }
        else {
            Write-Host "[NET ] Assigning gateway IP $gateway/$prefix to host adapter..." -ForegroundColor Cyan
            # Remove any existing IP on this adapter first
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $gateway -PrefixLength $prefix | Out-Null
            Write-Host "[OK  ] Gateway IP assigned." -ForegroundColor Green
        }
    }
    else {
        Write-Warning "Could not find network adapter for vSwitch '$switchName'. Assign IP manually."
    }

    # --- Create NAT ---
    $existingNAT = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
    if ($existingNAT) {
        Write-Host "[SKIP] NAT '$natName' already exists." -ForegroundColor Yellow
    }
    else {
        Write-Host "[NET ] Creating NAT '$natName' for subnet $subnet..." -ForegroundColor Cyan
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $subnet | Out-Null
        Write-Host "[OK  ] NAT '$natName' created." -ForegroundColor Green
    }
}

Export-ModuleMember -Function New-LabNetwork
