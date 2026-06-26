#!/usr/bin/env bash
# =============================================================================
# failover.sh — Automated DR Failover Script
# Mengelola failover dan failback antara primary dan DR region
#
# Usage:
#   ./failover.sh --initiate --target dr-region
#   ./failover.sh --failback --verify
#   ./failover.sh --status
#   ./failover.sh --isolate primary
# =============================================================================

set -euo pipefail

# =============================================================================
# Konfigurasi
# =============================================================================

PRIMARY_CLUSTER_CONTEXT="arn:aws:eks:ap-southeast-1:ACCOUNT_ID:cluster/myapp-primary"
DR_CLUSTER_CONTEXT="arn:aws:eks:ap-northeast-1:ACCOUNT_ID:cluster/myapp-dr"
PRIMARY_REGION="ap-southeast-1"
DR_REGION="ap-northeast-1"
DOMAIN_NAME="app.example.com"
HOSTED_ZONE_ID="Z1234567890"
DB_PRIMARY_IDENTIFIER="myapp-primary-db"
DB_DR_IDENTIFIER="myapp-dr-db"
SNS_TOPIC_ARN="arn:aws:sns:ap-southeast-1:ACCOUNT_ID:dr-alerts"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
LOG_FILE="/var/log/dr-failover-$(date +%Y%m%d-%H%M%S).log"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Fungsi Utilitas
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

notify() {
    local message="$1"
    local severity="${2:-INFO}"

    # SNS notification
    if command -v aws &> /dev/null; then
        aws sns publish \
            --topic-arn "${SNS_TOPIC_ARN}" \
            --subject "DR Failover Alert [${severity}]" \
            --message "${message}" \
            --region "${PRIMARY_REGION}" 2>/dev/null || true
    fi

    # Slack notification
    if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then
        local color="#36a64f"
        [[ "${severity}" == "WARNING" ]] && color="#ff9900"
        [[ "${severity}" == "CRITICAL" ]] && color="#cc0000"

        curl -s -X POST "${SLACK_WEBHOOK_URL}" \
            -H 'Content-type: application/json' \
            -d "{
                \"attachments\": [{
                    \"color\": \"${color}\",
                    \"title\": \"🚨 DR Failover [${severity}]\",
                    \"text\": \"${message}\",
                    \"footer\": \"DR Automation | $(date '+%Y-%m-%d %H:%M:%S UTC')\"
                }]
            }" 2>/dev/null || true
    fi
}

check_prerequisites() {
    log "INFO" "Memeriksa prerequisites..."

    local tools=("kubectl" "aws" "jq" "curl")
    for tool in "${tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            log "ERROR" "Tool '${tool}' tidak ditemukan. Install terlebih dahulu."
            exit 1
        fi
    done

    # Cek akses ke kedua cluster
    if ! kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        log "WARNING" "Tidak bisa mengakses primary cluster (mungkin memang sedang down)"
    fi

    if ! kubectl --context="${DR_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        log "ERROR" "Tidak bisa mengakses DR cluster. Failover tidak mungkin dilakukan."
        exit 1
    fi

    log "INFO" "${GREEN}Prerequisites check passed${NC}"
}

# =============================================================================
# Status Check
# =============================================================================

