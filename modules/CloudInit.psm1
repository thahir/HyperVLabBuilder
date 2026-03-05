function New-CloudInitISO {
    <#
    .SYNOPSIS
        Creates a cloud-init NoCloud datasource ISO for a RHEL VM.
        Contains meta-data, user-data, and network-config.
        Returns the ISO path.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VMDef,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$RootPassword,

        [Parameter(Mandatory)]
        [string]$RHELUsername,

        [Parameter(Mandatory)]
        [string]$RHELPassword
    )

    $vmName   = $VMDef.Name
    $ip       = $VMDef.IP
    $gateway  = $Config.Gateway
    $prefix   = $Config.PrefixLength
    $domain   = $Config.DomainName
    $dns1     = ($Config.VMs | Where-Object { $_.Role -eq "DomainController" } | Select-Object -First 1).IP
    if (-not $dns1) { $dns1 = $gateway }
    $dns2     = $Config.DNSForwarders[0]
    $vmFolder = Join-Path $Config.VMPath $vmName
    $isK8s    = $VMDef.Role -like "K8s*"

    if (-not (Test-Path $vmFolder)) {
        New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
    }

    $ciDir = Join-Path $vmFolder "cloud-init"
    if (-not (Test-Path $ciDir)) {
        New-Item -ItemType Directory -Path $ciDir -Force | Out-Null
    }

    # === meta-data ===
    $metaData = @"
instance-id: $vmName
local-hostname: $vmName
"@

    # === network-config (v2 format) ===
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: false
    dhcp6: false
    addresses:
      - $ip/$prefix
    gateway4: $gateway
    nameservers:
      addresses:
        - $dns1
        - $dns2
      search:
        - $domain
"@

    # === user-data ===
    # Build hosts entries dynamically from config
    $hostsBlock = "      # BoringLab hosts"
    foreach ($vm in $Config.VMs) {
        $hostsBlock += "`n      $($vm.IP)  $($vm.Name) $($vm.Name).$domain"
    }
    # Add service aliases
    $gitlabVM = $Config.VMs | Where-Object { $_.Role -eq "GitLab" } | Select-Object -First 1
    if ($gitlabVM) { $hostsBlock += "`n      $($gitlabVM.IP)  gitlab.$($domain.ToLower())" }
    $monitorVM = $Config.VMs | Where-Object { $_.Role -eq "Monitoring" } | Select-Object -First 1
    if ($monitorVM) { $hostsBlock += "`n      $($monitorVM.IP)  grafana.$($domain.ToLower())" }

    # K8s-specific commands
    $k8sCommands = ""
    if ($isK8s) {
        $k8sCommands = @"

  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  - setenforce 0 || true
  - sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
"@
    }

    # Escape special characters in password for YAML safety
    $yamlPassword = $RootPassword -replace "'", "''"

    $userData = @"
#cloud-config
hostname: $vmName
fqdn: $vmName.$domain
manage_etc_hosts: false

users:
  - name: root
    lock_passwd: false
    plain_text_passwd: '$yamlPassword'
    ssh_authorized_keys: []
  - name: labadmin
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: '$yamlPassword'

ssh_pwauth: true
disable_root: false

write_files:
  - path: /etc/hosts
    append: true
    content: |
$hostsBlock

  - path: /etc/ssh/sshd_config.d/99-boringlab.conf
    content: |
      PasswordAuthentication yes
      PermitRootLogin yes

  - path: /etc/systemd/system/node_exporter.service
    content: |
      [Unit]
      Description=Prometheus Node Exporter
      After=network.target
      [Service]
      Type=simple
      User=root
      ExecStart=/usr/local/bin/node_exporter
      Restart=always
      [Install]
      WantedBy=multi-user.target

packages:
  - openssh-server
  - python3
  - python3-pip
  - curl
  - wget
  - vim
  - git
  - tar
  - unzip
  - net-tools
  - bind-utils
  - bash-completion
  - chrony
  - hyperv-daemons

