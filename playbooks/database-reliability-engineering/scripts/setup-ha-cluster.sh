#!/usr/bin/env bash
# =============================================================================
# Script Setup PostgreSQL HA Cluster dengan Patroni
# Jalankan sebagai root di setiap node database
# Usage: ./setup-ha-cluster.sh [primary|replica] [node-ip] [primary-ip]
# =============================================================================
set -euo pipefail

# =============================================================================
# Konfigurasi — SESUAIKAN SEBELUM JALANKAN!
# =============================================================================
POSTGRES_VERSION="16"
PATRONI_CLUSTER_NAME="production-db"
POSTGRES_PASSWORD="GANTI_PASSWORD_POSTGRES"
REPLICATOR_PASSWORD="GANTI_PASSWORD_REPLICATOR"
ADMIN_PASSWORD="GANTI_PASSWORD_ADMIN"

# IPs cluster (sesuaikan!)
DB_PRIMARY_IP="10.0.1.1"
DB_REPLICA1_IP="10.0.1.2"
DB_REPLICA2_IP="10.0.1.3"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Script harus dijalankan sebagai root!"
        exit 1
    fi
}

# =============================================================================
install_dependencies() {
    log_info "Menginstall dependencies..."

    apt-get update -qq

    # PostgreSQL repository
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
        gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
        https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
        tee /etc/apt/sources.list.d/pgdg.list

    apt-get update -qq

    apt-get install -y \
        postgresql-${POSTGRES_VERSION} \
        postgresql-${POSTGRES_VERSION}-postgis \
        python3-pip \
        python3-dev \
        libpq-dev \
        etcd \
        haproxy \
        pgbouncer \
        pgbackrest \
        sysstat \
        htop \
        jq

    # Install Patroni
    pip3 install --quiet \
        patroni[etcd3]==3.2.2 \
        psycopg2-binary

    log_ok "Dependencies terinstall"
}

# =============================================================================
setup_system_tuning() {
    log_info "Mengoptimalkan system settings..."

    # Kernel parameters untuk PostgreSQL
    cat >> /etc/sysctl.d/99-postgresql.conf << 'EOF'
# PostgreSQL performance tuning
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
kernel.sem = 250 64000 100 512

# Network
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
EOF
    sysctl -p /etc/sysctl.d/99-postgresql.conf 2>/dev/null || true

    # Limits untuk postgres user
    cat >> /etc/security/limits.d/postgresql.conf << 'EOF'
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc 32768
postgres hard nproc 32768
EOF

    # Transparent huge pages — matikan untuk PostgreSQL!
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag

    # Persist hugepage setting
    cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=false
After=sysinit.target local-fs.target
Before=mongod.service postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    systemctl enable --now disable-thp.service

    log_ok "System tuning selesai"
}

# =============================================================================
setup_etcd() {
    local node_name="$1"
    local node_ip="$2"

    log_info "Mengkonfigurasi etcd untuk node ${node_name}..."

    mkdir -p /var/lib/etcd /var/log/etcd
    chown etcd:etcd /var/lib/etcd /var/log/etcd

    cat > /etc/etcd/etcd.conf.yml << EOF
name: '${node_name}'
data-dir: '/var/lib/etcd'
wal-dir: '/var/lib/etcd/wal'

listen-peer-urls: 'http://${node_ip}:2380'
listen-client-urls: 'http://${node_ip}:2379,http://127.0.0.1:2379'

advertise-client-urls: 'http://${node_ip}:2379'
initial-advertise-peer-urls: 'http://${node_ip}:2380'

initial-cluster: 'db-primary-01=http://${DB_PRIMARY_IP}:2380,db-replica-01=http://${DB_REPLICA1_IP}:2380,db-replica-02=http://${DB_REPLICA2_IP}:2380'
initial-cluster-token: 'production-db-cluster-token-$(openssl rand -hex 8)'
initial-cluster-state: 'new'

heartbeat-interval: 250
election-timeout: 2500

snapshot-count: 5000
auto-compaction-retention: "1"

log-level: info
log-outputs: ['/var/log/etcd/etcd.log']
EOF

    systemctl enable --now etcd
    sleep 5

    # Verify etcd running
    if etcdctl --endpoints="http://${node_ip}:2379" endpoint health &>/dev/null; then
        log_ok "etcd berjalan normal"
    else
        log_warn "etcd mungkin masih starting, lanjutkan..."
    fi
}