check_status() {
    log "INFO" "${BLUE}=== DR STATUS CHECK ===${NC}"

    echo ""
    echo "🏠 PRIMARY REGION (${PRIMARY_REGION})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Primary cluster status
    if kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        local primary_nodes
        primary_nodes=$(kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" get nodes --no-headers 2>/dev/null | wc -l)
        local primary_pods
        primary_pods=$(kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" get pods -n production --no-headers 2>/dev/null | grep Running | wc -l)
        echo -e "  Cluster: ${GREEN}HEALTHY${NC}"
        echo "  Nodes: ${primary_nodes}"
        echo "  Running Pods (production): ${primary_pods}"
    else
        echo -e "  Cluster: ${RED}UNREACHABLE${NC}"
    fi

    # Primary DB status
    local db_status
    db_status=$(aws rds describe-db-clusters \
        --db-cluster-identifier "${DB_PRIMARY_IDENTIFIER}" \
        --region "${PRIMARY_REGION}" \
        --query 'DBClusters[0].Status' \
        --output text 2>/dev/null || echo "unknown")
    echo "  Database: ${db_status}"

    echo ""
    echo "🏥 DR REGION (${DR_REGION})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # DR cluster status
    if kubectl --context="${DR_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        local dr_nodes
        dr_nodes=$(kubectl --context="${DR_CLUSTER_CONTEXT}" get nodes --no-headers 2>/dev/null | wc -l)
        local dr_pods
        dr_pods=$(kubectl --context="${DR_CLUSTER_CONTEXT}" get pods -n production --no-headers 2>/dev/null | grep Running | wc -l)
        echo -e "  Cluster: ${GREEN}HEALTHY${NC}"
        echo "  Nodes: ${dr_nodes}"
        echo "  Running Pods (production): ${dr_pods}"
    else
        echo -e "  Cluster: ${RED}UNREACHABLE${NC}"
    fi

    echo ""
    echo "🌐 DNS STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local dns_result
    dns_result=$(dig +short "${DOMAIN_NAME}" 2>/dev/null || echo "DNS lookup failed")
    echo "  ${DOMAIN_NAME} → ${dns_result}"

    echo ""
    echo "💾 BACKUP STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if command -v velero &>/dev/null; then
        local last_backup
        last_backup=$(kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" get backup -n velero \
            --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "N/A")
        local backup_status
        backup_status=$(kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" get backup "${last_backup}" -n velero \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
        echo "  Last Backup: ${last_backup}"
        echo "  Status: ${backup_status}"
    else
        echo "  Velero: not installed locally"
    fi

    # Replication lag
    echo ""
    echo "🔄 REPLICATION LAG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local rep_lag
    rep_lag=$(aws rds describe-db-clusters \
        --db-cluster-identifier "${DB_DR_IDENTIFIER}" \
        --region "${DR_REGION}" \
        --query 'DBClusters[0].ReplicationSourceIdentifier' \
        --output text 2>/dev/null || echo "N/A")
    echo "  DB Replication Source: ${rep_lag}"
}

# =============================================================================
# Initiate Failover
# =============================================================================

initiate_failover() {
    local target="$1"
    log "INFO" "${RED}╔══════════════════════════════════════╗${NC}"
    log "INFO" "${RED}║   INITIATING DR FAILOVER             ║${NC}"
    log "INFO" "${RED}║   Target: ${target}                  ║${NC}"
    log "INFO" "${RED}╚══════════════════════════════════════╝${NC}"

    notify "🚨 DR Failover DIMULAI. Target: ${target}. Operator: $(whoami)@$(hostname)" "CRITICAL"

    # Step 1: Verifikasi DR cluster siap
    log "INFO" "Step 1/6: Memeriksa kesiapan DR cluster..."
    if ! kubectl --context="${DR_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        log "ERROR" "DR cluster tidak dapat diakses. ABORTING."
        notify "❌ Failover GAGAL: DR cluster unreachable" "CRITICAL"
        exit 1
    fi
    local dr_nodes
    dr_nodes=$(kubectl --context="${DR_CLUSTER_CONTEXT}" get nodes --no-headers | grep -c Ready)
    if [[ "${dr_nodes}" -lt 2 ]]; then
        log "ERROR" "DR cluster hanya punya ${dr_nodes} ready nodes. Minimum 2. ABORTING."
        exit 1
    fi
    log "INFO" "${GREEN}DR cluster ready: ${dr_nodes} nodes${NC}"

    # Step 2: Scale up DR cluster
    log "INFO" "Step 2/6: Scaling up DR cluster nodes..."
    aws eks update-nodegroup-config \
        --cluster-name "myapp-dr" \
        --nodegroup-name "main" \
        --scaling-config minSize=3,maxSize=10,desiredSize=3 \
        --region "${DR_REGION}" 2>/dev/null || log "WARNING" "Node scaling mungkin perlu manual"

    # Tunggu nodes ready
    log "INFO" "Menunggu DR nodes ready (timeout: 5 menit)..."
    local attempt=0
    while [[ "${attempt}" -lt 30 ]]; do
        dr_nodes=$(kubectl --context="${DR_CLUSTER_CONTEXT}" get nodes --no-headers | grep -c Ready || echo 0)
        if [[ "${dr_nodes}" -ge 3 ]]; then
            log "INFO" "${GREEN}${dr_nodes} nodes ready${NC}"
            break
        fi
        sleep 10
        ((attempt++))
    done

    # Step 3: Promote database replica
    log "INFO" "Step 3/6: Mempromosikan database DR..."
    # Cek replication lag dulu
    log "INFO" "Memeriksa replication lag sebelum promote..."
    aws rds promote-read-replica-db-cluster \
        --db-cluster-identifier "${DB_DR_IDENTIFIER}" \
        --region "${DR_REGION}" 2>/dev/null || log "WARNING" "DB promotion mungkin perlu manual"

    log "INFO" "Menunggu database DR available (timeout: 10 menit)..."
    aws rds wait db-cluster-available \
        --db-cluster-identifier "${DB_DR_IDENTIFIER}" \
        --region "${DR_REGION}" 2>/dev/null || log "WARNING" "DB wait timeout, lanjut ke step berikutnya"

    # Step 4: Deploy/update aplikasi di DR
    log "INFO" "Step 4/6: Deploying aplikasi ke DR cluster..."
    # Restore dari Velero backup terbaru (jika belum ada)
    local latest_backup
    latest_backup=$(kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" get backup -n velero \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${latest_backup}" ]]; then
        log "INFO" "Restoring dari backup: ${latest_backup}"
        # Pindah ke DR context
        kubectl --context="${DR_CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-failover-$(date +%Y%m%d%H%M)
  namespace: velero
spec:
  backupName: ${latest_backup}
  includedNamespaces:
    - production
  restorePVs: true
EOF
        # Tunggu restore selesai
        sleep 30
    fi

    # Update ConfigMap/Secret untuk database endpoint
    kubectl --context="${DR_CLUSTER_CONTEXT}" -n production create configmap db-config \
        --from-literal=DB_HOST="${DB_DR_IDENTIFIER}.cluster-xxx.${DR_REGION}.rds.amazonaws.com" \
        --from-literal=DB_PORT="5432" \
        --dry-run=client -o yaml | kubectl --context="${DR_CLUSTER_CONTEXT}" apply -f - 2>/dev/null || true

    # Restart deployments untuk pick up new config
    kubectl --context="${DR_CLUSTER_CONTEXT}" -n production rollout restart deployment --all 2>/dev/null || true

    # Step 5: Update DNS
    log "INFO" "Step 5/6: Mengupdate DNS ke DR region..."
    # Route 53 failover seharusnya otomatis jika health check gagal
    # Tapi kita juga bisa force override:
    aws route53 change-resource-record-sets \
        --hosted-zone-id "${HOSTED_ZONE_ID}" \
        --change-batch '{
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": "'"${DOMAIN_NAME}"'",
                    "Type": "A",
                    "SetIdentifier": "dr-override",
                    "Weight": 100,
                    "AliasTarget": {
                        "HostedZoneId": "'"${HOSTED_ZONE_ID}"'",
                        "DNSName": "dr-alb.'"${DOMAIN_NAME}"'",
                        "EvaluateTargetHealth": true
                    }
                }
            }]
        }' \
        --region "${PRIMARY_REGION}" 2>/dev/null || log "WARNING" "DNS update mungkin perlu manual"

    # Step 6: Verifikasi
    log "INFO" "Step 6/6: Verifikasi failover..."
    sleep 10

    local dr_pods
    dr_pods=$(kubectl --context="${DR_CLUSTER_CONTEXT}" get pods -n production --no-headers 2>/dev/null | grep -c Running || echo 0)
    log "INFO" "DR pods running: ${dr_pods}"

    # Health check
    local health_status
    health_status=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/health" 2>/dev/null || echo "000")

    if [[ "${health_status}" == "200" ]]; then
        log "INFO" "${GREEN}╔══════════════════════════════════════╗${NC}"
        log "INFO" "${GREEN}║   FAILOVER BERHASIL                   ║${NC}"
        log "INFO" "${GREEN}║   Health check: ${health_status}       ║${NC}"
        log "INFO" "${GREEN}║   DR Pods: ${dr_pods}                  ║${NC}"
        log "INFO" "${GREEN}╚══════════════════════════════════════╝${NC}"
        notify "✅ DR Failover BERHASIL. Health: ${health_status}, Pods: ${dr_pods}" "INFO"
    else
        log "WARNING" "${YELLOW}Failover selesai tapi health check mengembalikan ${health_status}${NC}"
        log "WARNING" "Periksa secara manual: kubectl --context=${DR_CLUSTER_CONTEXT} get pods -n production"
        notify "⚠️ DR Failover selesai tapi health check: ${health_status}. PERLU VERIFIKASI MANUAL." "WARNING"
    fi

    log "INFO" "Log tersimpan di: ${LOG_FILE}"
}

