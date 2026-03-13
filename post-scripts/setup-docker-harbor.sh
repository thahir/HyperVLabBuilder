#!/bin/bash
set -euo pipefail
exec > /root/docker-harbor-setup.log 2>&1

# Service password passed as argument or default
SVC_PASSWORD="${1:-BoringLab123!}"

echo "=== BoringLab: Docker + Harbor Registry Setup ==="

# Idempotency: skip if Harbor is already installed and running
if [ -f /opt/harbor/docker-compose.yml ] && docker compose -f /opt/harbor/docker-compose.yml ps --status running 2>/dev/null | grep -q "harbor"; then
    echo "Harbor already running. Skipping."
    exit 0
fi

# Install Docker CE
dnf install -y yum-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
systemctl enable --now docker

# Add labadmin to docker group
usermod -aG docker labadmin

# Install Harbor
HARBOR_VERSION="v2.10.0"
echo "Downloading Harbor ${HARBOR_VERSION}..."
cd /opt
curl -fsSL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" -o harbor.tgz
tar xzf harbor.tgz
rm harbor.tgz
cd harbor

# Configure Harbor
cp harbor.yml.tmpl harbor.yml

# Update harbor.yml
sed -i "s|hostname: reg.mydomain.com|hostname: docker01.boringlab.local|" harbor.yml
sed -i "s|^https:|#https:|" harbor.yml
sed -i "s|port: 443|#port: 443|" harbor.yml
sed -i "s|certificate: /your/certificate/path|#certificate: /your/certificate/path|" harbor.yml
sed -i "s|private_key: /your/private/key/path|#private_key: /your/private/key/path|" harbor.yml
sed -i "s|harbor_admin_password: Harbor12345|harbor_admin_password: ${SVC_PASSWORD}|" harbor.yml

# Install Harbor
if ! ./install.sh --with-trivy; then
    echo "ERROR: Harbor installation failed."
    exit 1
fi

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=80/tcp    2>/dev/null || true  # Harbor HTTP
firewall-cmd --permanent --add-port=443/tcp   2>/dev/null || true  # Harbor HTTPS
firewall-cmd --permanent --add-port=4443/tcp  2>/dev/null || true  # Harbor Notary
firewall-cmd --reload 2>/dev/null || true

echo ""
echo "=== Docker + Harbor setup complete ==="
echo "Harbor UI:  http://docker01.boringlab.local (or http://10.10.10.51)"
echo "Harbor Admin: admin / <service_password>"
echo ""
echo "To use Harbor as a registry from other nodes:"
echo '  Add to /etc/docker/daemon.json: {"insecure-registries": ["docker01.boringlab.local"]}'
echo "  docker login docker01.boringlab.local"
