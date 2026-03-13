#!/bin/bash
set -euo pipefail
exec > /root/monitoring-setup.log 2>&1

# Service password passed as argument or default
SVC_PASSWORD="${1:-BoringLab123!}"

echo "=== BoringLab: Prometheus + Grafana Setup ==="

# Idempotency: if stack is already running, skip
if docker compose -f /opt/monitoring/docker-compose.yml ps --status running 2>/dev/null | grep -q "prometheus"; then
    echo "Monitoring stack already running. Skipping."
    exit 0
fi

# Install Docker for running monitoring stack
dnf install -y yum-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# Create monitoring directory
mkdir -p /opt/monitoring/{prometheus,grafana/{provisioning/datasources,provisioning/dashboards,dashboards},alertmanager}

# Prometheus configuration
cat > /opt/monitoring/prometheus/prometheus.yml << 'PROM'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets:
        - '10.10.10.20:9100'   # ANSIBLE01
        - '10.10.10.30:9100'   # K8S-MASTER
        - '10.10.10.31:9100'   # K8S-WORKER1
        - '10.10.10.32:9100'   # K8S-WORKER2
        - '10.10.10.40:9100'   # RHEL01
        - '10.10.10.41:9100'   # RHEL02
        - '10.10.10.50:9100'   # GITLAB01
        - '10.10.10.51:9100'   # DOCKER01
        - '10.10.10.52:9100'   # MONITOR01
        - '10.10.10.53:9100'   # DB01
        - '10.10.10.54:9100'   # VAULT01

  - job_name: 'vault'
    metrics_path: /v1/sys/metrics
    params:
      format: ['prometheus']
    static_configs:
      - targets: ['10.10.10.54:8200']

  - job_name: 'kubernetes'
    static_configs:
      - targets: ['10.10.10.30:6443']
    scheme: https
    tls_config:
      insecure_skip_verify: true

  - job_name: 'gitlab'
    static_configs:
      - targets: ['10.10.10.50:9168']

  - job_name: 'postgresql'
    static_configs:
      - targets: ['10.10.10.53:9187']

  - job_name: 'mysql'
    static_configs:
      - targets: ['10.10.10.53:9104']
PROM

# Alertmanager configuration
cat > /opt/monitoring/alertmanager/alertmanager.yml << 'ALERT'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'
ALERT

# Grafana datasource provisioning
cat > /opt/monitoring/grafana/provisioning/datasources/prometheus.yml << 'DS'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
DS

# Docker Compose for monitoring stack
cat > /opt/monitoring/docker-compose.yml << COMPOSE
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${SVC_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'

volumes:
  prometheus_data:
  grafana_data:
COMPOSE

# Start monitoring stack
cd /opt/monitoring
docker compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 15

# Import default Grafana dashboard
echo "Importing default Grafana dashboards..."
curl -s -X POST http://localhost:3000/api/dashboards/import \
    -H "Content-Type: application/json" \
    -u "admin:${SVC_PASSWORD}" \
    -d '{
        "dashboard": {"id": null, "uid": null, "title": "Node Exporter Full"},
        "overwrite": true,
        "inputs": [{"name": "DS_PROMETHEUS", "type": "datasource", "pluginId": "prometheus", "value": "Prometheus"}],
        "folderId": 0,
        "pluginId": "prometheus",
        "path": "",
        "dashboardId": 1860
    }' || true

echo ""
echo "=== Monitoring setup complete ==="
echo "Grafana:      http://10.10.10.52:3000 (admin / <service_password>)"
echo "Prometheus:   http://10.10.10.52:9090"
echo "Alertmanager: http://10.10.10.52:9093"
echo ""
echo "NOTE: Install node-exporter on other Linux hosts for metrics collection:"
echo "  dnf install -y node_exporter && systemctl enable --now node_exporter"

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=3000/tcp   2>/dev/null || true  # Grafana
firewall-cmd --permanent --add-port=9090/tcp   2>/dev/null || true  # Prometheus
firewall-cmd --permanent --add-port=9093/tcp   2>/dev/null || true  # Alertmanager
firewall-cmd --permanent --add-port=9100/tcp   2>/dev/null || true  # Node Exporter
firewall-cmd --reload 2>/dev/null || true
