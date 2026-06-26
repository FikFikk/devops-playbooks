#!/usr/bin/env bash
# =============================================================================
# test-restore.sh — Automated Backup Restore Testing
# Menjalankan test restore dari Velero backup secara berkala
# untuk memastikan backup benar-benar bisa di-restore
#
# Jalankan via cron: 0 6 * * 6 /opt/scripts/test-restore.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# Konfigurasi
# =============================================================================

CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-arn:aws:eks:ap-southeast-1:ACCOUNT_ID:cluster/myapp-primary}"
RESTORE_NAMESPACE="restore-test-$(date +%Y%m%d)"
TEST_TIMEOUT=600  # 10 menit
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:ap-southeast-1:ACCOUNT_ID:dr-alerts}"
LOG_FILE="/var/log/restore-test-$(date +%Y%m%d).log"

# =============================================================================
# Fungsi Utilitas
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

notify_result() {
    local status="$1"
    local details="$2"
    local emoji="✅"
    local severity="INFO"

    if [[ "${status}" == "FAIL" ]]; then
        emoji="❌"
        severity="CRITICAL"
    fi

    local message="${emoji} Backup Restore Test [${status}] — $(date '+%Y-%m-%d')

${details}

Cluster: ${CLUSTER_CONTEXT}
Namespace: ${RESTORE_NAMESPACE}
Log: ${LOG_FILE}"

    # SNS
    if command -v aws &>/dev/null; then
        aws sns publish \
            --topic-arn "${SNS_TOPIC_ARN}" \
            --subject "Restore Test ${status}" \
            --message "${message}" 2>/dev/null || true
    fi

    # Slack
    if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then
        local color="#36a64f"
        [[ "${status}" == "FAIL" ]] && color="#cc0000"

        curl -s -X POST "${SLACK_WEBHOOK_URL}" \
            -H 'Content-type: application/json' \
            -d "{
                \"attachments\": [{
                    \"color\": \"${color}\",
                    \"title\": \"${emoji} Restore Test ${status}\",
                    \"text\": \"${details}\",
                    \"footer\": \"Automated Restore Test | $(date '+%Y-%m-%d %H:%M:%S')\"
                }]
            }" 2>/dev/null || true
    fi
}

cleanup() {
    log "Cleaning up test namespace: ${RESTORE_NAMESPACE}"
    kubectl --context="${CLUSTER_CONTEXT}" delete namespace "${RESTORE_NAMESPACE}" --ignore-not-found --timeout=120s 2>/dev/null || true

    # Hapus restore object
    kubectl --context="${CLUSTER_CONTEXT}" -n velero delete restore "restore-test-$(date +%Y%m%d)" --ignore-not-found 2>/dev/null || true
}

# Cleanup on exit
trap cleanup EXIT

# =============================================================================
# Main
# =============================================================================

