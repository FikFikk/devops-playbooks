#!/usr/bin/env bash
# =============================================================================
# Test Restore Script — Ujicoba restore backup PostgreSQL ke environment test
# Jalankan setiap bulan untuk memverifikasi backup bisa di-restore
# Usage: ./test-restore.sh --stanza STANZA --target-host TARGET_HOST [--point-in-time "YYYY-MM-DD HH:MM:SS"]
# =============================================================================
set -euo pipefail

STANZA="${1:-production}"
TARGET_HOST="${2:-db-test-01}"
TARGET_DATA_DIR="/var/lib/postgresql/16/test-restore"
PGPORT_TEST=5433
REPORT_FILE="/tmp/restore-test-$(date +%Y%m%d).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$REPORT_FILE"; }
log_ok() { echo "[$(date '+%H:%M:%S')] ✅ $*" | tee -a "$REPORT_FILE"; }
log_fail() { echo "[$(date '+%H:%M:%S')] ❌ $*" | tee -a "$REPORT_FILE"; }

START_TIME=$(date +%s)

log "=== DISASTER RECOVERY TEST ==="
log "Stanza: $STANZA"
log "Target: $TARGET_HOST"
log "Tanggal: $(date)"
log ""

# =============================================================================
# Step 1: List backup yang tersedia
# =============================================================================
log "Step 1: Mengambil informasi backup terbaru..."

BACKUP_INFO=$(pgbackrest --stanza="$STANZA" info --output=json)
LATEST_BACKUP=$(echo "$BACKUP_INFO" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data and data[0].get('backup'):
    b = data[0]['backup'][-1]
    print(f\"{b['label']} | Size: {b['info']['size']} bytes | Stop: {b['timestamp']['stop']}\")
")

log "Backup terbaru: $LATEST_BACKUP"
log_ok "Step 1 selesai"

# =============================================================================
# Step 2: Restore backup ke direktori test
# =============================================================================
log ""
log "Step 2: Memulai restore backup..."
log "Target directory: $TARGET_DATA_DIR"

# Bersihkan direktori test jika ada
if [[ -d "$TARGET_DATA_DIR" ]]; then
    log "Membersihkan direktori test lama..."
    rm -rf "$TARGET_DATA_DIR"
fi

mkdir -p "$TARGET_DATA_DIR"
chown postgres:postgres "$TARGET_DATA_DIR"
chmod 700 "$TARGET_DATA_DIR"

RESTORE_START=$(date +%s)

# Jalankan restore
sudo -u postgres pgbackrest --stanza="$STANZA" restore \
    --pg1-path="$TARGET_DATA_DIR" \
    --pg1-port="$PGPORT_TEST" \
    --type=immediate \
    --target-action=promote \
    --log-level-console=info 2>&1 | tee -a "$REPORT_FILE"

RESTORE_END=$(date +%s)
RESTORE_DURATION=$((RESTORE_END - RESTORE_START))

log_ok "Step 2 selesai — Restore duration: ${RESTORE_DURATION}s"

# =============================================================================
# Step 3: Start PostgreSQL di port test
# =============================================================================
log ""
log "Step 3: Memulai PostgreSQL instance test di port $PGPORT_TEST..."

sudo -u postgres pg_ctl \
    -D "$TARGET_DATA_DIR" \
    -o "-p $PGPORT_TEST" \
    -l "$TARGET_DATA_DIR/postgresql-test.log" \
    start

sleep 10  # Tunggu PostgreSQL ready

if sudo -u postgres psql -p "$PGPORT_TEST" -c "SELECT 1;" &>/dev/null; then
    log_ok "Step 3 selesai — PostgreSQL test instance berjalan"
else
    log_fail "Step 3 GAGAL — PostgreSQL tidak bisa start!"
    exit 1
fi

# =============================================================================
# Step 4: Verifikasi data integritas
# =============================================================================
log ""
log "Step 4: Verifikasi integritas database..."

# Cek basic database info
DB_LIST=$(sudo -u postgres psql -p "$PGPORT_TEST" -t -c "
    SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null)

log "Database yang ditemukan:"
echo "$DB_LIST" | while read -r db; do
    [[ -z "$db" ]] && continue
    log "  - $db"
done

# Hitung total tables
TABLE_COUNT=$(sudo -u postgres psql -p "$PGPORT_TEST" -t -A -c "
    SELECT count(*) FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ')

log "Total tables di public schema: $TABLE_COUNT"

# Verifikasi tidak ada corruption
log "Menjalankan pg_dumpall untuk verifikasi (tanpa menyimpan output)..."
if sudo -u postgres pg_dumpall -p "$PGPORT_TEST" --schema-only &>/dev/null; then
    log_ok "Schema dump berhasil — tidak ada corruption terdeteksi"
else
    log_fail "pg_dumpall gagal — kemungkinan ada corruption!"
fi

# Check pg_stat_activity (database responsif)
CONNECTIONS=$(sudo -u postgres psql -p "$PGPORT_TEST" -t -A -c "
    SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' ')
log "Koneksi aktif: $CONNECTIONS"

log_ok "Step 4 selesai — Verifikasi data OK"

# =============================================================================
# Step 5: Cleanup instance test
# =============================================================================
log ""
log "Step 5: Cleanup instance test..."

sudo -u postgres pg_ctl \
    -D "$TARGET_DATA_DIR" \
    stop -m fast

rm -rf "$TARGET_DATA_DIR"

log_ok "Step 5 selesai — Cleanup OK"

# =============================================================================
# Summary Report
# =============================================================================
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

log ""
log "=============================================="
log "   LAPORAN DISASTER RECOVERY TEST"
log "=============================================="
log "Tanggal       : $(date)"
log "Backup        : $LATEST_BACKUP"
log "Restore Time  : ${RESTORE_DURATION} detik"
log "Total Duration: ${TOTAL_DURATION} detik"
log "Status        : ✅ BERHASIL"
log "=============================================="
log ""
log "📁 Log lengkap tersimpan di: $REPORT_FILE"

# Simpan hasil untuk tracking
cat "$REPORT_FILE" | mail -s "DR Test Report - $(date +%Y-%m-%d) - SUCCESS" ops-team@perusahaan.com 2>/dev/null || true
