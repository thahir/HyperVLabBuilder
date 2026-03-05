@{
    # ===== Lab Identity =====
    LabName       = "BoringLab"
    DomainName    = "BoringLab.local"
    DomainNetBIOS = "BORINGLAB"

    # ===== Paths =====
    VMPath         = "D:\HyperV\VMs"
    TemplatePath   = "D:\HyperV\Templates"

    # ===== Cloud Image Templates =====
    # The script auto-downloads these if missing from TemplatePath.
    # RHEL: Authenticated via your Red Hat subscription credentials.
    # Windows: Free evaluation VHD from Microsoft (180-day trial).
    RHELCloudImage   = "rhel-10.1-x86_64-kvm.qcow2"   # auto-detected from Red Hat API
    WindowsVHD       = "WindowsServer2022-eval.vhd"    # downloaded as .vhd, converted to .vhdx
    AutoDownload     = $true                            # set to $false to skip download prompts

    # ===== Network =====
    SwitchName    = "BoringLabSwitch"
    NATName       = "BoringLabNAT"
    Subnet        = "10.10.10.0/24"
    Gateway       = "10.10.10.1"
    PrefixLength  = 24
    DNSForwarders = @("8.8.8.8", "1.1.1.1")

    # ===== Domain Admin (created during DC promo) =====
    DomainAdminUser = "Administrator"

    # ===== Service Password (used for Grafana, Harbor, DB accounts, etc.) =====
    # Change this before first run. Used by post-install scripts for service accounts.
    ServicePassword = "BoringLab123!"

    # ===== VM Definitions =====
    VMs = @(
        # --- Windows VMs ---
        @{
            Name      = "DC01"
            OS        = "Windows"
            Role      = "DomainController"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 60
            IP        = "10.10.10.10"
        }
        @{
            Name      = "WS01"
            OS        = "Windows"
            Role      = "MemberServer"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 60
            IP        = "10.10.10.11"
            Features  = @("Web-Server", "Web-Asp-Net45", "Web-Mgmt-Console")
        }
        @{
            Name      = "WS02"
            OS        = "Windows"
            Role      = "MemberServer"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 60
            IP        = "10.10.10.12"
            Features  = @("FS-FileServer", "FS-Resource-Manager")
        }

        # --- Linux VMs ---
        @{
            Name      = "ANSIBLE01"
            OS        = "RHEL"
            Role      = "Ansible"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 50
            IP        = "10.10.10.20"
        }
        @{
            Name      = "K8S-MASTER"
            OS        = "RHEL"
            Role      = "K8sMaster"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 80
            IP        = "10.10.10.30"
        }
        @{
            Name      = "K8S-WORKER1"
            OS        = "RHEL"
            Role      = "K8sWorker"
            RAM       = 12GB
            vCPU      = 4
            DiskGB    = 80
            IP        = "10.10.10.31"
        }
        @{
            Name      = "K8S-WORKER2"
            OS        = "RHEL"
            Role      = "K8sWorker"
            RAM       = 12GB
            vCPU      = 4
            DiskGB    = 80
            IP        = "10.10.10.32"
        }
        @{
            Name      = "RHEL01"
            OS        = "RHEL"
            Role      = "General"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 50
            IP        = "10.10.10.40"
        }
        @{
            Name      = "RHEL02"
            OS        = "RHEL"
            Role      = "General"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 50
            IP        = "10.10.10.41"
        }
        @{
            Name      = "GITLAB01"
            OS        = "RHEL"
            Role      = "GitLab"
            RAM       = 12GB
            vCPU      = 4
            DiskGB    = 100
            IP        = "10.10.10.50"
        }
        @{
            Name      = "DOCKER01"
            OS        = "RHEL"
            Role      = "Docker"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 80
            IP        = "10.10.10.51"
        }
        @{
            Name      = "MONITOR01"
            OS        = "RHEL"
            Role      = "Monitoring"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 60
            IP        = "10.10.10.52"
        }
        @{
            Name      = "DB01"
            OS        = "RHEL"
            Role      = "Database"
            RAM       = 8GB
            vCPU      = 4
            DiskGB    = 80
            IP        = "10.10.10.53"
        }
        @{
            Name      = "VAULT01"
            OS        = "RHEL"
            Role      = "Vault"
            RAM       = 4GB
            vCPU      = 2
            DiskGB    = 40
            IP        = "10.10.10.54"
        }
    )
}
