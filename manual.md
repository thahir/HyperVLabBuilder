# BoringLab - Hyper-V DevOps Lab Builder

## Quick Start

```powershell
# Run as Administrator on your Hyper-V host
.\Build-BoringLab.ps1
```

That's it. The script handles everything - downloading images, creating VMs, configuring services.

## What It Builds

13 VMs on a `10.10.10.0/24` internal network with NAT (internet access):

| VM | IP | OS | Purpose |
|---|---|---|---|
| DC01 | 10.10.10.10 | Windows Server 2022 | Active Directory Domain Controller + DNS + DHCP |
| WS01 | 10.10.10.11 | Windows Server 2022 | IIS Web Server (domain-joined) |
| WS02 | 10.10.10.12 | Windows Server 2022 | File Server (domain-joined) |
| ANSIBLE01 | 10.10.10.20 | RHEL 10 | Ansible control node with full inventory |
| K8S-MASTER | 10.10.10.30 | RHEL 10 | Kubernetes 1.32 master (kubeadm + Calico CNI) |
| K8S-WORKER1 | 10.10.10.31 | RHEL 10 | Kubernetes worker node |
| K8S-WORKER2 | 10.10.10.32 | RHEL 10 | Kubernetes worker node |
| RHEL01 | 10.10.10.40 | RHEL 10 | General purpose |
| RHEL02 | 10.10.10.41 | RHEL 10 | General purpose |
| GITLAB01 | 10.10.10.50 | RHEL 10 | GitLab CE |
| DOCKER01 | 10.10.10.51 | RHEL 10 | Docker + Harbor registry |
| MONITOR01 | 10.10.10.52 | RHEL 10 | Prometheus + Grafana + Alertmanager |
| DB01 | 10.10.10.53 | RHEL 10 | PostgreSQL 17 + MySQL 8.4 |

**Domain:** BoringLab.local
**Total RAM:** ~120 GB across all VMs

## Prerequisites

