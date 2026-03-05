param(
    [string]$DomainName = "BoringLab.local",
    [PSCredential]$Credential,
    [string[]]$Features = @(),
    [string]$DCIP = "10.10.10.10"
)

# Set DNS to point to DC
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($DCIP, "8.8.8.8")

# Wait for DC to be reachable
Write-Host "Waiting for DC to be reachable..."
$retries = 0
while ($retries -lt 30) {
    try {
        Resolve-DnsName $DomainName -Server $DCIP -ErrorAction Stop | Out-Null
        break
    }
    catch {
        $retries++
        Start-Sleep -Seconds 10
    }
}

# Join domain
Write-Host "Joining domain '$DomainName'..."
Add-Computer -DomainName $DomainName -Credential $Credential -Restart -Force

# Install requested features (will run after reboot via post-install re-run)
if ($Features -and $Features.Count -gt 0) {
    Write-Host "Installing features: $($Features -join ', ')..."
    foreach ($feature in $Features) {
        Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
    }
}
