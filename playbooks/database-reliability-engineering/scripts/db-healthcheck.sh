#!/usr/bin/env bash
# =============================================================================
# Database Health Check Script
# Jalankan setiap menit via cron untuk monitoring awal
# Kirim notifikasi ke Slack/PagerDuty jika ada masalah
# Usage: ./db-healthcheck.sh [--slack-webhook URL] [--pagerduty-key KEY]
# =============================================================================
set -euo pipefail

# =============================================================================
# Konfigurasi
# =============================================================================
PATRONI_CONFIG="/etc/patroni/patroni.yml"
PATRONICTL_CMD="patronictl -c ${PATRONI_CONFIG}"
PSQL_CMD="psql -U postgres -t -A -c"
PGBACKREST_STANZA="production"
LOG_FILE="/var/log/db-healthcheck.log"

# Thresholds
REPLICATION_LAG_WARNING=30   # detik
REPLICATION_LAG_CRITICAL=300
CONNECTION_PCT_WARNING=70    # persen
CONNECTION_PCT_CRITICAL=85
DISK_PCT_WARNING=75          # persen dipakai
DISK_PCT_CRITICAL=90
BACKUP_STALE_HOURS=25        # jam

# Slack/PagerDuty (isi jika diinginkan)
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
PAGERDUTY_KEY="${PAGERDUTY_KEY:-}"

# Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "[$(timestamp)] ${GREEN}OK${NC}    $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "[$(timestamp)] ${YELLOW}WARN${NC}  $*" | tee -a "$LOG_FILE"; }
log_crit() { echo -e "[$(timestamp)] ${RED}CRIT${NC}  $*" | tee -a "$LOG_FILE"; }

ALERT_MESSAGES=()
CRITICAL_COUNT=0
WARNING_COUNT=0

add_alert() {
    local level="$1"
    local message="$2"
    ALERT_MESSAGES+=("[$level] $message")
    if [[ "$level" == "CRITICAL" ]]; then
        ((CRITICAL_COUNT++))
        log_crit "$message"
    else
        ((WARNING_COUNT++))
        log_warn "$message"
    fi
}

send_slack() {
    local message="$1"
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            --data "{\"text\": \"$message\"}" \
            &>/dev/null || true
    fi
}

send_pagerduty() {
    local summary="$1"
    local severity="$2"
    if [[ -n "$PAGERDUTY_KEY" ]]; then
        curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
            -H 'Content-Type: application/json' \
            --data "{
                \"routing_key\": \"$PAGERDUTY_KEY\",
                \"event_action\": \"trigger\",
                \"payload\": {
                    \"summary\": \"$summary\",
                    \"severity\": \"$severity\",
                    \"source\": \"$(hostname)\"
                }
            }" &>/dev/null || true
    fi
}

# =============================================================================
# CHECK 1: Patroni Cluster Status
# =============================================================================
check_patroni_cluster() {
    log "Checking Patroni cluster status..."

    if ! command -v patronictl &>/dev/null; then
        log_warn "patronictl tidak ditemukan, skip check"
        return
    fi

    # Cek apakah ada leader
    local leader_count
    leader_count=$(${PATRONICTL_CMD} list --format json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for m in d if m.get('Role')=='Leader'))" 2>/dev/null || echo "0")

    if [[ "$leader_count" -eq 0 ]]; then
        add_alert "CRITICAL" "Tidak ada Patroni leader! Split-brain atau semua node down!"
    else
        log_ok "Patroni cluster memiliki leader aktif"
    fi

    # Cek member yang down
    local down_members
    down_members=$(${PATRONICTL_CMD} list --format json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print([m['Member'] for m in d if m.get('State')!='running'])" 2>/dev/null || echo "[]")

    if [[ "$down_members" != "[]" ]]; then
        add_alert "CRITICAL" "Member Patroni dalam kondisi tidak running: $down_members"
    fi
}

# =============================================================================
# CHECK 2: PostgreSQL Connectivity
# =============================================================================
check_postgresql_connectivity() {
    log "Checking PostgreSQL connectivity..."

    if ${PSQL_CMD} "SELECT 1" &>/dev/null; then
        log_ok "PostgreSQL dapat diakses"
    else
        add_alert "CRITICAL" "Tidak dapat terkoneksi ke PostgreSQL lokal!"
        return 1
    fi
}

