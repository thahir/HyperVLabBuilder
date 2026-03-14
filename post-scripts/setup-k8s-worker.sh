#!/bin/bash
set -euo pipefail
exec > /root/k8s-worker-setup.log 2>&1

echo "=== BoringLab: Kubernetes Worker Setup ==="

# Kubernetes requires lowercase hostnames. Lowercase whatever cloud-init set.
LOWER_HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]')
hostnamectl set-hostname "$LOWER_HOSTNAME"
hostname "$LOWER_HOSTNAME"

# Idempotency: skip if already joined
if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "Already joined to a Kubernetes cluster. Skipping."
    exit 0
fi

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load required kernel modules
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
# On RHEL 10+ (kernel 6.x), br_netfilter is built into the kernel.
# Load 'bridge' first — it makes br_netfilter's sysctl entries visible.
modprobe bridge 2>/dev/null || true
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

# If the /proc entry still isn't visible, continue anyway (built-in assumed).
if [ ! -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    echo "WARNING: bridge-nf-call-iptables not visible in /proc yet. Continuing anyway (built-in kernel support assumed)."
fi

# Sysctl params
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Disable SELinux
setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Install containerd
dnf install -y yum-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# Add Kubernetes repo (v1.32)
cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF

# Install Kubernetes components
dnf install -y kubelet kubeadm kubectl
systemctl enable kubelet

# Join the cluster
# This placeholder is replaced by PostInstall.psm1 with the actual join command
JOIN_CMD="##K8S_JOIN_COMMAND##"

if [ "$JOIN_CMD" != "##K8S_JOIN_COMMAND##" ] && [ -n "$JOIN_CMD" ]; then
    echo "Joining Kubernetes cluster..."
    # Use bash -c instead of eval for safety
    bash -c "$JOIN_CMD"
else
    echo "WARNING: No join command provided. Attempting to fetch from master..."

    MAX_RETRIES=30
    RETRY=0
    JOIN_CMD=""
    while [ $RETRY -lt $MAX_RETRIES ]; do
        # Try reading saved join command first, then generate a new one
        JOIN_CMD=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            root@10.10.10.30 "cat /root/k8s-join-command.txt 2>/dev/null || kubeadm token create --print-join-command 2>/dev/null" 2>/dev/null) && break
        RETRY=$((RETRY + 1))
        echo "Waiting for master... (attempt $RETRY/$MAX_RETRIES)"
        sleep 30
    done

    if [ -n "$JOIN_CMD" ]; then
        echo "Joining cluster..."
        bash -c "$JOIN_CMD"
    else
        echo "ERROR: Could not retrieve join command. Manual join required."
        echo "Run on master: kubeadm token create --print-join-command"
        echo "Then run the output on this worker."
    fi
fi

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=10250/tcp      2>/dev/null || true  # kubelet
firewall-cmd --permanent --add-port=30000-32767/tcp 2>/dev/null || true # NodePort range
firewall-cmd --permanent --add-port=179/tcp         2>/dev/null || true  # Calico BGP
firewall-cmd --permanent --add-port=4789/udp        2>/dev/null || true  # VXLAN
firewall-cmd --reload 2>/dev/null || true

echo "=== Kubernetes Worker setup complete ==="
