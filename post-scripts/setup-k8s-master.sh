#!/bin/bash
set -euo pipefail
exec > /root/k8s-master-setup.log 2>&1

echo "=== BoringLab: Kubernetes Master Setup ==="
echo "[$(date '+%H:%M:%S')] Starting K8s master setup..."

# Kubernetes requires lowercase hostnames (DNS label rules).
# The VM hostname is set uppercase by cloud-init (K8S-MASTER).
# Fix it now so kubeadm generates certs matching the k8s node name.
hostnamectl set-hostname k8s-master
hostname k8s-master

# Idempotency: skip if cluster already initialized
if [ -f /etc/kubernetes/admin.conf ]; then
    echo "[$(date '+%H:%M:%S')] Kubernetes cluster already initialized. Skipping."
    # Regenerate join command in case it expired
    kubeadm token create --print-join-command > /root/k8s-join-command.txt 2>/dev/null || true
    exit 0
fi

# ── Step 1: Kernel modules & sysctl ──
echo "[$(date '+%H:%M:%S')] Step 1/9: Configuring kernel modules and sysctl..."
swapoff -a
sed -i '/swap/d' /etc/fstab

cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
# On RHEL 10+ (kernel 6.x), br_netfilter is built into the kernel.
# Load 'bridge' first — it makes br_netfilter's sysctl entries visible.
modprobe bridge 2>/dev/null || true
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

