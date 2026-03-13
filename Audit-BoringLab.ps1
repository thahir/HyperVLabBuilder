#Requires -RunAsAdministrator
#Requires -Version 7.0

<#
.SYNOPSIS
    BoringLab Audit - Validates every VM configuration in the lab.

.DESCRIPTION
    Runs comprehensive checks against all 14 VMs to verify:
    - Hyper-V VM state, resources, and networking
    - Windows: AD, DNS, DHCP, domain join, features
    - Linux: services, packages, K8s, GitLab, Harbor, DBs, Vault, Ansible
    Outputs a colored PASS/FAIL report with a final summary.

.PARAMETER SkipLinux
    Skip all Linux VM checks (useful if SSH is not available).

.PARAMETER SkipWindows
    Skip all Windows VM checks.
#>

param(
    [switch]$SkipLinux,
    [switch]$SkipWindows
)

$ErrorActionPreference = "Continue"

# ============================================================
# Load Config
# ============================================================
$modulePath = Join-Path $PSScriptRoot "modules"

# Ensure powershell-yaml is available
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host "ERROR: powershell-yaml module is required." -ForegroundColor Red
    Write-Host "  Install: Install-Module -Name powershell-yaml -Scope CurrentUser -Force" -ForegroundColor Cyan
    exit 1
}

Import-Module (Join-Path $modulePath "ConfigLoader.psm1") -Force

$configPath = Join-Path $PSScriptRoot "config.yaml"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.yaml not found at $configPath" -ForegroundColor Red
    exit 1
}
$Config = Import-LabConfig -Path $configPath

# ============================================================
# Collect Credentials
# ============================================================
Write-Host ""
Write-Host "=== BoringLab Audit ===" -ForegroundColor Cyan
Write-Host "This script validates that all VMs are configured correctly." -ForegroundColor Gray
Write-Host ""

if (-not $SkipWindows) {
    $winPassword = Read-Host -Prompt "Windows Administrator password" -AsSecureString
    $winCredential = New-Object PSCredential("Administrator", $winPassword)
    $domainUser = "$($Config.DomainNetBIOS)\$($Config.DomainAdminUser)"
    $domainCredential = New-Object PSCredential($domainUser, $winPassword)
}

