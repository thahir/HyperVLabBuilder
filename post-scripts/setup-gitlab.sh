#!/bin/bash
set -euo pipefail
exec > /root/gitlab-setup.log 2>&1

echo "=== BoringLab: GitLab CE Setup ==="

# Install prerequisites
dnf install -y curl policycoreutils openssh-server perl postfix
systemctl enable --now sshd postfix

# Open firewall ports
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --reload

# Add GitLab CE repository
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh | bash

# Install GitLab CE
EXTERNAL_URL="http://gitlab.boringlab.local" dnf install -y gitlab-ce

# Configure GitLab for lab use (reduce memory footprint)
cat >> /etc/gitlab/gitlab.rb << 'GITCFG'

# BoringLab GitLab Configuration
external_url 'http://gitlab.boringlab.local'
gitlab_rails['gitlab_shell_ssh_port'] = 22

# Reduce memory usage for lab environment
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
postgresql['shared_buffers'] = '256MB'
prometheus_monitoring['enable'] = false
GITCFG

# Reconfigure GitLab
gitlab-ctl reconfigure

# Wait for GitLab to be fully operational
echo "Waiting for GitLab services to be ready..."
MAX_WAIT=300
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if gitlab-ctl status 2>/dev/null | grep -q "run:"; then
        # Check if the web interface is responsive
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/-/readiness 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "503" ]; then
            echo "GitLab web interface is responding (HTTP $HTTP_CODE)."
            break
        fi
    fi
    echo "Still waiting... ($ELAPSED/${MAX_WAIT}s)"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
done

# Retrieve initial root password
echo ""
echo "=== GitLab CE setup complete ==="
echo "Access: http://gitlab.boringlab.local (or http://10.10.10.50)"

if [ -f /etc/gitlab/initial_root_password ]; then
    INITIAL_PASS=$(grep 'Password:' /etc/gitlab/initial_root_password | awk '{print $2}')
    echo "Initial root password: $INITIAL_PASS"
    # Save to a persistent location
    echo "$INITIAL_PASS" > /root/gitlab-root-password.txt
    echo "(Also saved to /root/gitlab-root-password.txt)"
else
    echo "WARNING: /etc/gitlab/initial_root_password not found."
    echo "You can reset the root password with:"
    echo "  gitlab-rake 'gitlab:password:reset[root]'"
fi
