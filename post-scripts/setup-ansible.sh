#!/bin/bash
set -euo pipefail
exec > /root/ansible-setup.log 2>&1

echo "=== BoringLab: Ansible Control Node Setup ==="

# Install EPEL and Ansible (RHEL 10)
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm || true
# python3-winrm doesn't exist in RHEL 10 repos (installed via pip below)
dnf install -y ansible-core python3-pip sshpass

# Install additional Ansible collections
ansible-galaxy collection install ansible.windows
ansible-galaxy collection install community.general
ansible-galaxy collection install community.mysql
ansible-galaxy collection install community.postgresql
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install ansible.posix

# Install pywinrm for Windows management
# PEP 668: RHEL 10 requires --break-system-packages for system-wide pip installs
pip3 install --break-system-packages pywinrm requests-ntlm

# Create Ansible directory structure
mkdir -p /etc/ansible/{inventory/group_vars,inventory/host_vars,roles,playbooks}

# Create inventory file
cat > /etc/ansible/inventory/boringlab.ini << 'INV'
[dc]
DC01 ansible_host=10.10.10.10

[windows_servers]
WS01 ansible_host=10.10.10.11
WS02 ansible_host=10.10.10.12

[windows:children]
dc
windows_servers

[k8s_master]
K8S-MASTER ansible_host=10.10.10.30

[k8s_workers]
K8S-WORKER1 ansible_host=10.10.10.31
K8S-WORKER2 ansible_host=10.10.10.32

[k8s:children]
k8s_master
k8s_workers

[gitlab]
GITLAB01 ansible_host=10.10.10.50

[docker]
DOCKER01 ansible_host=10.10.10.51

[monitoring]
MONITOR01 ansible_host=10.10.10.52

[database]
DB01 ansible_host=10.10.10.53

[rhel_general]
RHEL01 ansible_host=10.10.10.40
RHEL02 ansible_host=10.10.10.41

[linux:children]
k8s
gitlab
docker
monitoring
database
rhel_general
INV

# Create group_vars for Windows hosts
cat > /etc/ansible/inventory/group_vars/windows.yml << 'WINVARS'
ansible_user: Administrator
ansible_connection: winrm
ansible_winrm_transport: ntlm
ansible_winrm_server_cert_validation: ignore
ansible_port: 5985
WINVARS

# Create group_vars for Linux hosts
cat > /etc/ansible/inventory/group_vars/linux.yml << 'LINVARS'
ansible_user: root
ansible_connection: ssh
ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
LINVARS

# Create ansible.cfg
cat > /etc/ansible/ansible.cfg << 'CFG'
[defaults]
inventory = /etc/ansible/inventory/boringlab.ini
host_key_checking = False
retry_files_enabled = False
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
CFG

# Create a sample ping playbook
cat > /etc/ansible/playbooks/ping-all.yml << 'PING'
---
- name: Ping all Linux hosts
  hosts: linux
  tasks:
    - name: Ping
      ansible.builtin.ping:

- name: Ping all Windows hosts
  hosts: windows
  tasks:
    - name: Ping
      ansible.windows.win_ping:
PING

# Generate SSH key for Ansible (skip if already exists)
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
else
    echo "SSH key already exists, skipping generation."
fi

echo "=== Ansible setup complete ==="
echo "Run: ansible -i /etc/ansible/inventory/boringlab.ini all -m ping"

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true
