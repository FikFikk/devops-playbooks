# 🗄️ Database Reliability Engineering (DRE)

> Panduan lengkap membangun database yang andal, aman, dan siap produksi menggunakan PostgreSQL dengan High Availability, backup otomatis, disaster recovery, dan observability menyeluruh.

---

## 📋 Daftar Isi

- [Latar Belakang & Masalah](#latar-belakang--masalah)
- [Arsitektur Solusi](#arsitektur-solusi)
- [Komponen Utama](#komponen-utama)
- [Struktur Repository](#struktur-repository)
- [Quick Start](#quick-start)
- [Setup Step-by-Step](#setup-step-by-step)
- [Backup & Recovery](#backup--recovery)
- [Monitoring & Alerting](#monitoring--alerting)
- [Disaster Recovery Playbook](#disaster-recovery-playbook)
- [Best Practices](#best-practices)
- [Pitfalls to Avoid](#pitfalls-to-avoid)
- [Troubleshooting](#troubleshooting)
- [Referensi & Tool Recommendations](#referensi--tool-recommendations)

---

## Latar Belakang & Masalah

Database adalah jantung dari hampir semua aplikasi modern. Kegagalan database = bisnis berhenti. Namun banyak tim yang masih mengoperasikan database dengan:

| Masalah Umum | Dampak |
|---|---|
| Single Point of Failure (SPOF) | Downtime total saat primary crash |
| Backup manual (atau tidak ada) | Kehilangan data saat disaster |
| Tidak punya PITR | Tidak bisa undo kesalahan delete/update |
| Monitoring reaktif (alert setelah down) | Response lambat, SLA terlampaui |
| Tidak pernah test restore | DR plan hanya di atas kertas |
| Connection overload | Aplikasi error meski DB healthy |

**Database Reliability Engineering** adalah praktik menerapkan prinsip SRE (Site Reliability Engineering) khusus pada layer database, memastikan:

- **High Availability**: 99.99% uptime dengan automatic failover < 30 detik
- **Durability**: Zero data loss dengan WAL-shipping + backup terenkripsi
- **Observability**: Full visibility ke performa, replication lag, dan health
- **Recoverability**: RTO < 60 menit, RPO < 5 menit untuk semua skenario

---

## Arsitektur Solusi

```
                    ┌─────────────────────────────────────────┐
                    │           APPLICATION LAYER              │
                    │   app-01    app-02    app-03             │
                    └──────────────────┬──────────────────────┘
                                       │
                    ┌──────────────────▼──────────────────────┐
                    │              HAProxy                     │
                    │  Port 5000: Primary (RW)                 │
                    │  Port 5001: Replica (RO, Load Balanced)  │
                    │  Port 7000: Stats Dashboard              │
                    └────┬────────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    ┌────▼────┐     ┌────▼────┐    ┌────▼────┐
    │  DB-01  │     │  DB-02  │    │  DB-03  │
    │ PRIMARY │◄────┤ REPLICA │    │ REPLICA │
    │ (Patroni│     │ (Patroni│    │ (Patroni│
    │  Leader)│     │  Member)│    │  Member)│
    └────┬────┘     └────┬────┘    └────┬────┘
         │               │               │
         └───────────────┼───────────────┘
                         │
                    ┌────▼────────────────────────────────────┐
                    │              etcd Cluster               │
                    │  Distributed consensus & leader election │
                    │  Berjalan di setiap node DB              │
                    └────┬────────────────────────────────────┘
                         │
         ┌───────────────▼────────────────────────────────────┐
         │              pgBackRest                            │
         │  Full backup: Minggu 01:00                         │
         │  Differential: Harian 01:00                        │
         │  WAL Archive: Continuous (setiap perubahan)        │
         └───────────────┬────────────────────────────────────┘
                         │
         ┌───────────────▼────────────────────────────────────┐
         │         S3 Backup Bucket (enkripsi AES-256)        │
         │                                                    │
         │  Primary Region ──replication──▶ DR Region         │
         └────────────────────────────────────────────────────┘
```

---

## Komponen Utama

### 1. PostgreSQL 16 + Patroni (High Availability)

**Patroni** adalah template untuk manajemen PostgreSQL HA berbasis Python. Ia mengotomatiskan:

- **Leader election** menggunakan distributed consensus (etcd)
- **Automatic failover** saat primary tidak responsif (default: 30 detik)
- **Replica promotion** dengan pg_rewind untuk recovery cepat
- **Configuration synchronization** di seluruh cluster
- **REST API** untuk monitoring dan manual operations

```bash
# Lihat status cluster
patronictl -c /etc/patroni/patroni.yml list

# Contoh output healthy cluster:
# + Cluster: production-db (7123456789012) +---------+----+-----------+
# | Member        | Host       | Role    | State   | TL | Lag in MB |
# +---------------+------------+---------+---------+----+-----------+
# | db-primary-01 | 10.0.1.1:5 | Leader  | running |  3 |           |
# | db-replica-01 | 10.0.1.2:5 | Replica | running |  3 |         0 |
# | db-replica-02 | 10.0.1.3:5 | Replica | running |  3 |         0 |
# +---------------+------------+---------+---------+----+-----------+
```

### 2. etcd (Distributed Consensus Store)

etcd menyediakan:
- **Distributed lock** untuk leader election — hanya 1 node yang bisa jadi primary
- **Cluster state** — konfigurasi DCS dibagikan ke semua Patroni member
- **Health monitoring** — Patroni secara periodik mem-ping etcd

### 3. HAProxy (Load Balancing & Health Check)

HAProxy mengecek Patroni REST API di port 8008:
- `/primary` → HTTP 200 jika node adalah Leader
- `/replica` → HTTP 200 jika node adalah Replica

Ini memastikan traffic `write` selalu ke primary, dan traffic `read-only` didistribusi ke replicas.

### 4. PgBouncer (Connection Pooling)

Tanpa connection pooler, setiap koneksi PostgreSQL = 5-10 MB RAM. Dengan 1000 koneksi = 5-10 GB RAM hanya untuk connection overhead!

PgBouncer menyediakan:
- **Transaction pooling**: 1 koneksi PgBouncer bisa melayani ratusan aplikasi
- **Max connections**: Batasi berapa koneksi ke PostgreSQL backend
- **Prepared statement support**: Kompatibel dengan ORM modern

### 5. pgBackRest (Backup Enterprise-Grade)

pgBackRest unggul karena:
- **Incremental backup**: Hanya backup blok data yang berubah
- **Parallel backup/restore**: Gunakan semua CPU core
- **Enkripsi**: AES-256-CBC built-in
- **PITR**: Restore ke detik manapun dalam history
- **S3/GCS/Azure support**: Langsung tanpa wrapper
- **Backup dari replica**: Tidak membebani primary

---

## Struktur Repository

```
database-reliability-engineering/
├── README.md                           # Dokumen ini
├── scripts/
│   ├── setup-ha-cluster.sh             # Script setup Patroni cluster
│   ├── db-healthcheck.sh               # Health check script (cron)
│   └── test-restore.sh                 # DR test — verifikasi backup bulanan
├── configs/
│   ├── patroni-primary.yml             # Konfigurasi Patroni lengkap
│   ├── haproxy.cfg                     # HAProxy untuk routing read/write
│   ├── pgbouncer.ini                   # PgBouncer connection pooling
│   └── etcd-cluster.yml               # etcd 3-node cluster config
├── backup/
│   └── pgbackrest.conf                 # pgBackRest backup configuration
├── monitoring/
│   ├── prometheus-alerts.yml           # Alert rules Prometheus
│   ├── postgres-exporter.yml           # postgres_exporter config
│   ├── postgres-exporter-queries.yml   # Custom metrics queries
│   └── grafana-dashboard.json         # Grafana dashboard siap import
├── terraform/
│   └── main.tf                         # AWS infrastructure (VPC, EC2, S3, KMS)
└── docs/
    └── disaster-recovery-runbook.md    # Runbook DR per skenario
```

---

## Quick Start

### Prasyarat

```bash
# Minimal 3 server/VM dengan:
# - Ubuntu 22.04 LTS
# - CPU: 4+ core (8+ untuk production)
# - RAM: 16+ GB (32+ untuk production)
# - Disk Data: SSD NVMe, 500GB+
# - Network: Private network antar nodes

# Clone repository
git clone https://github.com/your-org/devops-playbooks.git
cd devops-playbooks/playbooks/database-reliability-engineering
```

### Setup 3-Node HA Cluster

```bash
# Node 1 (Primary) — jalankan dari node 10.0.1.1
sudo bash scripts/setup-ha-cluster.sh primary 10.0.1.1

# Node 2 (Replica 1) — jalankan dari node 10.0.1.2
sudo bash scripts/setup-ha-cluster.sh replica 10.0.1.2

# Node 3 (Replica 2) — jalankan dari node 10.0.1.3
sudo bash scripts/setup-ha-cluster.sh replica 10.0.1.3
```

---

## Setup Step-by-Step

### Fase 1: Persiapan Infrastructure

#### 1.1 System Requirements

```bash
# Cek hardware compatibility
echo "CPU cores: $(nproc)"
echo "RAM: $(free -h | awk '/Mem:/{print $2}')"
echo "Disk: $(df -h /var/lib/postgresql 2>/dev/null | tail -1)"

# Optimal PostgreSQL settings berdasarkan RAM:
# RAM 16 GB  → shared_buffers=4GB, effective_cache=12GB, max_connections=200
# RAM 32 GB  → shared_buffers=8GB, effective_cache=24GB, max_connections=300
# RAM 64 GB  → shared_buffers=16GB, effective_cache=48GB, max_connections=500
```

#### 1.2 Install PostgreSQL 16

```bash
# Tambah PostgreSQL repository
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    sudo gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
    https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
    sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt-get update
sudo apt-get install -y postgresql-16 postgresql-16-postgis

# Verifikasi
psql --version
# postgresql 16.x
```

#### 1.3 Setup etcd Cluster

```bash
# Install etcd di semua 3 node
sudo apt-get install -y etcd

# Copy konfigurasi
sudo cp configs/etcd-cluster.yml /etc/etcd/etcd.conf.yml

# Sesuaikan nama node dan IP di config
# Lalu start etcd di semua node
sudo systemctl enable --now etcd

# Verifikasi cluster health
etcdctl --endpoints="http://10.0.1.1:2379,http://10.0.1.2:2379,http://10.0.1.3:2379" \
    endpoint health
```

#### 1.4 Install & Konfigurasi Patroni

```bash
# Install Patroni
sudo pip3 install 'patroni[etcd3]==3.2.2' psycopg2-binary

# Copy dan sesuaikan konfigurasi
sudo cp configs/patroni-primary.yml /etc/patroni/patroni.yml
sudo vim /etc/patroni/patroni.yml  # Sesuaikan IP, password, dll

# Start Patroni (di primary terlebih dahulu!)
sudo systemctl start patroni

# Tunggu cluster bootstrap (30-60 detik)
sleep 30
patronictl -c /etc/patroni/patroni.yml list
```

#### 1.5 Setup HAProxy

```bash
# Install HAProxy
sudo apt-get install -y haproxy

# Copy konfigurasi
sudo cp configs/haproxy.cfg /etc/haproxy/haproxy.cfg

# Sesuaikan IP server di dalam config
sudo vim /etc/haproxy/haproxy.cfg

# Verifikasi config
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Start HAProxy
sudo systemctl enable --now haproxy
```

#### 1.6 Setup PgBouncer

```bash
# Install PgBouncer
sudo apt-get install -y pgbouncer

# Copy konfigurasi
sudo cp configs/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini

# Setup userlist
echo '"app_user" "HASH_ATAU_PASSWORD"' | sudo tee /etc/pgbouncer/userlist.txt

# Start PgBouncer
sudo systemctl enable --now pgbouncer

# Verifikasi
psql -h localhost -p 6432 -U app_user -c "SHOW DATABASES;" pgbouncer
```

### Fase 2: Konfigurasi Backup

#### 2.1 Install & Setup pgBackRest

```bash
# Install pgBackRest
sudo apt-get install -y pgbackrest

# Buat direktori
sudo mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
sudo chown postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest

# Copy dan sesuaikan konfigurasi S3
sudo cp backup/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
sudo vim /etc/pgbackrest/pgbackrest.conf
# → Isi S3 bucket, region, credentials, dan passphrase enkripsi!

# Inisialisasi stanza
sudo -u postgres pgbackrest --stanza=production stanza-create

# Verifikasi
sudo -u postgres pgbackrest --stanza=production check

# Jalankan backup pertama
sudo -u postgres pgbackrest --stanza=production backup --type=full
```

#### 2.2 Jadwalkan Backup Otomatis

```bash
# Setup cron untuk postgres user
sudo crontab -u postgres -e

# Tambahkan jadwal berikut:
# Full backup tiap Minggu jam 01:00
0 1 * * 0 pgbackrest --stanza=production backup --type=full >> /var/log/pgbackrest/cron.log 2>&1

# Differential backup Selasa-Sabtu jam 01:00
0 1 * * 2-7 pgbackrest --stanza=production backup --type=diff >> /var/log/pgbackrest/cron.log 2>&1

# Expire backup lama (jalan setelah backup selesai)
30 1 * * * pgbackrest --stanza=production expire >> /var/log/pgbackrest/cron.log 2>&1
```

### Fase 3: Setup Monitoring

#### 3.1 Install postgres_exporter

```bash
# Download postgres_exporter
wget https://github.com/prometheus-community/postgres_exporter/releases/latest/download/postgres_exporter-*.linux-amd64.tar.gz
tar xvf postgres_exporter-*.linux-amd64.tar.gz
sudo cp postgres_exporter-*/postgres_exporter /usr/local/bin/

# Buat user monitoring di PostgreSQL
sudo -u postgres psql << 'EOF'
CREATE USER monitoring_user WITH PASSWORD 'password_yang_kuat' NOSUPERUSER;
GRANT pg_monitor TO monitoring_user;
GRANT CONNECT ON DATABASE postgres TO monitoring_user;
EOF

# Buat systemd service
sudo tee /etc/systemd/system/postgres_exporter.service > /dev/null << 'EOF'
[Unit]
Description=PostgreSQL Prometheus Exporter
After=network.target

[Service]
User=postgres
Environment=DATA_SOURCE_NAME="postgresql://monitoring_user:password@localhost:5432/postgres?sslmode=require"
Environment=PG_EXPORTER_QUERY_FILE="/etc/postgres_exporter/queries.yml"
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=":9187"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now postgres_exporter
```

#### 3.2 Import Alert Rules ke Prometheus

```yaml
# Tambahkan ke prometheus.yml
rule_files:
  - "/etc/prometheus/rules/postgresql-alerts.yml"

# Copy file alert rules
sudo cp monitoring/prometheus-alerts.yml /etc/prometheus/rules/postgresql-alerts.yml
sudo systemctl reload prometheus
```

#### 3.3 Import Grafana Dashboard

```bash
# Via Grafana API
curl -s -X POST \
    -H "Content-Type: application/json" \
    -d @monitoring/grafana-dashboard.json \
    "http://admin:password@grafana:3000/api/dashboards/import"

# Atau manual: Grafana → Import → Upload JSON file
```

---

## Backup & Recovery

### Jenis Backup yang Dibuat

| Jenis | Frekuensi | Ukuran | Keterangan |
|---|---|---|---|
| **Full** | Mingguan | 100% data | Base untuk restore |
| **Differential** | Harian | Hanya perubahan sejak full | Lebih cepat dari full |
| **WAL Archive** | Continuous | Sangat kecil per file | Untuk PITR ke detik manapun |

### Recovery Time Objective (RTO) & RPO

| Skenario | RTO | RPO |
|---|---|---|
| Primary failure (auto-failover) | < 30 detik | 0 (tidak ada data loss) |
| Full node restore dari backup | 30-60 menit | < 5 menit (WAL archive) |
| PITR (kesalahan DELETE/UPDATE) | 30-60 menit | Sampai 1 detik sebelum |
| Full datacenter failure (DR) | 60-120 menit | < 5 menit |

### Point-in-Time Recovery

```bash
# 1. Cek backup yang tersedia
pgbackrest --stanza=production info

# 2. Restore ke waktu tertentu (misal: sebelum accidental DELETE)
sudo -u postgres pgbackrest --stanza=production restore \
    --type=time \
    --target="2024-06-15 14:30:00+07" \
    --target-action=promote \
    --delta  # Delta mode: hanya file yang berubah

# 3. Verifikasi data
psql -U postgres myapp -c "SELECT count(*) FROM orders;"

# 4. Jika data sudah benar, promote instance
# (--target-action=promote otomatis melakukan ini)
```

---

## Monitoring & Alerting

### Alert Levels dan Response SLA

| Severity | Alert | Response SLA | PIC |
|---|---|---|---|
| 🔴 CRITICAL | PostgreSQL down | 5 menit | On-Call DBA + Pager |
| 🔴 CRITICAL | Replication lag > 5 menit | 5 menit | On-Call DBA |
| 🔴 CRITICAL | Koneksi > 85% | 15 menit | Dev + DBA |
| 🟡 WARNING | Replication lag > 30 detik | 30 menit | On-Call DBA |
| 🟡 WARNING | Disk > 75% | 2 jam | DBA |
| 🟡 WARNING | Backup > 25 jam lalu | 1 jam | DBA |

### Key Metrics yang Dipantau

```bash
# Replication lag (di primary)
SELECT client_addr,
       extract(epoch from replay_lag) AS lag_seconds
FROM pg_stat_replication;

# Connection usage
SELECT count(*), max_conn,
       round(count(*)::numeric/max_conn*100, 2) AS pct
FROM pg_stat_activity,
     (SELECT setting::numeric AS max_conn FROM pg_settings WHERE name='max_connections') s
GROUP BY max_conn;

# Table bloat (slow query karena bloat)
SELECT schemaname, tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
       n_dead_tup,
       round(n_dead_tup::numeric/GREATEST(n_live_tup,1)*100, 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;

# Long-running queries
SELECT pid, now()-query_start AS duration, query, state
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - interval '5 minutes'
ORDER BY duration DESC;
```

### Health Check Automation

```bash
# Setup cron health check setiap menit
sudo crontab -e

# Health check setiap menit
* * * * * /opt/scripts/db-healthcheck.sh --slack-webhook=$SLACK_WEBHOOK > /dev/null 2>&1

# DR restore test setiap bulan (hari pertama jam 02:00)
0 2 1 * * /opt/scripts/test-restore.sh production >> /var/log/dr-test.log 2>&1
```

---

## Disaster Recovery Playbook

Lihat: [`docs/disaster-recovery-runbook.md`](docs/disaster-recovery-runbook.md)

### Quick Reference DR Matrix

| Skenario | Tindakan | Komponen |
|---|---|---|
| Primary crash | Auto-handled Patroni | etcd + Patroni |
| Planned failover | `patronictl failover` | Patroni |
| Accidental DELETE | pgBackRest PITR | pgBackRest + WAL |
| Disk penuh | Extend EBS + VACUUM | AWS + PostgreSQL |
| etcd cluster gagal | Rebuild etcd | etcd |
| Full region failure | Activate DR region | pgBackRest + Terraform |

---

## Best Practices

### ✅ Database Design

```sql
-- Selalu gunakan partition untuk tabel besar (> 50 juta baris)
CREATE TABLE events (
    id BIGSERIAL,
    event_date DATE NOT NULL,
    user_id BIGINT,
    event_type VARCHAR(50),
    payload JSONB
) PARTITION BY RANGE (event_date);

CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- Selalu ada created_at + updated_at untuk audit
ALTER TABLE orders ADD COLUMN created_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE orders ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();

-- Gunakan trigger untuk auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

### ✅ Connection Management

```python
# Python: Gunakan connection pooling library
import psycopg2.pool

# Jangan buat koneksi baru setiap request!
pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=2,
    maxconn=20,          # Sesuaikan dengan kapasitas pgBouncer
    dsn="postgresql://user:pass@pgbouncer:6432/mydb"
)

# Gunakan context manager
with pool.getconn() as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM orders LIMIT 10")
        results = cur.fetchall()

# Java Spring: Gunakan HikariCP
# spring.datasource.hikari.maximum-pool-size=20
# spring.datasource.hikari.minimum-idle=5
# spring.datasource.hikari.connection-timeout=30000
# spring.datasource.hikari.idle-timeout=600000
```

### ✅ Query Optimization

```sql
-- Selalu EXPLAIN ANALYZE sebelum deploy query baru ke production
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT o.id, o.total, u.email
FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.status = 'pending'
  AND o.created_at > NOW() - INTERVAL '7 days';

-- Buat index untuk foreign key yang sering di-JOIN
CREATE INDEX CONCURRENTLY idx_orders_user_id ON orders(user_id);

-- Partial index untuk filter yang sering digunakan
CREATE INDEX CONCURRENTLY idx_orders_pending ON orders(created_at)
WHERE status = 'pending';

-- Monitor slow queries
SELECT
    calls,
    total_exec_time/calls AS avg_ms,
    rows/calls AS avg_rows,
    left(query, 100) AS query_preview
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_exec_time/calls DESC
LIMIT 20;
```

---

## Pitfalls to Avoid

### ❌ Jangan Lakukan Ini

```bash
# ❌ JANGAN backup hanya sekali seminggu tanpa WAL archive
# Jika ada insiden di hari Sabtu, data 6 hari bisa hilang!
# ✅ Gunakan WAL archiving untuk continuous backup

# ❌ JANGAN restore langsung ke production tanpa test di staging
# Test di environment terpisah dulu!

# ❌ JANGAN gunakan shared_buffers terlalu besar
# PostgreSQL juga butuh filesystem cache
# Rule of thumb: max 25% dari total RAM

# ❌ JANGAN jalankan backup saat peak hours
# Backup intensif I/O, bisa mempengaruhi query performance

# ❌ JANGAN abaikan replication lag yang terus meningkat
# Ini bisa saja gejala disk bottleneck atau network issue

# ❌ JANGAN gunakan max_connections terlalu tinggi
# Lebih baik pakai PgBouncer dengan max_connections moderat
```

```sql
-- ❌ JANGAN gunakan SELECT * di production queries
SELECT * FROM orders;  -- Buruk: fetch semua kolom termasuk yang tidak perlu

-- ✅ Selalu sebutkan kolom yang dibutuhkan
SELECT id, user_id, total, status, created_at FROM orders;

-- ❌ JANGAN buat perubahan skema di jam sibuk tanpa pengamanan
ALTER TABLE users ADD COLUMN last_login TIMESTAMPTZ;  -- Bisa lock lama!

-- ✅ Gunakan operasi yang aman untuk perubahan skema besar
ALTER TABLE users ADD COLUMN last_login TIMESTAMPTZ DEFAULT NULL;
-- Kemudian backfill secara bertahap menggunakan UPDATE batch
```

---

## Troubleshooting

### Problem: Patroni tidak bisa start / cluster tidak ada leader

```bash
# Cek status
systemctl status patroni
journalctl -xu patroni -n 50

# Cek etcd health
etcdctl --endpoints="http://10.0.1.1:2379,http://10.0.1.2:2379,http://10.0.1.3:2379" \
    endpoint health

# Jika etcd bermasalah: restart etcd di semua node
systemctl restart etcd
# Tunggu 30 detik
patronictl -c /etc/patroni/patroni.yml list
```

### Problem: Replication Lag Terus Meningkat

```bash
# Di primary: cek status replication
psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Cek apakah ada query lambat di replica yang memblok
psql -h replica-host -U postgres -c "
    SELECT pid, query, state, wait_event_type, wait_event
    FROM pg_stat_activity
    WHERE state != 'idle'
    ORDER BY duration DESC;"

# Cek disk I/O di replica
iostat -x 5
iotop

# Jika replica terlalu jauh tertinggal: reinstate dengan pg_rewind
patronictl -c /etc/patroni/patroni.yml reinit production-db db-replica-01
```

### Problem: Koneksi Database Penuh

```bash
# Lihat koneksi per aplikasi
psql -U postgres -c "
    SELECT application_name, state, count(*)
    FROM pg_stat_activity
    GROUP BY application_name, state
    ORDER BY count(*) DESC;"

# Kill idle connections yang lama
psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state = 'idle'
      AND query_start < NOW() - INTERVAL '10 minutes'
      AND pid != pg_backend_pid();"

# Naikkan max_connections sementara (tidak perlu restart dengan ALTER SYSTEM)
psql -U postgres -c "ALTER SYSTEM SET max_connections = 300;"
psql -U postgres -c "SELECT pg_reload_conf();"
```

### Problem: Database Lambat / CPU Tinggi

```bash
# Identifikasi query paling berat
psql -U postgres -c "
    SELECT
        calls,
        round(total_exec_time::numeric/calls, 2) AS avg_ms,
        round(total_exec_time::numeric, 2) AS total_ms,
        left(query, 120) AS query
    FROM pg_stat_statements
    WHERE calls > 50
    ORDER BY total_exec_time DESC
    LIMIT 10;"

# Cek apakah ada autovacuum yang berjalan lama
psql -U postgres -c "
    SELECT schemaname, relname, phase, heap_blks_scanned,
           heap_blks_total, time_start
    FROM pg_stat_progress_vacuum;"

# Cek index usage — index mana yang tidak dipakai
psql -U postgres -c "
    SELECT schemaname, tablename, indexname,
           idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
    FROM pg_stat_user_indexes
    WHERE idx_scan = 0 AND schemaname = 'public'
    ORDER BY pg_relation_size(indexrelid) DESC;"
```

---

## Referensi & Tool Recommendations

### 💡 Tools Wajib

| Tool | Fungsi | URL |
|---|---|---|
| **Patroni** | PostgreSQL HA Cluster Manager | https://patroni.readthedocs.io |
| **pgBackRest** | Backup & PITR Enterprise-Grade | https://pgbackrest.org |
| **PgBouncer** | Connection Pooler | https://www.pgbouncer.org |
| **HAProxy** | Load Balancing & Health Check | https://haproxy.org |
| **postgres_exporter** | Prometheus Metrics Exporter | https://github.com/prometheus-community/postgres_exporter |
| **pgBadger** | Log Analysis & Slow Query Report | https://pgbadger.darold.net |
| **pg_activity** | Top-like tool untuk PostgreSQL | https://github.com/dalibo/pg_activity |

### 🛠️ Tools Diagnostic

```bash
# Install tools berguna
sudo apt-get install -y pg-activity pgbadger

# pg_activity: real-time monitoring (seperti 'top' untuk PostgreSQL)
pg_activity -U postgres --dbname=myapp

# pgBadger: analisis log PostgreSQL menjadi HTML report
pgbadger /var/lib/postgresql/16/main/log/*.log \
    -o /var/www/html/pgbadger-report.html \
    --format stderr

# check_postgres.pl: Nagios/monitoring compatible checks
check_postgres.pl --action=bloat --dbname=myapp --warning=20 --critical=50
```

### 📚 Referensi Mendalam

- **[PostgreSQL Documentation](https://www.postgresql.org/docs/current/)** — Referensi official terlengkap
- **[The Art of PostgreSQL](https://theartofpostgresql.com/)** — Buku terbaik untuk SQL expert level
- **[PostgreSQL High Availability Cookbook](https://www.packtpub.com/product/postgresql-high-availability-cookbook)** — Deep dive HA & failover
- **[pgDash Blog](https://pgdash.io/blog/)** — Tutorial monitoring & performance
- **[Citus Blog](https://www.citusdata.com/blog/)** — Advanced PostgreSQL patterns

### SLA Targets Realistis

| Tier | Uptime Target | Max Downtime/Bulan | Arsitektur Minimum |
|---|---|---|---|
| Tier 1 (Best effort) | 99.5% | 3.6 jam | Single node |
| Tier 2 (Standard) | 99.9% | 43 menit | Primary + 1 Replica |
| Tier 3 (High Availability) | 99.99% | 4.3 menit | 3-node Patroni cluster |
| Tier 4 (Critical) | 99.999% | 26 detik | Multi-region active-active |

---

## 🚀 Roadmap Pengembangan

- [ ] **Logical Replication** untuk zero-downtime major version upgrade
- [ ] **pgvector** extension untuk AI/ML embedding storage
- [ ] **Citus** untuk horizontal sharding jika data > 1TB
- [ ] **Distributed SQL** migration path (Yugabyte / CockroachDB)
- [ ] **Automated index advisor** menggunakan pg_qualstats
- [ ] **Database CI/CD** dengan pgTAP untuk database testing

---

*Dibuat: 2026-06-25 | Versi: 1.0 | Maintainer: Platform Engineering Team*
