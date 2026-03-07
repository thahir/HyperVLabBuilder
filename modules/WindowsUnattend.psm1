function Inject-WindowsUnattend {
    <#
    .SYNOPSIS
        Mounts a Windows VHDX and injects an autounattend.xml into
        \Windows\Panther\Unattend.xml so it's processed on first boot.
        Also enables WinRM via a SetupComplete.cmd script.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VMDef,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [securestring]$AdminPassword,

        [Parameter(Mandatory)]
        [string]$VHDXPath
    )

    $vmName  = $VMDef.Name
    $ip      = $VMDef.IP
    $gateway = $Config.Gateway
    $prefix  = $Config.PrefixLength
    $dns     = $Config.Gateway

    # Convert secure string for XML
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $xmlPass = [System.Security.SecurityElement]::Escape($plainPass)

    Write-Host "[UNATTEND] Injecting unattend.xml into VHDX for '$vmName'..." -ForegroundColor Cyan

    # Mount the VHDX
    $mountResult = Mount-VHD -Path $VHDXPath -Passthru
    $disk = $mountResult | Get-Disk
    $partition = $disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB } | Select-Object -First 1

    if (-not $partition) {
        # Fallback: get the largest partition
        $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
    }

    # Assign a drive letter if none
    $driveLetter = $partition.DriveLetter
    if (-not $driveLetter) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
        $partition = $partition | Get-Partition  # Refresh
        $driveLetter = $partition.DriveLetter
    }

    if (-not $driveLetter) {
        Dismount-VHD -Path $VHDXPath
        throw "Could not assign drive letter to VHDX partition for '$vmName'."
    }

    $drive = "${driveLetter}:"

    try {
        # Create Panther directory for unattend.xml
        $pantherPath = Join-Path $drive "Windows\Panther"
        if (-not (Test-Path $pantherPath)) {
            New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
        }

        # Generate unattend.xml
        $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$vmName</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Interfaces>
        <Interface wcm:action="add">
          <Ipv4Settings>
            <DhcpEnabled>false</DhcpEnabled>
          </Ipv4Settings>
          <Identifier>Ethernet</Identifier>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">$ip/$prefix</IpAddress>
          </UnicastIpAddresses>
          <Routes>
            <Route wcm:action="add">
              <Identifier>0</Identifier>
              <NextHopAddress>$gateway</NextHopAddress>
              <Prefix>0.0.0.0/0</Prefix>
              <Metric>10</Metric>
            </Route>
          </Routes>
        </Interface>
      </Interfaces>
    </component>

    <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <DNSServerSearchOrder>
            <IpAddress wcm:action="add" wcm:keyValue="1">$dns</IpAddress>
            <IpAddress wcm:action="add" wcm:keyValue="2">8.8.8.8</IpAddress>
          </DNSServerSearchOrder>
        </Interface>
      </Interfaces>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>

      <UserAccounts>
        <AdministratorPassword>
          <Value>$xmlPass</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>$xmlPass</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>3</LogonCount>
      </AutoLogon>
    </component>
  </settings>

</unattend>
"@

        $unattendXml | Out-File -FilePath (Join-Path $pantherPath "Unattend.xml") -Encoding UTF8 -Force

        # Create SetupComplete.cmd - runs after OOBE to enable WinRM and disable firewall
        $setupCompletePath = Join-Path $drive "Windows\Setup\Scripts"
        if (-not (Test-Path $setupCompletePath)) {
            New-Item -ItemType Directory -Path $setupCompletePath -Force | Out-Null
        }

        $setupCompleteCmd = @"
@echo off
REM BoringLab: Enable PowerShell Remoting and WinRM
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force; Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force"
winrm set winrm/config/service @{AllowUnencrypted="true"}
winrm set winrm/config/service/auth @{Basic="true"}
netsh advfirewall set allprofiles state off
REM Delete this script after first run
del "%~f0"
"@
        $setupCompleteCmd | Out-File -FilePath (Join-Path $setupCompletePath "SetupComplete.cmd") -Encoding ASCII -Force

        Write-Host "[OK  ] Unattend.xml + SetupComplete.cmd injected into '$vmName' VHDX." -ForegroundColor Green
    }
    finally {
        # Always dismount
        Dismount-VHD -Path $VHDXPath -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Inject-WindowsUnattend