# =============================================================================
# CHECK 3: Replication Status (hanya di primary)
# =============================================================================
check_replication() {
    log "Checking replication status..."

    local is_primary
    is_primary=$(${PSQL_CMD} "SELECT NOT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')

    if [[ "$is_primary" != "t" ]]; then
        log "Node ini adalah replica, skip replication check dari primary"
        return
    fi

    # Cek jumlah replicas yang terkoneksi
    local replica_count
    replica_count=$(${PSQL_CMD} "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

    if [[ "$replica_count" -eq 0 ]]; then
        add_alert "WARNING" "Tidak ada replica yang terkoneksi ke primary!"
    else
        log_ok "Jumlah replica aktif: $replica_count"
    fi

    # Cek replication lag per replica
    while IFS='|' read -r client_addr lag_seconds; do
        lag_seconds=$(echo "$lag_seconds" | tr -d ' ')
        if [[ -z "$lag_seconds" || "$lag_seconds" == "NULL" ]]; then
            continue
        fi

        if (( $(echo "$lag_seconds > $REPLICATION_LAG_CRITICAL" | bc -l) )); then
            add_alert "CRITICAL" "Replication lag CRITICAL dari $client_addr: ${lag_seconds}s (threshold: ${REPLICATION_LAG_CRITICAL}s)"
        elif (( $(echo "$lag_seconds > $REPLICATION_LAG_WARNING" | bc -l) )); then
            add_alert "WARNING" "Replication lag WARNING dari $client_addr: ${lag_seconds}s (threshold: ${REPLICATION_LAG_WARNING}s)"
        else
            log_ok "Replication lag $client_addr: ${lag_seconds}s (OK)"
        fi
    done < <(${PSQL_CMD} "
        SELECT client_addr,
               EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
        FROM pg_stat_replication;" 2>/dev/null || true)
}

# =============================================================================
# CHECK 4: Connection Count
# =============================================================================
check_connections() {
    log "Checking connection counts..."

    local result
    result=$(${PSQL_CMD} "
        SELECT
            count(*) AS current,
            max_conn,
            round(count(*)::numeric / max_conn * 100, 2) AS pct
        FROM pg_stat_activity,
             (SELECT setting::numeric AS max_conn FROM pg_settings WHERE name='max_connections') s
        GROUP BY max_conn;" 2>/dev/null || echo "")

    if [[ -z "$result" ]]; then
        log_warn "Tidak bisa mengambil data koneksi"
        return
    fi

    IFS='|' read -r current max_conn pct <<< "$result"
    pct=$(echo "$pct" | tr -d ' ')

    if (( $(echo "$pct > $CONNECTION_PCT_CRITICAL" | bc -l) )); then
        add_alert "CRITICAL" "Koneksi hampir penuh! ${current}/${max_conn} (${pct}%)"
    elif (( $(echo "$pct > $CONNECTION_PCT_WARNING" | bc -l) )); then
        add_alert "WARNING" "Koneksi tinggi: ${current}/${max_conn} (${pct}%)"
    else
        log_ok "Koneksi normal: ${current}/${max_conn} (${pct}%)"
    fi
}

# =============================================================================
# CHECK 5: Long-running Transactions
# =============================================================================
check_long_transactions() {
    log "Checking long-running transactions..."

    local long_txn_count
    long_txn_count=$(${PSQL_CMD} "
        SELECT count(*)
        FROM pg_stat_activity
        WHERE state IN ('active', 'idle in transaction')
          AND xact_start IS NOT NULL
          AND extract(epoch from (now() - xact_start)) > 300;" 2>/dev/null | tr -d ' ')

    if [[ -n "$long_txn_count" && "$long_txn_count" -gt 0 ]]; then
        add_alert "WARNING" "Terdapat ${long_txn_count} transaksi yang berjalan > 5 menit!"
    else
        log_ok "Tidak ada long-running transaction"
    fi
}

# =============================================================================
# CHECK 6: Disk Space
# =============================================================================
check_disk_space() {
    log "Checking disk space..."

    local data_dir="/var/lib/postgresql"

    if [[ ! -d "$data_dir" ]]; then
        log_warn "Data directory $data_dir tidak ditemukan"
        return
    fi

    local disk_pct
    disk_pct=$(df "$data_dir" | awk 'NR==2 {gsub("%",""); print $5}')

    if [[ "$disk_pct" -ge "$DISK_PCT_CRITICAL" ]]; then
        add_alert "CRITICAL" "Disk hampir penuh! ${disk_pct}% digunakan di $data_dir"
    elif [[ "$disk_pct" -ge "$DISK_PCT_WARNING" ]]; then
        add_alert "WARNING" "Disk mulai penuh: ${disk_pct}% digunakan di $data_dir"
    else
        log_ok "Disk space OK: ${disk_pct}% digunakan"
    fi
}

# =============================================================================
# CHECK 7: Backup Status
# =============================================================================
check_backup_status() {
    log "Checking backup status..."

    if ! command -v pgbackrest &>/dev/null; then
        log_warn "pgbackrest tidak ditemukan, skip check"
        return
    fi

    local backup_info
    backup_info=$(pgbackrest --stanza="$PGBACKREST_STANZA" info --output=json 2>/dev/null || echo "[]")

    local last_backup_epoch
    last_backup_epoch=$(echo "$backup_info" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data and data[0].get('backup'):
    backups = data[0]['backup']
    if backups:
        print(backups[-1]['timestamp']['stop'])
    else:
        print(0)
else:
    print(0)
" 2>/dev/null || echo "0")

    if [[ "$last_backup_epoch" -eq 0 ]]; then
        add_alert "CRITICAL" "Tidak ada backup yang ditemukan untuk stanza $PGBACKREST_STANZA!"
        return
    fi

    local current_epoch
    current_epoch=$(date +%s)
    local hours_since=$(( (current_epoch - last_backup_epoch) / 3600 ))

    if [[ "$hours_since" -ge "$BACKUP_STALE_HOURS" ]]; then
        add_alert "CRITICAL" "Backup terakhir ${hours_since} jam yang lalu (threshold: ${BACKUP_STALE_HOURS} jam)!"
    else
        log_ok "Backup terakhir ${hours_since} jam yang lalu (OK)"
    fi
}

# =============================================================================
# CHECK 8: Deadlock Rate
# =============================================================================
check_deadlocks() {
    log "Checking deadlock rate..."

    # Gunakan pg_stat_database untuk cek deadlock total
    local deadlock_count
    deadlock_count=$(${PSQL_CMD} "
        SELECT COALESCE(sum(deadlocks), 0)
        FROM pg_stat_database
        WHERE datname NOT IN ('template0', 'template1');" 2>/dev/null | tr -d ' ')

    # Simpan ke file untuk dibandingkan dengan run sebelumnya
    local deadlock_file="/tmp/pg_deadlock_count"
    local prev_count=0

    if [[ -f "$deadlock_file" ]]; then
        prev_count=$(cat "$deadlock_file")
    fi

    echo "$deadlock_count" > "$deadlock_file"

    local new_deadlocks=$(( deadlock_count - prev_count ))
    if [[ "$new_deadlocks" -gt 10 ]]; then
        add_alert "WARNING" "Deadlock rate tinggi: ${new_deadlocks} deadlock baru sejak check terakhir"
    else
        log_ok "Deadlock rate normal: ${new_deadlocks} baru"
    fi
}

# =============================================================================
# Kirim notifikasi
# =============================================================================
send_notifications() {
    if [[ "${#ALERT_MESSAGES[@]}" -eq 0 ]]; then
        log_ok "Semua check PASS — Database sehat!"
        return
    fi

    local summary="🚨 Database Alert $(hostname) | CRITICAL: $CRITICAL_COUNT | WARNING: $WARNING_COUNT"
    local details
    details=$(printf '%s\n' "${ALERT_MESSAGES[@]}")

    log ""
    log "=== ALERTS SUMMARY ==="
    printf '%s\n' "${ALERT_MESSAGES[@]}"

    # Kirim ke Slack
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        local slack_msg
        slack_msg="${summary}\n\`\`\`${details}\`\`\`"
        send_slack "$slack_msg"
    fi

    # Kirim ke PagerDuty jika ada critical
    if [[ "$CRITICAL_COUNT" -gt 0 && -n "$PAGERDUTY_KEY" ]]; then
        send_pagerduty "$summary" "critical"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log "======================================================"
    log "Database Health Check dimulai: $(hostname)"
    log "======================================================"

    check_patroni_cluster
    check_postgresql_connectivity && {
        check_replication
        check_connections
        check_long_transactions
        check_deadlocks
    }
    check_disk_space
    check_backup_status
    send_notifications

    log "======================================================"
    log "Health check selesai: CRITICAL=$CRITICAL_COUNT WARNING=$WARNING_COUNT"
    log "======================================================"

    # Exit code: 2 jika critical, 1 jika warning, 0 jika OK
    if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
        exit 2
    elif [[ "$WARNING_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