main() {
    log "════════════════════════════════════════"
    log "AUTOMATED BACKUP RESTORE TEST"
    log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    log "════════════════════════════════════════"

    # Step 1: Temukan backup terbaru
    log "Step 1: Mencari backup terbaru..."
    local latest_backup
    latest_backup=$(kubectl --context="${CLUSTER_CONTEXT}" get backup -n velero \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

    if [[ -z "${latest_backup}" ]]; then
        log "ERROR: Tidak ada backup ditemukan!"
        notify_result "FAIL" "Tidak ada backup ditemukan di cluster"
        exit 1
    fi

    local backup_phase
    backup_phase=$(kubectl --context="${CLUSTER_CONTEXT}" get backup "${latest_backup}" -n velero \
        -o jsonpath='{.status.phase}' 2>/dev/null)

    log "Latest backup: ${latest_backup} (status: ${backup_phase})"

    if [[ "${backup_phase}" != "Completed" ]]; then
        log "ERROR: Backup terakhir tidak Completed (${backup_phase})"
        notify_result "FAIL" "Backup '${latest_backup}' status: ${backup_phase}, bukan Completed"
        exit 1
    fi

    # Step 2: Buat namespace untuk test restore
    log "Step 2: Membuat test namespace..."
    kubectl --context="${CLUSTER_CONTEXT}" create namespace "${RESTORE_NAMESPACE}" 2>/dev/null || true
    kubectl --context="${CLUSTER_CONTEXT}" label namespace "${RESTORE_NAMESPACE}" \
        purpose=restore-test \
        auto-cleanup=true 2>/dev/null || true

    # Step 3: Jalankan restore
    log "Step 3: Menjalankan restore..."
    local restore_name="restore-test-$(date +%Y%m%d)"

    kubectl --context="${CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: velero
spec:
  backupName: ${latest_backup}
  includedNamespaces:
    - production
  namespaceMapping:
    production: ${RESTORE_NAMESPACE}
  restorePVs: false
  preserveNodePorts: false
EOF

    # Step 4: Tunggu restore selesai
    log "Step 4: Menunggu restore selesai (timeout: ${TEST_TIMEOUT}s)..."
    local start_time
    start_time=$(date +%s)
    local restore_phase="InProgress"

    while [[ "${restore_phase}" == "InProgress" || "${restore_phase}" == "New" ]]; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$(( current_time - start_time ))

        if [[ "${elapsed}" -gt "${TEST_TIMEOUT}" ]]; then
            log "ERROR: Restore timeout setelah ${TEST_TIMEOUT} detik"
            notify_result "FAIL" "Restore '${restore_name}' timeout setelah ${TEST_TIMEOUT}s"
            exit 1
        fi

        sleep 10
        restore_phase=$(kubectl --context="${CLUSTER_CONTEXT}" get restore "${restore_name}" -n velero \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        log "  Restore phase: ${restore_phase} (elapsed: ${elapsed}s)"
    done

    # Step 5: Verifikasi restore
    log "Step 5: Verifikasi restore..."

    if [[ "${restore_phase}" != "Completed" && "${restore_phase}" != "PartiallyFailed" ]]; then
        log "ERROR: Restore gagal dengan status: ${restore_phase}"
        local restore_errors
        restore_errors=$(kubectl --context="${CLUSTER_CONTEXT}" get restore "${restore_name}" -n velero \
            -o jsonpath='{.status.errors}' 2>/dev/null || echo "unknown")
        notify_result "FAIL" "Restore '${restore_name}' gagal: ${restore_phase}. Errors: ${restore_errors}"
        exit 1
    fi

    # Cek jumlah resource yang ter-restore
    local restored_pods
    restored_pods=$(kubectl --context="${CLUSTER_CONTEXT}" get pods -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    local restored_services
    restored_services=$(kubectl --context="${CLUSTER_CONTEXT}" get services -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    local restored_configmaps
    restored_configmaps=$(kubectl --context="${CLUSTER_CONTEXT}" get configmaps -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    local restored_secrets
    restored_secrets=$(kubectl --context="${CLUSTER_CONTEXT}" get secrets -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)

    # Cek apakah pod bisa running
    log "Menunggu pod running..."
    sleep 30
    local running_pods
    running_pods=$(kubectl --context="${CLUSTER_CONTEXT}" get pods -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | grep -c Running || echo 0)
    local total_pods
    total_pods=$(kubectl --context="${CLUSTER_CONTEXT}" get pods -n "${RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)

    local end_time
    end_time=$(date +%s)
    local total_duration=$(( end_time - start_time ))

    # Step 6: Report
    local details="Backup: ${latest_backup}
Restore: ${restore_name}
Status: ${restore_phase}
Duration: ${total_duration}s

Resources Restored:
  Pods: ${restored_pods} (${running_pods} running / ${total_pods} total)
  Services: ${restored_services}
  ConfigMaps: ${restored_configmaps}
  Secrets: ${restored_secrets}

RPO Actual: $(kubectl --context="${CLUSTER_CONTEXT}" get backup "${latest_backup}" -n velero \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo 'N/A')"

    if [[ "${restore_phase}" == "Completed" && "${running_pods}" -gt 0 ]]; then
        log "═══════════════════════════════════"
        log "✅ RESTORE TEST PASSED"
        log "═══════════════════════════════════"
        log "${details}"
        notify_result "PASS" "${details}"
    elif [[ "${restore_phase}" == "PartiallyFailed" ]]; then
        log "═══════════════════════════════════"
        log "⚠️  RESTORE TEST PARTIALLY PASSED"
        log "═══════════════════════════════════"
        log "${details}"
        notify_result "FAIL" "Partial restore: ${details}"
    else
        log "═══════════════════════════════════"
        log "❌ RESTORE TEST FAILED"
        log "═══════════════════════════════════"
        log "${details}"
        notify_result "FAIL" "${details}"
        exit 1
    fi
}

main "$@"
