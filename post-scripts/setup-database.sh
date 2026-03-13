#!/bin/bash
set -uo pipefail  # No -e: allow individual failures so both DBs get installed
exec > /root/database-setup.log 2>&1

# Service password passed as argument or default
SVC_PASSWORD="${1:-BoringLab123!}"

echo "=== BoringLab: PostgreSQL + MySQL Setup ==="

# ============================================
# PostgreSQL 17
# ============================================
echo "--- Installing PostgreSQL 17 ---"

# Install PostgreSQL repo (EL-10)
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Install PostgreSQL 17
dnf install -y postgresql17-server postgresql17-contrib

# Idempotency: only initdb if not already done
if [ ! -f /var/lib/pgsql/17/data/PG_VERSION ]; then
    /usr/pgsql-17/bin/postgresql-17-setup initdb
else
    echo "PostgreSQL already initialized, skipping initdb."
fi

# Configure PostgreSQL for remote access
PG_HBA="/var/lib/pgsql/17/data/pg_hba.conf"
PG_CONF="/var/lib/pgsql/17/data/postgresql.conf"

# Listen on all interfaces
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" $PG_CONF

# Allow connections from lab network (idempotent)
if ! grep -q "BoringLab network access" "$PG_HBA" 2>/dev/null; then
    echo "# BoringLab network access" >> $PG_HBA
    echo "host    all    all    10.10.10.0/24    md5" >> $PG_HBA
fi

# Start PostgreSQL
systemctl enable --now postgresql-17

# Create lab database and user (idempotent with IF NOT EXISTS)
sudo -u postgres psql << PGSQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'labadmin') THEN
        CREATE USER labadmin WITH PASSWORD '${SVC_PASSWORD}' SUPERUSER;
    END IF;
END
\$\$;
SELECT 'CREATE DATABASE boringlab OWNER labadmin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'boringlab')\gexec
SELECT 'CREATE DATABASE devops_app OWNER labadmin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'devops_app')\gexec

-- Create sample table
\c boringlab
CREATE TABLE IF NOT EXISTS lab_info (
    id SERIAL PRIMARY KEY,
    vm_name VARCHAR(50),
    ip_address VARCHAR(15),
    role VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Only insert if table is empty
INSERT INTO lab_info (vm_name, ip_address, role)
SELECT * FROM (VALUES
    ('DC01', '10.10.10.10', 'Domain Controller'),
    ('WS01', '10.10.10.11', 'IIS App Server'),
    ('WS02', '10.10.10.12', 'File Server'),
    ('ANSIBLE01', '10.10.10.20', 'Ansible Control Node'),
    ('K8S-MASTER', '10.10.10.30', 'Kubernetes Master'),
    ('K8S-WORKER1', '10.10.10.31', 'Kubernetes Worker'),
    ('K8S-WORKER2', '10.10.10.32', 'Kubernetes Worker'),
    ('RHEL01', '10.10.10.40', 'General Purpose'),
    ('RHEL02', '10.10.10.41', 'General Purpose'),
    ('GITLAB01', '10.10.10.50', 'GitLab CE'),
    ('DOCKER01', '10.10.10.51', 'Docker + Harbor'),
    ('MONITOR01', '10.10.10.52', 'Prometheus + Grafana'),
    ('DB01', '10.10.10.53', 'PostgreSQL + MySQL')
) AS v(vm_name, ip_address, role)
WHERE NOT EXISTS (SELECT 1 FROM lab_info LIMIT 1);
PGSQL

# ============================================
# MySQL 8
# ============================================
echo "--- Installing MySQL 8 ---"

# Install MySQL repo
dnf install -y https://dev.mysql.com/get/mysql84-community-release-el10-1.noarch.rpm || true
dnf install -y mysql-community-server mysql-community-client || {
    # Fallback: install MariaDB if MySQL repo fails
    echo "MySQL repo failed, installing MariaDB as alternative..."
    dnf install -y mariadb-server mariadb
}

# Start MySQL/MariaDB
systemctl enable --now mysqld 2>/dev/null || systemctl enable --now mariadb 2>/dev/null

# Get temporary MySQL root password (MySQL only)
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}') || true

if [ -n "$TEMP_PASS" ]; then
    # MySQL: change root password
    mysql --connect-expired-password -u root -p"$TEMP_PASS" <<MYSQL_INIT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${SVC_PASSWORD}';
FLUSH PRIVILEGES;
MYSQL_INIT
    MYSQL_PASS="$SVC_PASSWORD"
else
    # MariaDB: set root password
    mysqladmin -u root password "$SVC_PASSWORD" 2>/dev/null || true
    MYSQL_PASS="$SVC_PASSWORD"
fi

# Configure MySQL
mysql -u root -p"$MYSQL_PASS" <<MYSQL_SETUP
-- Create lab user with remote access
CREATE USER IF NOT EXISTS 'labadmin'@'%' IDENTIFIED BY '${SVC_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'labadmin'@'%' WITH GRANT OPTION;

-- Create lab databases
CREATE DATABASE IF NOT EXISTS boringlab;
CREATE DATABASE IF NOT EXISTS devops_app;

USE boringlab;
CREATE TABLE IF NOT EXISTS lab_info (
    id INT AUTO_INCREMENT PRIMARY KEY,
    vm_name VARCHAR(50),
    ip_address VARCHAR(15),
    role VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO lab_info (vm_name, ip_address, role)
SELECT 'DC01', '10.10.10.10', 'Domain Controller' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM lab_info LIMIT 1);

FLUSH PRIVILEGES;
MYSQL_SETUP

# Open firewall ports (at end so core setup isn't blocked)
systemctl enable --now firewalld 2>/dev/null || true
firewall-cmd --permanent --add-port=5432/tcp  2>/dev/null || true  # PostgreSQL
firewall-cmd --permanent --add-port=3306/tcp  2>/dev/null || true  # MySQL
firewall-cmd --permanent --add-port=9187/tcp  2>/dev/null || true  # PostgreSQL exporter
firewall-cmd --permanent --add-port=9104/tcp  2>/dev/null || true  # MySQL exporter
firewall-cmd --reload 2>/dev/null || true

echo ""
echo "=== Database setup complete ==="
echo "PostgreSQL 17:"
echo "  Host: 10.10.10.53, Port: 5432"
echo "  User: labadmin"
echo "  Databases: boringlab, devops_app"
echo ""
echo "MySQL 8.4:"
echo "  Host: 10.10.10.53, Port: 3306"
echo "  User: labadmin"
echo "  Databases: boringlab, devops_app"