# If the /proc entry still isn't visible, force the sysctl via /proc directly
# rather than hard-failing — the kernel still enforces the setting.
if [ ! -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    echo "WARNING: bridge-nf-call-iptables not visible in /proc yet. Continuing anyway (built-in kernel support assumed)."
fi

cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
echo "[$(date '+%H:%M:%S')] Step 1/9: Done."

# ── Step 2: Disable SELinux ──
echo "[$(date '+%H:%M:%S')] Step 2/9: Disabling SELinux..."
setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
echo "[$(date '+%H:%M:%S')] Step 2/9: Done."

# ── Step 3: Install containerd ──
echo "[$(date '+%H:%M:%S')] Step 3/9: Installing containerd..."
dnf install -y yum-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y containerd.io
echo "[$(date '+%H:%M:%S')] Step 3/9: Packages installed."

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# Verify containerd is running
echo "[$(date '+%H:%M:%S')] Step 3/9: Verifying containerd..."
for i in $(seq 1 10); do
    if systemctl is-active --quiet containerd; then
        echo "[$(date '+%H:%M:%S')] Step 3/9: containerd is running."
        break
    fi
    echo "[$(date '+%H:%M:%S')] Step 3/9: Waiting for containerd (attempt $i/10)..."
    sleep 3
done
if ! systemctl is-active --quiet containerd; then
    echo "[$(date '+%H:%M:%S')] ERROR: containerd failed to start!"
    systemctl status containerd --no-pager || true
    exit 1
fi

# ── Step 4: Install Kubernetes components ──
echo "[$(date '+%H:%M:%S')] Step 4/9: Installing kubelet, kubeadm, kubectl..."
cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF

dnf install -y kubelet kubeadm kubectl
systemctl enable kubelet
echo "[$(date '+%H:%M:%S')] Step 4/9: Done."

# ── Step 5: Open firewall ports BEFORE kubeadm init ──
# CRITICAL: Must happen before init, otherwise kubelet/etcd/API server
# traffic is blocked by firewalld and kubeadm init hangs indefinitely.
echo "[$(date '+%H:%M:%S')] Step 5/9: Opening firewall ports..."
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=6443/tcp      2>/dev/null || true  # API server
firewall-cmd --permanent --add-port=2379-2380/tcp  2>/dev/null || true  # etcd
firewall-cmd --permanent --add-port=10250/tcp      2>/dev/null || true  # kubelet
firewall-cmd --permanent --add-port=10259/tcp      2>/dev/null || true  # kube-scheduler
firewall-cmd --permanent --add-port=10257/tcp      2>/dev/null || true  # kube-controller-manager
firewall-cmd --permanent --add-port=179/tcp        2>/dev/null || true  # Calico BGP
firewall-cmd --permanent --add-port=4789/udp       2>/dev/null || true  # VXLAN
firewall-cmd --permanent --add-port=5473/tcp       2>/dev/null || true  # Calico Typha
firewall-cmd --permanent --add-port=443/tcp        2>/dev/null || true  # HTTPS (image pulls)
firewall-cmd --permanent --add-port=10256/tcp      2>/dev/null || true  # kube-proxy
firewall-cmd --reload 2>/dev/null || true
echo "[$(date '+%H:%M:%S')] Step 5/9: Done."

# ── Step 6: Initialize Kubernetes cluster ──
echo "[$(date '+%H:%M:%S')] Step 6/9: Initializing Kubernetes cluster (timeout: 10m)..."
echo "[$(date '+%H:%M:%S')]   API server: 10.10.10.30"
echo "[$(date '+%H:%M:%S')]   Pod CIDR:   10.244.0.0/16"
echo "[$(date '+%H:%M:%S')]   Svc CIDR:   10.96.0.0/12"

if ! timeout --signal=TERM --kill-after=30 600 \
    kubeadm init \
    --apiserver-advertise-address=10.10.10.30 \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --node-name=k8s-master 2>&1 | tee /root/kubeadm-init.log; then
    echo "[$(date '+%H:%M:%S')] ERROR: kubeadm init failed or timed out!"
    echo "[$(date '+%H:%M:%S')] Dumping diagnostics..."
    echo "--- kubelet status ---"
    systemctl status kubelet --no-pager 2>&1 || true
    echo "--- kubelet journal (last 30 lines) ---"
    journalctl -u kubelet --no-pager -n 30 2>&1 || true
    echo "--- containerd status ---"
    systemctl status containerd --no-pager 2>&1 || true
    exit 1
fi
echo "[$(date '+%H:%M:%S')] Step 6/9: kubeadm init completed."

# Set up kubectl for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

# Set up kubectl for labadmin
mkdir -p /home/labadmin/.kube
cp /etc/kubernetes/admin.conf /home/labadmin/.kube/config
chown labadmin:labadmin /home/labadmin/.kube/config

# ── Step 7: Install Calico CNI ──
echo "[$(date '+%H:%M:%S')] Step 7/9: Installing Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml

echo "[$(date '+%H:%M:%S')] Step 7/9: Waiting for Calico pods (timeout: 5m)..."
if kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s; then
    echo "[$(date '+%H:%M:%S')] Step 7/9: Calico pods are ready."
else
    echo "[$(date '+%H:%M:%S')] WARNING: Calico pods not ready after 5m. Continuing..."
    echo "--- Calico pod status ---"
    kubectl get pods -n kube-system -l k8s-app=calico-node -o wide 2>&1 || true
    kubectl describe pods -n kube-system -l k8s-app=calico-node 2>&1 | tail -30 || true
fi

# ── Step 8: Generate join command ──
echo "[$(date '+%H:%M:%S')] Step 8/9: Generating worker join command..."
kubeadm token create --print-join-command > /root/k8s-join-command.txt
echo "[$(date '+%H:%M:%S')] Step 8/9: Join command saved to /root/k8s-join-command.txt"

# ── Step 9: Install Helm & metrics-server ──
echo "[$(date '+%H:%M:%S')] Step 9/9: Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "[$(date '+%H:%M:%S')] Step 9/9: Installing metrics-server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || true
# Patch for self-signed certs in lab
kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' || true

echo "[$(date '+%H:%M:%S')] Step 9/9: Done."

# ── Complete ──
echo ""
echo "=== Kubernetes Master setup complete ==="
echo "[$(date '+%H:%M:%S')] Join command saved to /root/k8s-join-command.txt"
echo "--- Node status ---"
kubectl get nodes
echo "--- Pod status ---"
kubectl get pods -n kube-system