# =============================================================================
setup_patroni() {
    local node_name="$1"
    local node_ip="$2"
    local role="$3"

    log_info "Mengkonfigurasi Patroni untuk node ${node_name} (role: ${role})..."

    mkdir -p /etc/patroni /var/log/patroni
    chown postgres:postgres /etc/patroni /var/log/patroni

    # Hitung recommended settings berdasarkan RAM
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    SHARED_BUFFERS_MB=$((TOTAL_RAM_MB / 4))
    EFFECTIVE_CACHE_MB=$((TOTAL_RAM_MB * 3 / 4))
    WORK_MEM_MB=64
    MAINTENANCE_MB=$((TOTAL_RAM_MB / 16))

    cat > /etc/patroni/patroni.yml << EOF
scope: ${PATRONI_CLUSTER_NAME}
namespace: /patroni/
name: ${node_name}

etcd3:
  hosts:
    - ${DB_PRIMARY_IP}:2379
    - ${DB_REPLICA1_IP}:2379
    - ${DB_REPLICA2_IP}:2379
  protocol: http

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${node_ip}:8008

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        shared_buffers: "${SHARED_BUFFERS_MB}MB"
        effective_cache_size: "${EFFECTIVE_CACHE_MB}MB"
        work_mem: "${WORK_MEM_MB}MB"
        maintenance_work_mem: "${MAINTENANCE_MB}MB"
        max_connections: 200
        superuser_reserved_connections: 5
        log_min_duration_statement: 1000
        log_checkpoints: "on"
        log_connections: "on"
        log_disconnections: "on"
        log_lock_waits: "on"
        deadlock_timeout: "1s"
        autovacuum_vacuum_scale_factor: 0.05
        autovacuum_analyze_scale_factor: 0.02
        autovacuum_vacuum_cost_limit: 400
        archive_mode: "on"
        archive_command: "pgbackrest --stanza=${PATRONI_CLUSTER_NAME} archive-push %p"
        archive_timeout: "300s"

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: "en_US.UTF-8"

  pg_hba:
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator ${DB_PRIMARY_IP}/32 scram-sha-256
    - host replication replicator ${DB_REPLICA1_IP}/32 scram-sha-256
    - host replication replicator ${DB_REPLICA2_IP}/32 scram-sha-256
    - host all postgres 127.0.0.1/32 trust
    - host all all 0.0.0.0/0 scram-sha-256

  users:
    admin:
      password: "${ADMIN_PASSWORD}"
      options:
        - createrole
        - createdb
    replicator:
      password: "${REPLICATOR_PASSWORD}"
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${node_ip}:5432
  data_dir: /var/lib/postgresql/${POSTGRES_VERSION}/main
  bin_dir: /usr/lib/postgresql/${POSTGRES_VERSION}/bin
  pgpass: /tmp/pgpass

  authentication:
    replication:
      username: replicator
      password: "${REPLICATOR_PASSWORD}"
    superuser:
      username: postgres
      password: "${POSTGRES_PASSWORD}"

tags:
  nofailover: false
  noloadbalance: false
EOF

    # Buat systemd service untuk Patroni
    cat > /etc/systemd/system/patroni.service << 'EOF'
[Unit]
Description=Runners to orchestrate a high-availability PostgreSQL
After=syslog.target network.target etcd.service
Wants=etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure
StandardOutput=journal
StandardError=journal

# Environment
Environment=PATRONI_LOGLEVEL=INFO

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable patroni

    log_ok "Patroni dikonfigurasi untuk ${node_name}"
}