runcmd:
  # Enable Hyper-V services
  - systemctl enable --now hypervkvpd hypervvssd hypervfcopyd 2>/dev/null || true

  # Register with Red Hat
  - subscription-manager register --username="$RHELUsername" --password="$RHELPassword" --auto-attach > /root/rhel-registration.log 2>&1 || true
  - subscription-manager repos --enable=rhel-10-for-x86_64-baseos-rpms --enable=rhel-10-for-x86_64-appstream-rpms || true

  # Install node_exporter for monitoring
  - curl -fsSLo /tmp/node_exporter.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz" || true
  - cd /tmp && tar xzf node_exporter.tar.gz 2>/dev/null && cp node_exporter-*/node_exporter /usr/local/bin/ 2>/dev/null || true
  - systemctl daemon-reload && systemctl enable --now node_exporter 2>/dev/null || true

  # Firewall
  - firewall-cmd --permanent --add-service=ssh || true
  - firewall-cmd --permanent --add-port=9100/tcp || true
  - firewall-cmd --reload || true
$k8sCommands
  # Restart SSH to pick up new config
  - systemctl restart sshd

  # Signal that cloud-init is done
  - touch /var/lib/cloud/instance/boot-finished-boringlab

power_state:
  mode: reboot
  message: "Cloud-init complete. Rebooting..."
  timeout: 30
  condition: test -f /var/lib/cloud/instance/boot-finished-boringlab
"@

    # Write files
    $metaData | Out-File -FilePath (Join-Path $ciDir "meta-data") -Encoding ASCII -Force -NoNewline
    $userData | Out-File -FilePath (Join-Path $ciDir "user-data") -Encoding ASCII -Force -NoNewline
    $networkConfig | Out-File -FilePath (Join-Path $ciDir "network-config") -Encoding ASCII -Force -NoNewline

    # Create ISO with cidata label (NoCloud datasource)
    $isoOutputPath = Join-Path $vmFolder "$vmName-cidata.iso"

    $oscdimg = Find-OscdImg
    if ($oscdimg) {
        & $oscdimg -l"cidata" -j1 -o $ciDir $isoOutputPath 2>&1 | Out-Null
    }
    else {
        New-SimpleISO -SourcePath $ciDir -OutputPath $isoOutputPath -VolumeName "cidata"
    }

    # Clean up temp cloud-init directory
    Remove-Item $ciDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[OK  ] Cloud-init ISO created: $isoOutputPath" -ForegroundColor Green
    return $isoOutputPath
}

function Find-OscdImg {
    $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $paths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function New-SimpleISO {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$VolumeName = "cidata"
    )

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3  # ISO9660 + Joliet
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($SourcePath, $false)

    $result = $fsi.CreateResultImage()
    $iStream = $result.ImageStream

    # COM IStream cannot be read directly via .Read() in PowerShell.
    # Use inline C# to properly read COM IStream to file.
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class IStreamToFile {
    public static void Write(object comStream, string outputPath) {
        IStream stream = (IStream)comStream;
        using (FileStream fs = new FileStream(outputPath, FileMode.Create, FileAccess.Write)) {
            byte[] buffer = new byte[65536];
            while (true) {
                IntPtr bytesReadPtr = Marshal.AllocHGlobal(sizeof(int));
                try {
                    stream.Read(buffer, buffer.Length, bytesReadPtr);
                    int bytesRead = Marshal.ReadInt32(bytesReadPtr);
                    if (bytesRead <= 0) break;
                    fs.Write(buffer, 0, bytesRead);
                } finally {
                    Marshal.FreeHGlobal(bytesReadPtr);
                }
            }
        }
    }
}
"@ -ErrorAction SilentlyContinue

    [IStreamToFile]::Write($iStream, $OutputPath)

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($iStream) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) | Out-Null
}

Export-ModuleMember -Function New-CloudInitISO
