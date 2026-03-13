#!/bin/bash
set -euo pipefail
exec > /root/vault-setup.log 2>&1

# Service password passed as argument or default
SVC_PASSWORD="${1:-BoringLab123!}"

echo "=== BoringLab: HashiCorp Vault Setup ==="

# Idempotency: skip if Vault is already running and initialized
if systemctl is-active --quiet vault 2>/dev/null && vault status -address=http://127.0.0.1:8200 2>/dev/null | grep -q "Initialized.*true"; then
    echo "Vault already running and initialized. Skipping."
    exit 0
fi

# Install Vault from HashiCorp repo
if ! command -v vault &>/dev/null; then
    echo "Installing HashiCorp Vault..."
    dnf install -y yum-utils
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    dnf install -y vault
fi

# Create Vault data directory
mkdir -p /opt/vault/data

# Configure Vault (file storage backend for lab use)
cat > /etc/vault.d/vault.hcl << 'VAULTCFG'
ui = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "file" {
  path = "/opt/vault/data"
}

api_addr     = "http://vault01.boringlab.local:8200"
cluster_addr = "http://vault01.boringlab.local:8201"
VAULTCFG

# Set ownership
chown -R vault:vault /opt/vault/data
chown vault:vault /etc/vault.d/vault.hcl

# Enable and start Vault
systemctl enable --now vault

# Wait for Vault to be ready
echo "Waiting for Vault to start..."
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8200/v1/sys/health -o /dev/null 2>/dev/null; then
        break
    fi
    sleep 2
done

export VAULT_ADDR="http://127.0.0.1:8200"

# Initialize Vault (3 key shares, 2 key threshold for lab simplicity)
KEYS_FILE="/root/vault-keys.txt"

if ! vault status 2>/dev/null | grep -q "Initialized.*true"; then
    echo "Initializing Vault..."
    vault operator init -key-shares=3 -key-threshold=2 -format=json > /root/vault-init.json

    # Extract keys and root token into a readable file
    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /root/vault-init.json)
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /root/vault-init.json)
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' /root/vault-init.json)
    ROOT_TOKEN=$(jq -r '.root_token' /root/vault-init.json)

    cat > "$KEYS_FILE" << EOF
============================================
  BoringLab Vault - Unseal Keys & Root Token
============================================
  Generated: $(date)
  Vault Address: http://vault01.boringlab.local:8200

  Unseal Key 1: ${UNSEAL_KEY_1}
  Unseal Key 2: ${UNSEAL_KEY_2}
  Unseal Key 3: ${UNSEAL_KEY_3}

  Root Token:   ${ROOT_TOKEN}

  Key Threshold: 2 of 3 keys required to unseal
============================================
  IMPORTANT: In production, distribute these
  keys to different trusted operators.
  For this lab, all keys are stored here.
============================================
EOF

    chmod 600 "$KEYS_FILE"
    chmod 600 /root/vault-init.json

    # Unseal Vault (need 2 of 3 keys)
    echo "Unsealing Vault..."
    vault operator unseal "$UNSEAL_KEY_1"
    vault operator unseal "$UNSEAL_KEY_2"

    # Authenticate with root token
    export VAULT_TOKEN="$ROOT_TOKEN"

    # Enable KV secrets engine v2
    vault secrets enable -path=secret kv-v2 2>/dev/null || true

    # Store the lab service password in Vault
    vault kv put secret/boringlab/service-password password="$SVC_PASSWORD"

    # Store all lab VM info
    vault kv put secret/boringlab/lab-info \
        domain="boringlab.local" \
        gateway="10.10.10.1" \
        dc01="10.10.10.10" \
        ansible01="10.10.10.20" \
        k8s_master="10.10.10.30" \
        gitlab01="10.10.10.50" \
        docker01="10.10.10.51" \
        monitor01="10.10.10.52" \
        db01="10.10.10.53" \
        vault01="10.10.10.54"

    # Enable userpass auth method and create a lab admin user
    vault auth enable userpass 2>/dev/null || true
    vault policy write lab-admin - << 'POLICY'
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/health" {
  capabilities = ["read"]
}
path "sys/seal" {
  capabilities = ["update", "sudo"]
}
path "sys/unseal" {
  capabilities = ["update", "sudo"]
}
POLICY
    vault write auth/userpass/users/labadmin password="$SVC_PASSWORD" policies="lab-admin"

    echo ""
    echo "Vault initialized and unsealed successfully."
else
    echo "Vault already initialized. Attempting unseal from saved keys..."
    if [ -f /root/vault-init.json ]; then
        UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /root/vault-init.json)
        UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /root/vault-init.json)
        vault operator unseal "$UNSEAL_KEY_1" 2>/dev/null || true
        vault operator unseal "$UNSEAL_KEY_2" 2>/dev/null || true
    fi
fi

# Create a helper script for quick unseal after reboots
cat > /usr/local/bin/vault-unseal.sh << 'UNSEALSCRIPT'
#!/bin/bash
export VAULT_ADDR="http://127.0.0.1:8200"
if [ ! -f /root/vault-init.json ]; then
    echo "ERROR: /root/vault-init.json not found. Cannot auto-unseal."
    exit 1
fi
KEY1=$(jq -r '.unseal_keys_b64[0]' /root/vault-init.json)
KEY2=$(jq -r '.unseal_keys_b64[1]' /root/vault-init.json)
vault operator unseal "$KEY1"
vault operator unseal "$KEY2"
echo "Vault unsealed."
UNSEALSCRIPT
chmod +x /usr/local/bin/vault-unseal.sh

# Create a systemd service for auto-unseal on boot (lab convenience)
cat > /etc/systemd/system/vault-unseal.service << 'SVCUNIT'
[Unit]
Description=Auto-unseal Vault on boot (BoringLab)
After=vault.service
Requires=vault.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/vault-unseal.sh
Environment=VAULT_ADDR=http://127.0.0.1:8200

[Install]
WantedBy=multi-user.target
SVCUNIT

systemctl daemon-reload
systemctl enable vault-unseal.service

echo ""
echo "=== Vault setup complete ==="
echo "Vault UI:    http://vault01.boringlab.local:8200  (or http://10.10.10.54:8200)"
echo "Root Token:  See /root/vault-keys.txt"
echo "Lab Admin:   labadmin / <service_password> (userpass auth)"
echo ""
echo "Unseal keys and root token saved to: /root/vault-keys.txt"
echo "Auto-unseal on reboot: enabled (via vault-unseal.service)"
echo ""
echo "Quick commands:"
echo "  export VAULT_ADDR=http://10.10.10.54:8200"
echo "  vault login -method=userpass username=labadmin"
echo "  vault kv get secret/boringlab/service-password"

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=8200/tcp  2>/dev/null || true  # Vault API
firewall-cmd --permanent --add-port=8201/tcp  2>/dev/null || true  # Vault cluster
firewall-cmd --reload 2>/dev/null || true