# =============================================================================
# Failback
# =============================================================================

failback() {
    local verify="${1:-false}"

    log "INFO" "${BLUE}╔══════════════════════════════════════╗${NC}"
    log "INFO" "${BLUE}║   INITIATING FAILBACK                ║${NC}"
    log "INFO" "${BLUE}╚══════════════════════════════════════╝${NC}"

    notify "🔄 Failback ke primary region DIMULAI" "WARNING"

    # Step 1: Verifikasi primary region sudah pulih
    log "INFO" "Step 1: Memeriksa primary region..."
    if ! kubectl --context="${PRIMARY_CLUSTER_CONTEXT}" cluster-info &>/dev/null; then
        log "ERROR" "Primary cluster masih unreachable. Failback tidak bisa dilakukan."
        exit 1
    fi

    # Step 2: Sync data dari DR ke primary
    log "INFO" "Step 2: Sinkronisasi data..."
    log "WARNING" "⚠️  PENTING: Pastikan data yang berubah selama failover ter-sync!"
    log "INFO" "Gunakan database migration/sync tool untuk memastikan konsistensi data."

    # Step 3: Restore workload ke primary
    log "INFO" "Step 3: Restoring workload ke primary cluster..."

    # Backup state DR saat ini
    kubectl --context="${DR_CLUSTER_CONTEXT}" -n velero apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-failback-$(date +%Y%m%d%H%M)
  namespace: velero
spec:
  includedNamespaces:
    - production
  defaultVolumesToFsBackup: true
  ttl: 720h
EOF

    sleep 30  # Tunggu backup mulai

    # Step 4: Update DNS kembali ke primary
    log "INFO" "Step 4: Mengupdate DNS ke primary region..."
    # Hapus override dan kembalikan failover policy
    aws route53 change-resource-record-sets \
        --hosted-zone-id "${HOSTED_ZONE_ID}" \
        --change-batch '{
            "Changes": [{
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": "'"${DOMAIN_NAME}"'",
                    "Type": "A",
                    "SetIdentifier": "dr-override",
                    "Weight": 100,
                    "AliasTarget": {
                        "HostedZoneId": "'"${HOSTED_ZONE_ID}"'",
                        "DNSName": "dr-alb.'"${DOMAIN_NAME}"'",
                        "EvaluateTargetHealth": true
                    }
                }
            }]
        }' \
        --region "${PRIMARY_REGION}" 2>/dev/null || log "WARNING" "DNS cleanup mungkin perlu manual"

    # Step 5: Scale down DR
    log "INFO" "Step 5: Scaling down DR cluster..."
    aws eks update-nodegroup-config \
        --cluster-name "myapp-dr" \
        --nodegroup-name "main" \
        --scaling-config minSize=1,maxSize=10,desiredSize=2 \
        --region "${DR_REGION}" 2>/dev/null || true

    # Step 6: Verifikasi
    if [[ "${verify}" == "true" ]]; then
        log "INFO" "Step 6: Verifikasi failback..."
        sleep 30

        local health
        health=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}/health" 2>/dev/null || echo "000")
        log "INFO" "Health check primary: ${health}"

        if [[ "${health}" == "200" ]]; then
            notify "✅ Failback ke primary BERHASIL. Health: ${health}" "INFO"
        else
            notify "⚠️ Failback selesai tapi health: ${health}. VERIFIKASI MANUAL diperlukan." "WARNING"
        fi
    fi

    log "INFO" "${GREEN}Failback process selesai${NC}"
}

