param(
    [string]$DomainName = "BoringLab.local",
    [string]$DomainNetBIOS = "BORINGLAB",
    [string]$SafeModePass,
    [string[]]$DNSForwarders = @("8.8.8.8", "1.1.1.1")
)

# Install AD DS role
Write-Host "Installing AD DS role..."
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null

# Install DNS
Write-Host "Installing DNS role..."
Install-WindowsFeature DNS -IncludeManagementTools | Out-Null

# Promote to Domain Controller
Write-Host "Promoting to Domain Controller for '$DomainName'..."
$secureSafeModePass = ConvertTo-SecureString $SafeModePass -AsPlainText -Force

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $DomainNetBIOS `
    -SafeModeAdministratorPassword $secureSafeModePass `
    -InstallDns:$true `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$false `
    -Force:$true `
    -Confirm:$false

# Note: The server will reboot automatically after promotion.
# DNS forwarders and DHCP are configured after reboot by PostInstall.psm1.