# =============================================================================
setup_backup() {
    log_info "Mengkonfigurasi pgBackRest..."

    mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
    chown postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest

    # Konfigurasi dasar — S3 bucket harus dikonfigurasi manual!
    cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
# TODO: Konfigurasi S3 atau storage backend yang sesuai
repo1-type=posix
repo1-path=/var/lib/pgbackrest
repo1-retention-full=4
repo1-retention-diff=14
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=GANTI_DENGAN_PASSPHRASE_KUAT
compress-type=lz4
compress-level=3
process-max=4
archive-async=y
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

[${PATRONI_CLUSTER_NAME}]
pg1-path=/var/lib/postgresql/${POSTGRES_VERSION}/main
pg1-port=5432
pg1-user=postgres
pg1-socket-path=/var/run/postgresql
EOF

    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    chmod 640 /etc/pgbackrest/pgbackrest.conf

    mkdir -p /var/lib/pgbackrest
    chown postgres:postgres /var/lib/pgbackrest

    log_ok "pgBackRest dikonfigurasi (sesuaikan storage backend!)"
}

# =============================================================================
setup_monitoring_user() {
    log_info "Membuat monitoring user di PostgreSQL..."

    # Script ini dijalankan setelah Patroni aktif
    cat > /tmp/setup_monitoring.sql << EOF
-- Buat user monitoring dengan akses minimal
CREATE USER monitoring_user WITH PASSWORD 'GANTI_PASSWORD_MONITORING' NOSUPERUSER NOCREATEROLE NOCREATEDB;

-- Grant permissions untuk monitoring
GRANT pg_monitor TO monitoring_user;
GRANT CONNECT ON DATABASE postgres TO monitoring_user;

-- Beri akses ke pg_stat_* views
GRANT SELECT ON pg_stat_activity TO monitoring_user;
GRANT SELECT ON pg_stat_replication TO monitoring_user;
GRANT SELECT ON pg_stat_database TO monitoring_user;
GRANT EXECUTE ON FUNCTION pg_current_wal_lsn() TO monitoring_user;

COMMENT ON ROLE monitoring_user IS 'User untuk postgres_exporter dan monitoring tools';
EOF

    log_warn "Jalankan setup_monitoring.sql setelah cluster PostgreSQL aktif:"
    log_warn "  psql -U postgres -f /tmp/setup_monitoring.sql"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local role="${1:-}"
    local node_ip="${2:-}"

    if [[ -z "$role" || -z "$node_ip" ]]; then
        echo "Usage: $0 [primary|replica] [node-ip]"
        echo "Example: $0 primary 10.0.1.1"
        exit 1
    fi

    case "$role" in
        primary)
            local node_name="db-primary-01"
            ;;
        replica)
            # Tentukan nama berdasarkan IP
            if [[ "$node_ip" == "$DB_REPLICA1_IP" ]]; then
                local node_name="db-replica-01"
            else
                local node_name="db-replica-02"
            fi
            ;;
        *)
            log_error "Role harus 'primary' atau 'replica'"
            exit 1
            ;;
    esac

    log_info "=== Setup Database HA Cluster ==="
    log_info "Node: ${node_name} (${node_ip})"
    log_info "Role: ${role}"
    echo ""

    check_root
    install_dependencies
    setup_system_tuning
    setup_etcd "$node_name" "$node_ip"
    setup_patroni "$node_name" "$node_ip" "$role"
    setup_backup
    setup_monitoring_user

    echo ""
    log_ok "=== Setup selesai untuk ${node_name} ==="
    echo ""
    log_info "Langkah selanjutnya:"
    echo "  1. Pastikan semua 3 node sudah di-setup"
    echo "  2. Start Patroni di primary terlebih dahulu:"
    echo "     systemctl start patroni"
    echo "  3. Verifikasi cluster:"
    echo "     patronictl -c /etc/patroni/patroni.yml list"
    echo "  4. Inisialisasi backup:"
    echo "     sudo -u postgres pgbackrest --stanza=${PATRONI_CLUSTER_NAME} stanza-create"
    echo "     sudo -u postgres pgbackrest --stanza=${PATRONI_CLUSTER_NAME} backup --type=full"
    echo ""
}

main "$@"
