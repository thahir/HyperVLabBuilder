#!/bin/bash
set -euo pipefail
exec > /root/k8s-master-setup.log 2>&1

echo "=== BoringLab: Kubernetes Master Setup ==="

# Idempotency: skip if cluster already initialized
if [ -f /etc/kubernetes/admin.conf ]; then
    echo "Kubernetes cluster already initialized. Skipping."
    # Regenerate join command in case it expired
    kubeadm token create --print-join-command > /root/k8s-join-command.txt 2>/dev/null || true
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
modprobe overlay
modprobe br_netfilter

# Sysctl params for Kubernetes networking
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Disable SELinux (required for kubelet)
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

# Initialize Kubernetes cluster
echo "Initializing Kubernetes cluster..."
if ! kubeadm init \
    --apiserver-advertise-address=10.10.10.30 \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --node-name=K8S-MASTER 2>&1 | tee /root/kubeadm-init.log; then
    echo "ERROR: kubeadm init failed. Check /root/kubeadm-init.log"
    exit 1
fi

# Set up kubectl for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

# Set up kubectl for labadmin
mkdir -p /home/labadmin/.kube
cp /etc/kubernetes/admin.conf /home/labadmin/.kube/config
chown labadmin:labadmin /home/labadmin/.kube/config

# Install Calico CNI
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml

# Wait for Calico to be ready
echo "Waiting for Calico pods to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s || true

# Generate join command and save it
kubeadm token create --print-join-command > /root/k8s-join-command.txt

# Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || true
# Patch for self-signed certs in lab
kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' || true

# Open firewall ports (at end so core setup isn't blocked by firewalld issues)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=6443/tcp      2>/dev/null || true  # API server
firewall-cmd --permanent --add-port=2379-2380/tcp  2>/dev/null || true  # etcd
firewall-cmd --permanent --add-port=10250/tcp      2>/dev/null || true  # kubelet
firewall-cmd --permanent --add-port=10259/tcp      2>/dev/null || true  # kube-scheduler
firewall-cmd --permanent --add-port=10257/tcp      2>/dev/null || true  # kube-controller-manager
firewall-cmd --permanent --add-port=179/tcp        2>/dev/null || true  # Calico BGP
firewall-cmd --permanent --add-port=4789/udp       2>/dev/null || true  # VXLAN
firewall-cmd --reload 2>/dev/null || true

echo "=== Kubernetes Master setup complete ==="
echo "Join command saved to /root/k8s-join-command.txt"
kubectl get nodes