if (-not $SkipLinux) {
    $sshKeyPath = Join-Path $Config.VMPath ".ssh\boringlab_ed25519"
    if (-not (Test-Path $sshKeyPath)) {
        Write-Host "ERROR: SSH key not found at $sshKeyPath" -ForegroundColor Red
        Write-Host "Run Build-BoringLab.ps1 first to generate the key pair." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Using SSH key: $sshKeyPath" -ForegroundColor Green
}

# ============================================================
# Tracking
# ============================================================
$script:totalChecks = 0
$script:passedChecks = 0
$script:failedChecks = 0
$script:skippedChecks = 0
$script:results = @()

function Test-Check {
    param(
        [string]$VM,
        [string]$Category,
        [string]$Check,
        [bool]$Passed,
        [string]$Detail = ""
    )
    $script:totalChecks++
    $status = if ($Passed) { $script:passedChecks++; "PASS" } else { $script:failedChecks++; "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    $detailStr = if ($Detail) { " - $Detail" } else { "" }
    Write-Host "  [$status] $Check$detailStr" -ForegroundColor $color

    $script:results += [PSCustomObject]@{
        VM       = $VM
        Category = $Category
        Check    = $Check
        Status   = $status
        Detail   = $Detail
    }
}

function Skip-Check {
    param([string]$VM, [string]$Check, [string]$Reason)
    $script:totalChecks++
    $script:skippedChecks++
    Write-Host "  [SKIP] $Check - $Reason" -ForegroundColor Yellow
    $script:results += [PSCustomObject]@{ VM = $VM; Category = "Skip"; Check = $Check; Status = "SKIP"; Detail = $Reason }
}

function Invoke-SSHCheck {
    param(
        [string]$IP,
        [string]$Command,
        [int]$Timeout = 15
    )
    try {
        $output = & ssh -i $sshKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=$Timeout -o BatchMode=yes "root@$IP" $Command 2>$null
        # Always return a single string — multi-line output causes -match to return
        # arrays instead of booleans, crashing Test-Check's [bool] -Passed parameter.
        if ($output -is [array]) { return ($output -join "`n") }
        return $output
    }
    catch { return $null }
}

# ============================================================
# Phase 1: Hyper-V Level Checks (all VMs)
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Phase 1: Hyper-V Infrastructure Checks" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Network switch
Write-Host ""
Write-Host "--- Virtual Switch ---" -ForegroundColor Yellow
$switch = Get-VMSwitch -Name $Config.SwitchName -ErrorAction SilentlyContinue
Test-Check -VM "HOST" -Category "Network" -Check "Virtual switch '$($Config.SwitchName)' exists" -Passed ($null -ne $switch)

$nat = Get-NetNat -Name $Config.NATName -ErrorAction SilentlyContinue
Test-Check -VM "HOST" -Category "Network" -Check "NAT '$($Config.NATName)' exists" -Passed ($null -ne $nat)
if ($nat) {
    Test-Check -VM "HOST" -Category "Network" -Check "NAT subnet is $($Config.Subnet)" -Passed ($nat.InternalIPInterfaceAddressPrefix -eq $Config.Subnet)
}

# Per-VM Hyper-V checks
foreach ($vmDef in $Config.VMs) {
    $vmName = $vmDef.Name
    Write-Host ""
    Write-Host "--- $vmName (Hyper-V) ---" -ForegroundColor Yellow

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    Test-Check -VM $vmName -Category "HyperV" -Check "VM exists" -Passed ($null -ne $vm)

    if (-not $vm) {
        Skip-Check -VM $vmName -Check "Remaining Hyper-V checks" -Reason "VM not found"
        continue
    }

    Test-Check -VM $vmName -Category "HyperV" -Check "VM is running" -Passed ($vm.State -eq 'Running') -Detail "State: $($vm.State)"

    # CPU
    Test-Check -VM $vmName -Category "HyperV" -Check "vCPU count = $($vmDef.vCPU)" -Passed ($vm.ProcessorCount -eq $vmDef.vCPU) -Detail "Actual: $($vm.ProcessorCount)"

    # RAM (check startup memory for static, or assigned for dynamic)
    $expectedRAM = [int64]$vmDef.RAM
    $actualRAM = $vm.MemoryStartup
    Test-Check -VM $vmName -Category "HyperV" -Check "RAM = $([math]::Round($expectedRAM/1GB))GB" -Passed ($actualRAM -eq $expectedRAM) -Detail "Actual: $([math]::Round($actualRAM/1GB,1))GB"

    # Generation
    $expectedGen = if ($vmDef.OS -eq "Windows") { 1 } else { 2 }
    Test-Check -VM $vmName -Category "HyperV" -Check "Generation = $expectedGen" -Passed ($vm.Generation -eq $expectedGen) -Detail "Actual: Gen$($vm.Generation)"

    # Network adapter
    $nic = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
    $connectedToSwitch = $nic | Where-Object { $_.SwitchName -eq $Config.SwitchName }
    Test-Check -VM $vmName -Category "HyperV" -Check "Connected to '$($Config.SwitchName)'" -Passed ($null -ne $connectedToSwitch)

    # Disk size
    $vhd = Get-VHD -VMId $vm.VMId -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vhd) {
        $expectedDiskGB = $vmDef.DiskGB
        $actualDiskGB = [math]::Round($vhd.Size / 1GB)
        Test-Check -VM $vmName -Category "HyperV" -Check "Disk >= ${expectedDiskGB}GB" -Passed ($actualDiskGB -ge $expectedDiskGB) -Detail "Actual: ${actualDiskGB}GB"
    }

    # Ping test
    $ping = Test-Connection -TargetName $vmDef.IP -Count 1 -TimeoutSeconds 3 -ErrorAction SilentlyContinue
    Test-Check -VM $vmName -Category "Network" -Check "IP $($vmDef.IP) reachable" -Passed ($null -ne $ping -and $ping.Status -eq 'Success')
}

# ============================================================
# Phase 2: Windows VM Checks
# ============================================================
if (-not $SkipWindows) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Phase 2: Windows VM Configuration Checks" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    # --- DC01 ---
    $dc = $Config.VMs | Where-Object { $_.Role -eq "DomainController" }
    if ($dc) {
        Write-Host ""
        Write-Host "--- DC01 (Domain Controller) ---" -ForegroundColor Yellow

        try {
            $adCheck = Invoke-Command -VMName $dc.Name -Credential $domainCredential -ScriptBlock {
                $result = @{}

                # AD DS installed
                $adds = Get-WindowsFeature AD-Domain-Services -ErrorAction SilentlyContinue
                $result.ADDS_Installed = ($adds -and $adds.Installed)

                # DNS installed
                $dns = Get-WindowsFeature DNS -ErrorAction SilentlyContinue
                $result.DNS_Installed = ($dns -and $dns.Installed)

                # AD Domain exists
                try {
                    $domain = Get-ADDomain -ErrorAction Stop
                    $result.Domain_Exists = $true
                    $result.Domain_Name = $domain.DNSRoot
                    $result.Domain_NetBIOS = $domain.NetBIOSName
                } catch {
                    $result.Domain_Exists = $false
                }

                # DHCP installed
                $dhcp = Get-WindowsFeature DHCP -ErrorAction SilentlyContinue
                $result.DHCP_Installed = ($dhcp -and $dhcp.Installed)

                # DHCP scope
                try {
                    $scope = Get-DhcpServerv4Scope -ErrorAction Stop | Where-Object { $_.ScopeId -eq "10.10.10.0" }
                    $result.DHCP_Scope = ($null -ne $scope)
                    if ($scope) {
                        $result.DHCP_StartRange = $scope.StartRange.ToString()
                        $result.DHCP_EndRange = $scope.EndRange.ToString()
                    }
                } catch {
                    $result.DHCP_Scope = $false
                }

                # DNS Forwarders
                try {
                    $fwd = Get-DnsServerForwarder -ErrorAction Stop
                    $result.DNS_Forwarders = ($fwd.IPAddress | ForEach-Object { $_.ToString() }) -join ","
                } catch {
                    $result.DNS_Forwarders = ""
                }

                return $result
            } -ErrorAction Stop

            Test-Check -VM "DC01" -Category "AD" -Check "AD DS role installed" -Passed $adCheck.ADDS_Installed
            Test-Check -VM "DC01" -Category "AD" -Check "DNS role installed" -Passed $adCheck.DNS_Installed
            Test-Check -VM "DC01" -Category "AD" -Check "AD domain exists" -Passed $adCheck.Domain_Exists -Detail "Domain: $($adCheck.Domain_Name)"
            if ($adCheck.Domain_Exists) {
                Test-Check -VM "DC01" -Category "AD" -Check "Domain name = $($Config.DomainName)" -Passed ($adCheck.Domain_Name -eq $Config.DomainName)
                Test-Check -VM "DC01" -Category "AD" -Check "NetBIOS name = $($Config.DomainNetBIOS)" -Passed ($adCheck.Domain_NetBIOS -eq $Config.DomainNetBIOS)
            }
            Test-Check -VM "DC01" -Category "DHCP" -Check "DHCP role installed" -Passed $adCheck.DHCP_Installed
            Test-Check -VM "DC01" -Category "DHCP" -Check "DHCP scope 10.10.10.0 exists" -Passed $adCheck.DHCP_Scope
            if ($adCheck.DHCP_Scope) {
                Test-Check -VM "DC01" -Category "DHCP" -Check "DHCP range 10.10.10.100-200" -Passed ($adCheck.DHCP_StartRange -eq "10.10.10.100" -and $adCheck.DHCP_EndRange -eq "10.10.10.200")
            }
            $hasForwarders = $adCheck.DNS_Forwarders -match "8.8.8.8"
            Test-Check -VM "DC01" -Category "DNS" -Check "DNS forwarders configured" -Passed $hasForwarders -Detail $adCheck.DNS_Forwarders
        }
        catch {
            Skip-Check -VM "DC01" -Check "All AD/DNS/DHCP checks" -Reason "Cannot connect: $_"
        }
    }

    # --- Member Servers (WS01, WS02) ---
    $memberServers = $Config.VMs | Where-Object { $_.Role -eq "MemberServer" }
    foreach ($ms in $memberServers) {
        Write-Host ""
        Write-Host "--- $($ms.Name) (Member Server) ---" -ForegroundColor Yellow

        try {
            # Try domain credential first, fall back to local
            $cred = $domainCredential
            $msCheck = Invoke-Command -VMName $ms.Name -Credential $cred -ScriptBlock {
                param($expectedFeatures, $dcIP)
                $result = @{}

                # Domain joined
                $cs = Get-CimInstance Win32_ComputerSystem
                $result.DomainJoined = ($cs.PartOfDomain -eq $true)
                $result.Domain = $cs.Domain

                # DNS pointing to DC
                $dns = (Get-DnsClientServerAddress -InterfaceAlias (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name -AddressFamily IPv4).ServerAddresses
                $result.DNS_PointsToDC = ($dns -contains $dcIP)
                $result.DNS_Servers = $dns -join ","

                # Features
                $result.Features = @{}
                foreach ($f in $expectedFeatures) {
                    $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
                    $result.Features[$f] = ($feat -and $feat.Installed)
                }

                return $result
            } -ArgumentList $ms.Features, $dc.IP -ErrorAction Stop

            Test-Check -VM $ms.Name -Category "Domain" -Check "Joined to domain" -Passed $msCheck.DomainJoined -Detail "Domain: $($msCheck.Domain)"
            Test-Check -VM $ms.Name -Category "DNS" -Check "DNS points to DC ($($dc.IP))" -Passed $msCheck.DNS_PointsToDC -Detail "DNS: $($msCheck.DNS_Servers)"

            if ($ms.Features) {
                foreach ($f in $ms.Features) {
                    $installed = $msCheck.Features[$f]
                    Test-Check -VM $ms.Name -Category "Features" -Check "Feature '$f' installed" -Passed $installed
                }
            }
        }
        catch {
            Skip-Check -VM $ms.Name -Check "All member server checks" -Reason "Cannot connect: $_"
        }
    }
}

# ============================================================
# Phase 3: Linux VM Checks
# ============================================================
if (-not $SkipLinux) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Phase 3: Linux VM Configuration Checks" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    # Helper: test SSH reachability first
    function Test-SSHReachable {
        param([string]$IP)
        $out = & ssh -i $sshKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes "root@$IP" "echo OK" 2>$null
        return ($out -match "OK")
    }

    # --- Common Linux checks ---
    $linuxVMs = $Config.VMs | Where-Object { $_.OS -eq "RHEL" }

    foreach ($vmDef in $linuxVMs) {
        $vmName = $vmDef.Name
        $ip = $vmDef.IP
        $role = $vmDef.Role

        Write-Host ""
        Write-Host "--- $vmName ($role) ---" -ForegroundColor Yellow

        # SSH reachability
        $sshOK = Test-SSHReachable -IP $ip
        Test-Check -VM $vmName -Category "SSH" -Check "SSH reachable" -Passed $sshOK

        if (-not $sshOK) {
            Skip-Check -VM $vmName -Check "All remaining checks" -Reason "SSH not reachable"
            continue
        }

        # Cloud-init completed
        $ciDone = Invoke-SSHCheck -IP $ip -Command "test -f /var/lib/cloud/instance/boot-finished && echo YES || echo NO"
        Test-Check -VM $vmName -Category "CloudInit" -Check "Cloud-init completed" -Passed ($ciDone -match "YES")

        # Hostname
        $hostname = Invoke-SSHCheck -IP $ip -Command "hostname -s"
        Test-Check -VM $vmName -Category "OS" -Check "Hostname = $vmName" -Passed ($hostname -and $hostname.Trim().ToUpper() -eq $vmName.ToUpper()) -Detail "Actual: $($hostname.Trim())"

        # Static IP configured (not DHCP)
        $ipCheck = Invoke-SSHCheck -IP $ip -Command "ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1"
        if (-not $ipCheck) {
            # Try alternate interface names
            $ipCheck = Invoke-SSHCheck -IP $ip -Command "hostname -I | awk '{print `$1}'"
        }
        Test-Check -VM $vmName -Category "Network" -Check "IP address = $ip" -Passed ($ipCheck -and $ipCheck.Trim() -eq $ip) -Detail "Actual: $($ipCheck.Trim())"

        # RHEL subscription (optional check)
        $subStatus = Invoke-SSHCheck -IP $ip -Command "subscription-manager status 2>/dev/null | grep -i 'overall status' | awk -F: '{print `$2}' | xargs"
        if ($subStatus) {
            Test-Check -VM $vmName -Category "RHEL" -Check "RHEL subscription active" -Passed ([bool]($subStatus -match "Current|Valid|Registered")) -Detail "Status: $($subStatus.Trim())"
        }

        # --- Role-specific checks ---
        switch ($role) {
            "Ansible" {
                $ansibleInstalled = Invoke-SSHCheck -IP $ip -Command "command -v ansible >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "ansible-core installed" -Passed ($ansibleInstalled -match "YES")

                $pipInstalled = Invoke-SSHCheck -IP $ip -Command "command -v pip3 >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "pip3 installed" -Passed ($pipInstalled -match "YES")

                $pywinrm = Invoke-SSHCheck -IP $ip -Command "pip3 show pywinrm >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "pywinrm installed" -Passed ($pywinrm -match "YES")

                $inventory = Invoke-SSHCheck -IP $ip -Command "test -f /etc/ansible/inventory/boringlab.ini && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "Inventory file exists" -Passed ($inventory -match "YES")

                $cfg = Invoke-SSHCheck -IP $ip -Command "test -f /etc/ansible/ansible.cfg && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "ansible.cfg exists" -Passed ($cfg -match "YES")

                $sshKey = Invoke-SSHCheck -IP $ip -Command "test -f /root/.ssh/id_ed25519 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Ansible" -Check "SSH key generated" -Passed ($sshKey -match "YES")

                # Check collections
                $collections = @("ansible.windows", "community.general", "community.postgresql", "kubernetes.core", "ansible.posix")
                foreach ($col in $collections) {
                    $colCheck = Invoke-SSHCheck -IP $ip -Command "ansible-galaxy collection list 2>/dev/null | grep -q '$col' && echo YES || echo NO"
                    Test-Check -VM $vmName -Category "Ansible" -Check "Collection '$col'" -Passed ($colCheck -match "YES")
                }
            }

            "K8sMaster" {
                $containerd = Invoke-SSHCheck -IP $ip -Command "systemctl is-active containerd 2>/dev/null"
                Test-Check -VM $vmName -Category "K8s" -Check "containerd running" -Passed ($containerd -match "active")

                $kubelet = Invoke-SSHCheck -IP $ip -Command "systemctl is-active kubelet 2>/dev/null"
                Test-Check -VM $vmName -Category "K8s" -Check "kubelet running" -Passed ($kubelet -match "active")

                $adminConf = Invoke-SSHCheck -IP $ip -Command "test -f /etc/kubernetes/admin.conf && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "admin.conf exists" -Passed ($adminConf -match "YES")

                $nodes = Invoke-SSHCheck -IP $ip -Command "kubectl get nodes --no-headers 2>/dev/null | head -5"
                Test-Check -VM $vmName -Category "K8s" -Check "kubectl get nodes works" -Passed ($null -ne $nodes -and $nodes.Length -gt 0) -Detail ($nodes -join " | ")

                $masterReady = Invoke-SSHCheck -IP $ip -Command "kubectl get nodes --no-headers 2>/dev/null | grep K8S-MASTER | grep -q Ready && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Master node is Ready" -Passed ($masterReady -match "YES")

                $calico = Invoke-SSHCheck -IP $ip -Command "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep calico-node | grep -q Running && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Calico CNI running" -Passed ($calico -match "YES")

                $helm = Invoke-SSHCheck -IP $ip -Command "command -v helm >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Helm installed" -Passed ($helm -match "YES")

                $joinCmd = Invoke-SSHCheck -IP $ip -Command "test -f /root/k8s-join-command.txt && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Join command saved" -Passed ($joinCmd -match "YES")

                $swap = Invoke-SSHCheck -IP $ip -Command "swapon --show 2>/dev/null | wc -l"
                Test-Check -VM $vmName -Category "K8s" -Check "Swap disabled" -Passed ($swap -and $swap.Trim() -eq "0")

                $brNetfilter = Invoke-SSHCheck -IP $ip -Command "lsmod | grep -q br_netfilter && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "br_netfilter module loaded" -Passed ($brNetfilter -match "YES")

                $overlay = Invoke-SSHCheck -IP $ip -Command "lsmod | grep -q overlay && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "overlay module loaded" -Passed ($overlay -match "YES")

                $fwAPI = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 6443 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Firewall port 6443 open" -Passed ($fwAPI -match "YES")
            }

            "K8sWorker" {
                $containerd = Invoke-SSHCheck -IP $ip -Command "systemctl is-active containerd 2>/dev/null"
                Test-Check -VM $vmName -Category "K8s" -Check "containerd running" -Passed ($containerd -match "active")

                $kubelet = Invoke-SSHCheck -IP $ip -Command "systemctl is-active kubelet 2>/dev/null"
                Test-Check -VM $vmName -Category "K8s" -Check "kubelet running" -Passed ($kubelet -match "active")

                $kubeletConf = Invoke-SSHCheck -IP $ip -Command "test -f /etc/kubernetes/kubelet.conf && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "kubelet.conf exists (joined cluster)" -Passed ($kubeletConf -match "YES")

                $swap = Invoke-SSHCheck -IP $ip -Command "swapon --show 2>/dev/null | wc -l"
                Test-Check -VM $vmName -Category "K8s" -Check "Swap disabled" -Passed ($swap -and $swap.Trim() -eq "0")

                # Check if this worker shows Ready on the master
                $masterIP = ($Config.VMs | Where-Object { $_.Role -eq "K8sMaster" }).IP
                $workerReady = Invoke-SSHCheck -IP $masterIP -Command "kubectl get nodes --no-headers 2>/dev/null | grep $vmName | grep -q Ready && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Node shows Ready on master" -Passed ($workerReady -match "YES")

                $fwKubelet = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 10250 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "K8s" -Check "Firewall port 10250 open" -Passed ($fwKubelet -match "YES")
            }

            "GitLab" {
                $gitlabInstalled = Invoke-SSHCheck -IP $ip -Command "command -v gitlab-ctl >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "GitLab" -Check "gitlab-ce installed" -Passed ($gitlabInstalled -match "YES")

                $gitlabRunning = Invoke-SSHCheck -IP $ip -Command "gitlab-ctl status 2>/dev/null | grep -q 'run:' && echo YES || echo NO"
                Test-Check -VM $vmName -Category "GitLab" -Check "GitLab services running" -Passed ($gitlabRunning -match "YES")

                $gitlabHTTP = Invoke-SSHCheck -IP $ip -Command "curl -s -o /dev/null -w '%{http_code}' http://localhost/-/readiness 2>/dev/null || echo 000"
                $httpOK = ($gitlabHTTP -match "200|503")
                Test-Check -VM $vmName -Category "GitLab" -Check "GitLab web responding" -Passed $httpOK -Detail "HTTP: $($gitlabHTTP.Trim())"

                $rootPass = Invoke-SSHCheck -IP $ip -Command "test -f /root/gitlab-root-password.txt && echo YES || echo NO"
                Test-Check -VM $vmName -Category "GitLab" -Check "Root password file saved" -Passed ($rootPass -match "YES")

                $fwHTTP = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-services 2>/dev/null | grep -q http && echo YES || echo NO"
                Test-Check -VM $vmName -Category "GitLab" -Check "Firewall HTTP open" -Passed ($fwHTTP -match "YES")
            }

            "Docker" {
                $dockerRunning = Invoke-SSHCheck -IP $ip -Command "systemctl is-active docker 2>/dev/null"
                Test-Check -VM $vmName -Category "Docker" -Check "Docker running" -Passed ($dockerRunning -match "active")

                $harborRunning = Invoke-SSHCheck -IP $ip -Command "docker compose -f /opt/harbor/docker-compose.yml ps --status running 2>/dev/null | grep -c harbor"
                $harborCount = if ($harborRunning) { [int]($harborRunning.Trim()) } else { 0 }
                Test-Check -VM $vmName -Category "Harbor" -Check "Harbor containers running" -Passed ($harborCount -gt 0) -Detail "$harborCount containers"

                $harborHTTP = Invoke-SSHCheck -IP $ip -Command "curl -s -o /dev/null -w '%{http_code}' http://localhost 2>/dev/null || echo 000"
                Test-Check -VM $vmName -Category "Harbor" -Check "Harbor web responding" -Passed ($harborHTTP -match "200|302") -Detail "HTTP: $($harborHTTP.Trim())"

                $harborYml = Invoke-SSHCheck -IP $ip -Command "test -f /opt/harbor/harbor.yml && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Harbor" -Check "harbor.yml exists" -Passed ($harborYml -match "YES")

                $fwHTTP = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-services 2>/dev/null | grep -q http && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Docker" -Check "Firewall HTTP open" -Passed ($fwHTTP -match "YES")

                $fw5000 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 5000 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Docker" -Check "Firewall port 5000 open" -Passed ($fw5000 -match "YES")
            }

            "Monitoring" {
                $dockerRunning = Invoke-SSHCheck -IP $ip -Command "systemctl is-active docker 2>/dev/null"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Docker running" -Passed ($dockerRunning -match "active")

                $prometheus = Invoke-SSHCheck -IP $ip -Command "docker ps --filter name=prometheus --filter status=running --format '{{.Names}}' 2>/dev/null"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Prometheus container running" -Passed ($prometheus -match "prometheus")

                $grafana = Invoke-SSHCheck -IP $ip -Command "docker ps --filter name=grafana --filter status=running --format '{{.Names}}' 2>/dev/null"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Grafana container running" -Passed ($grafana -match "grafana")

                $alertmanager = Invoke-SSHCheck -IP $ip -Command "docker ps --filter name=alertmanager --filter status=running --format '{{.Names}}' 2>/dev/null"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Alertmanager container running" -Passed ($alertmanager -match "alertmanager")

                $nodeExporter = Invoke-SSHCheck -IP $ip -Command "docker ps --filter name=node-exporter --filter status=running --format '{{.Names}}' 2>/dev/null"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Node-exporter container running" -Passed ($nodeExporter -match "node-exporter")

                $grafanaHTTP = Invoke-SSHCheck -IP $ip -Command "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health 2>/dev/null || echo 000"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Grafana API responding" -Passed ($grafanaHTTP -match "200") -Detail "HTTP: $($grafanaHTTP.Trim())"

                $promHTTP = Invoke-SSHCheck -IP $ip -Command "curl -s -o /dev/null -w '%{http_code}' http://localhost:9090/-/healthy 2>/dev/null || echo 000"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Prometheus API responding" -Passed ($promHTTP -match "200") -Detail "HTTP: $($promHTTP.Trim())"

                $promYml = Invoke-SSHCheck -IP $ip -Command "test -f /opt/monitoring/prometheus/prometheus.yml && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Monitoring" -Check "prometheus.yml exists" -Passed ($promYml -match "YES")

                $fw3000 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 3000 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Firewall port 3000 open" -Passed ($fw3000 -match "YES")

                $fw9090 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 9090 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Monitoring" -Check "Firewall port 9090 open" -Passed ($fw9090 -match "YES")
            }

            "Database" {
                # PostgreSQL
                $pgRunning = Invoke-SSHCheck -IP $ip -Command "systemctl is-active postgresql-17 2>/dev/null"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "PostgreSQL 17 running" -Passed ($pgRunning -match "active")

                $pgVersion = Invoke-SSHCheck -IP $ip -Command "test -f /var/lib/pgsql/17/data/PG_VERSION && cat /var/lib/pgsql/17/data/PG_VERSION"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "PG_VERSION file exists" -Passed ($null -ne $pgVersion -and $pgVersion.Trim().Length -gt 0) -Detail "Version: $($pgVersion.Trim())"

                $pgUser = Invoke-SSHCheck -IP $ip -Command "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_roles WHERE rolname='labadmin'`" 2>/dev/null"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "User 'labadmin' exists" -Passed ($pgUser -match "1")

                $pgDB = Invoke-SSHCheck -IP $ip -Command "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_database WHERE datname='boringlab'`" 2>/dev/null"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "Database 'boringlab' exists" -Passed ($pgDB -match "1")

                $pgDevops = Invoke-SSHCheck -IP $ip -Command "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_database WHERE datname='devops_app'`" 2>/dev/null"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "Database 'devops_app' exists" -Passed ($pgDevops -match "1")

                $pgRemote = Invoke-SSHCheck -IP $ip -Command "grep -q '10.10.10.0/24' /var/lib/pgsql/17/data/pg_hba.conf && echo YES || echo NO"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "Remote access configured (pg_hba)" -Passed ($pgRemote -match "YES")

                $pgListen = Invoke-SSHCheck -IP $ip -Command "grep -q `"listen_addresses = '\*'`" /var/lib/pgsql/17/data/postgresql.conf && echo YES || echo NO"
                Test-Check -VM $vmName -Category "PostgreSQL" -Check "Listen on all interfaces" -Passed ($pgListen -match "YES")

                # MySQL/MariaDB
                $mysqlRunning = Invoke-SSHCheck -IP $ip -Command "systemctl is-active mysqld 2>/dev/null || systemctl is-active mariadb 2>/dev/null"
                Test-Check -VM $vmName -Category "MySQL" -Check "MySQL/MariaDB running" -Passed ($mysqlRunning -match "active")

                $fw5432 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 5432 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Database" -Check "Firewall port 5432 (PG) open" -Passed ($fw5432 -match "YES")

                $fw3306 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 3306 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Database" -Check "Firewall port 3306 (MySQL) open" -Passed ($fw3306 -match "YES")
            }

            "Vault" {
                $vaultRunning = Invoke-SSHCheck -IP $ip -Command "systemctl is-active vault 2>/dev/null"
                Test-Check -VM $vmName -Category "Vault" -Check "Vault service running" -Passed ($vaultRunning -match "active")

                $vaultInit = Invoke-SSHCheck -IP $ip -Command "VAULT_ADDR=http://127.0.0.1:8200 vault status 2>/dev/null | grep -oP 'Initialized\s+\K\w+'"
                Test-Check -VM $vmName -Category "Vault" -Check "Vault initialized" -Passed ($vaultInit -match "true")

                $vaultSealed = Invoke-SSHCheck -IP $ip -Command "VAULT_ADDR=http://127.0.0.1:8200 vault status 2>/dev/null | grep -oP 'Sealed\s+\K\w+'"
                Test-Check -VM $vmName -Category "Vault" -Check "Vault unsealed" -Passed ($vaultSealed -match "false") -Detail "Sealed: $(if ($vaultSealed) { $vaultSealed.Trim() } else { 'N/A' })"

                $keysFile = Invoke-SSHCheck -IP $ip -Command "test -f /root/vault-keys.txt && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Unseal keys file exists (/root/vault-keys.txt)" -Passed ($keysFile -match "YES")

                $initJson = Invoke-SSHCheck -IP $ip -Command "test -f /root/vault-init.json && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Init JSON exists (/root/vault-init.json)" -Passed ($initJson -match "YES")

                $keysPerms = Invoke-SSHCheck -IP $ip -Command "stat -c '%a' /root/vault-keys.txt 2>/dev/null"
                Test-Check -VM $vmName -Category "Vault" -Check "Keys file permissions = 600" -Passed ($keysPerms -match "600") -Detail "Actual: $(if ($keysPerms) { $keysPerms.Trim() } else { 'N/A' })"

                $kvEnabled = Invoke-SSHCheck -IP $ip -Command "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=`$(jq -r .root_token /root/vault-init.json 2>/dev/null) vault secrets list 2>/dev/null | grep -q secret/ && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "KV v2 secrets engine enabled" -Passed ($kvEnabled -match "YES")

                $userpass = Invoke-SSHCheck -IP $ip -Command "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=`$(jq -r .root_token /root/vault-init.json 2>/dev/null) vault auth list 2>/dev/null | grep -q userpass && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Userpass auth enabled" -Passed ($userpass -match "YES")

                $unsealSvc = Invoke-SSHCheck -IP $ip -Command "systemctl is-enabled vault-unseal 2>/dev/null"
                Test-Check -VM $vmName -Category "Vault" -Check "Auto-unseal service enabled" -Passed ($unsealSvc -match "enabled")

                $unsealScript = Invoke-SSHCheck -IP $ip -Command "test -x /usr/local/bin/vault-unseal.sh && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Unseal helper script exists" -Passed ($unsealScript -match "YES")

                $vaultUI = Invoke-SSHCheck -IP $ip -Command "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8200/ui/ 2>/dev/null || echo 000"
                Test-Check -VM $vmName -Category "Vault" -Check "Vault UI responding" -Passed ($vaultUI -match "200|307") -Detail "HTTP: $($vaultUI.Trim())"

                $fw8200 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 8200 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Firewall port 8200 open" -Passed ($fw8200 -match "YES")

                $fw8201 = Invoke-SSHCheck -IP $ip -Command "firewall-cmd --list-ports 2>/dev/null | grep -q 8201 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "Vault" -Check "Firewall port 8201 open" -Passed ($fw8201 -match "YES")
            }

            "General" {
                # General-purpose VMs: just verify basic OS health
                $uptime = Invoke-SSHCheck -IP $ip -Command "uptime -p"
                Test-Check -VM $vmName -Category "OS" -Check "System is up" -Passed ($null -ne $uptime -and $uptime.Length -gt 0) -Detail $uptime.Trim()

                $dnf = Invoke-SSHCheck -IP $ip -Command "command -v dnf >/dev/null 2>&1 && echo YES || echo NO"
                Test-Check -VM $vmName -Category "OS" -Check "DNF package manager available" -Passed ($dnf -match "YES")
            }
        }
    }
}