- **Windows Server or Windows 11 Pro/Enterprise** with Hyper-V enabled
- **PowerShell 5.1+** (run as Administrator)
- **Red Hat subscription** (free developer account works: https://developers.redhat.com)
- **~20 GB free disk** for cloud image downloads (one-time)
- **~1 TB recommended** for all VM disks

## What Happens When You Run It

1. **Credentials prompt** — You enter:
   - Admin/root password (used for both Windows Administrator and Linux root)
   - Red Hat subscription username + password (popup dialog)

2. **Image download** (first run only, ~6.5 GB total) — The script asks before downloading:
   - RHEL 10 KVM cloud image (~1.5 GB) from Red Hat API
   - Windows Server 2022 eval VHD (~5 GB) from Microsoft
   - If qemu-img is needed and missing, offers to install via winget

3. **Template preparation** — Converts images to VHDX format

4. **VM creation** — Clones template VHDXs, injects configuration (cloud-init for Linux, unattend.xml for Windows)

5. **Boot** — Cloud images boot in 2-3 minutes (vs 25-30 min with ISOs)

6. **Post-install** — Fully automated:
   - DC01: AD forest promotion, DNS, DHCP
   - WS01/WS02: Domain join, feature installation
   - ANSIBLE01: Ansible + collections + full lab inventory
   - K8S: kubeadm cluster init, Calico CNI, workers join
   - GITLAB01: GitLab CE install
   - DOCKER01: Docker + Harbor registry
   - MONITOR01: Prometheus/Grafana/Alertmanager stack
   - DB01: PostgreSQL 17 + MySQL 8.4 with sample databases

**Total time: ~20 minutes** (mostly post-install configuration)

## Accessing the Lab

### Windows VMs
```powershell
mstsc /v:10.10.10.10    # DC01
mstsc /v:10.10.10.11    # WS01
mstsc /v:10.10.10.12    # WS02
```
**Login:** `BORINGLAB\Administrator` + your chosen password

### Linux VMs
```bash
ssh root@10.10.10.20    # ANSIBLE01
ssh root@10.10.10.30    # K8S-MASTER
ssh root@10.10.10.50    # GITLAB01
# ... etc
```
**Login:** `root` + your chosen password
**Alt user:** `labadmin` (same password, sudo access)

### Web UIs

| Service | URL | Credentials |
|---|---|---|
| GitLab | http://10.10.10.50 | root / see `/root/gitlab-root-password.txt` on GITLAB01 |
| Grafana | http://10.10.10.52:3000 | admin / BoringLab123! |
| Harbor | http://10.10.10.51 | admin / BoringLab123! |
| Prometheus | http://10.10.10.52:9090 | (no auth) |
| Alertmanager | http://10.10.10.52:9093 | (no auth) |

### Kubernetes
```bash
ssh root@10.10.10.30
kubectl get nodes
kubectl get pods -A
```

### Ansible
```bash
ssh root@10.10.10.20
ansible all -m ping
ansible-inventory --list
```

## Configuration

All settings are in `config.psd1`:

| Setting | Default | Description |
|---|---|---|
| `VMPath` | `D:\HyperV\VMs` | Where VM disks and configs are stored |
| `TemplatePath` | `D:\HyperV\Templates` | Where cloud image templates are cached |
| `AutoDownload` | `$true` | Auto-download images if missing |
| `DomainName` | `BoringLab.local` | AD domain name |
| `SwitchName` | `BoringLabSwitch` | Hyper-V virtual switch name |
| `Subnet` | `10.10.10.0/24` | Lab network subnet |

You can adjust VM RAM, vCPU, disk size, and IP addresses in the `VMs` array.

## Re-running the Script

The script is **idempotent** — safe to run again:
- Existing VMs are skipped (not recreated or destroyed)
- Existing templates are reused (not re-downloaded)
- Existing network/switch is reused

To add a VM: add its definition to `config.psd1` and re-run.

## Skipping Post-Install

To create VMs without configuring them:
```powershell
.\Build-BoringLab.ps1 -SkipPostInstall
```

## Disabling Auto-Download

If you prefer to download images manually:
1. Set `AutoDownload = $false` in `config.psd1`
2. Place images in `D:\HyperV\Templates\`:
   - RHEL: Download KVM Guest Image (.qcow2) from https://access.redhat.com/downloads/content/rhel
   - Windows: Download VHD from https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
3. Install qemu-img if using .qcow2: `winget install SoftwareFreedomConservancy.QEMU`

## Red Hat Auth Troubleshooting

The script tries your subscription credentials first. If that fails (e.g., 2FA enabled), it will ask for an **offline token**:

1. Go to https://access.redhat.com/management/api
2. Click "Generate Token"
3. Paste the token when prompted

This is a one-time step per session (the token is not saved anywhere).

## Log Files

Build logs are saved to: `D:\HyperV\VMs\BoringLab-Build_YYYYMMDD_HHmmss.log`

Credentials are **never** written to log files.

## Project Structure

```
HyperVLsbBuilder/
├── Build-BoringLab.ps1           # Main entry point
├── config.psd1                    # All configuration
├── manual.md                      # This file
├── modules/
│   ├── ImageDownload.psm1        # Auto-download cloud images
│   ├── CloudImage.psm1           # Template validation + conversion
│   ├── CloudInit.psm1            # Linux VM cloud-init config
│   ├── WindowsUnattend.psm1      # Windows VM unattend injection
│   ├── LabNetwork.psm1           # Virtual switch + NAT
│   ├── LabVM.psm1                # VM creation
│   └── PostInstall.psm1          # Post-boot configuration
└── post-scripts/
    ├── Configure-DC.ps1          # AD DS promotion
    ├── Join-Domain.ps1           # Domain join
    ├── setup-ansible.sh          # Ansible control node
    ├── setup-k8s-master.sh       # Kubernetes master
    ├── setup-k8s-worker.sh       # Kubernetes worker
    ├── setup-gitlab.sh           # GitLab CE
    ├── setup-docker-harbor.sh    # Docker + Harbor
    ├── setup-monitoring.sh       # Prometheus + Grafana
    └── setup-database.sh         # PostgreSQL + MySQL
```