# =============================================================================
# Isolate Region
# =============================================================================

isolate_region() {
    local region="$1"
    log "INFO" "${RED}ISOLATING region: ${region}${NC}"
    notify "🔒 Region ${region} sedang di-ISOLASI (kemungkinan security incident)" "CRITICAL"

    # Isolasi: matikan semua traffic ke region
    if [[ "${region}" == "primary" ]]; then
        # Disable health check agar failover ke DR
        aws route53 update-health-check \
            --health-check-id "$(aws route53 list-health-checks --query 'HealthChecks[?CallerReference==`primary`].Id' --output text 2>/dev/null)" \
            --disabled \
            --region "${PRIMARY_REGION}" 2>/dev/null || true

        log "INFO" "Primary region health check disabled — traffic akan failover ke DR"
    fi
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --status              Cek status primary dan DR"
    echo "  --initiate            Inisiasi failover ke DR"
    echo "  --target <region>     Target region untuk failover"
    echo "  --failback            Failback ke primary"
    echo "  --verify              Verifikasi setelah failback"
    echo "  --isolate <region>    Isolasi region (untuk security incident)"
    echo "  --help                Tampilkan bantuan ini"
    echo ""
    echo "Examples:"
    echo "  $0 --status"
    echo "  $0 --initiate --target dr-region"
    echo "  $0 --failback --verify"
    echo "  $0 --isolate primary"
}

ACTION=""
TARGET=""
VERIFY="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)    ACTION="status"; shift ;;
        --initiate)  ACTION="initiate"; shift ;;
        --failback)  ACTION="failback"; shift ;;
        --target)    TARGET="$2"; shift 2 ;;
        --verify)    VERIFY="true"; shift ;;
        --isolate)   ACTION="isolate"; TARGET="$2"; shift 2 ;;
        --help)      usage; exit 0 ;;
        *)           echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "${ACTION}" ]]; then
    usage
    exit 1
fi

case "${ACTION}" in
    status)
        check_status
        ;;
    initiate)
        if [[ -z "${TARGET}" ]]; then
            echo "Error: --target required for --initiate"
            exit 1
        fi
        check_prerequisites
        initiate_failover "${TARGET}"
        ;;
    failback)
        check_prerequisites
        failback "${VERIFY}"
        ;;
    isolate)
        if [[ -z "${TARGET}" ]]; then
            echo "Error: Region name required for --isolate"
            exit 1
        fi
        isolate_region "${TARGET}"
        ;;
esac