# ============================================================
# Final Summary
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$passRate = if ($script:totalChecks -gt 0) { [math]::Round(($script:passedChecks / $script:totalChecks) * 100, 1) } else { 0 }

Write-Host "  Total Checks:   $($script:totalChecks)" -ForegroundColor White
Write-Host "  Passed:         $($script:passedChecks)" -ForegroundColor Green
Write-Host "  Failed:         $($script:failedChecks)" -ForegroundColor $(if ($script:failedChecks -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped:        $($script:skippedChecks)" -ForegroundColor $(if ($script:skippedChecks -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Pass Rate:      ${passRate}%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
Write-Host ""

# Per-VM summary
Write-Host "  Per-VM Results:" -ForegroundColor Cyan
$vmGroups = $script:results | Group-Object VM
foreach ($group in ($vmGroups | Sort-Object Name)) {
    $vmPass = ($group.Group | Where-Object { $_.Status -eq "PASS" }).Count
    $vmFail = ($group.Group | Where-Object { $_.Status -eq "FAIL" }).Count
    $vmSkip = ($group.Group | Where-Object { $_.Status -eq "SKIP" }).Count
    $vmTotal = $group.Group.Count
    $icon = if ($vmFail -eq 0 -and $vmSkip -eq 0) { "OK" } elseif ($vmFail -gt 0) { "!!" } else { "--" }
    $color = if ($vmFail -eq 0 -and $vmSkip -eq 0) { "Green" } elseif ($vmFail -gt 0) { "Red" } else { "Yellow" }
    Write-Host "    [$icon] $($group.Name.PadRight(14)) $vmPass/$vmTotal passed$(if ($vmFail -gt 0) { ", $vmFail FAILED" })$(if ($vmSkip -gt 0) { ", $vmSkip skipped" })" -ForegroundColor $color
}

# List all failures
if ($script:failedChecks -gt 0) {
    Write-Host ""
    Write-Host "  Failed Checks:" -ForegroundColor Red
    $failures = $script:results | Where-Object { $_.Status -eq "FAIL" }
    foreach ($f in $failures) {
        $detail = if ($f.Detail) { " ($($f.Detail))" } else { "" }
        Write-Host "    [FAIL] $($f.VM): $($f.Check)$detail" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan

# Export results to CSV
$csvPath = Join-Path $PSScriptRoot "audit-results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$script:results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "  Results exported to: $csvPath" -ForegroundColor Gray
Write-Host ""

# Cleanup
[System.GC]::Collect()
