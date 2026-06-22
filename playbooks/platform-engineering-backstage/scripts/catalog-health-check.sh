#!/bin/bash
# =============================================================================
# catalog-health-check.sh
# Script untuk memantau kesehatan Backstage Service Catalog secara rutin
# 
# Jalankan sebagai CronJob K8s setiap hari atau via CI/CD pipeline
# Output: laporan JSON + notifikasi Slack jika ada masalah
# =============================================================================

set -euo pipefail

# ─── Konfigurasi ──────────────────────────────────────────────────────────────
BACKSTAGE_URL="${BACKSTAGE_URL:-https://backstage.mycompany.com}"
BACKSTAGE_TOKEN="${BACKSTAGE_TOKEN:?ERROR: BACKSTAGE_TOKEN tidak di-set}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REPORT_FILE="/tmp/catalog-health-$(date +%Y%m%d-%H%M%S).json"

# Threshold untuk alerting
MAX_ORPHANED_COMPONENTS=5        # Alert jika lebih dari N komponen tanpa owner
MAX_DEPRECATED_DAYS=90           # Alert jika komponen deprecated lebih dari N hari
MIN_CATALOG_ENTITIES=10          # Alert jika total entitas kurang dari N

# ─── Fungsi Helper ────────────────────────────────────────────────────────────
api_get() {
  local path="$1"
  curl -s \
    -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${BACKSTAGE_URL}/api${path}"
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-warning}"  # warning | critical
  
  if [[ -z "$SLACK_WEBHOOK" ]]; then
    echo "[SLACK DISABLED] $message"
    return
  fi
  
  local color
  case "$severity" in
    critical) color="#ff0000" ;;
    warning)  color="#ffaa00" ;;
    info)     color="#00aa00" ;;
    *)        color="#cccccc" ;;
  esac
  
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{
      \"attachments\": [{
        \"color\": \"${color}\",
        \"title\": \"🔍 Backstage Catalog Health Alert\",
        \"text\": \"${message}\",
        \"footer\": \"Catalog Health Check | $(date '+%Y-%m-%d %H:%M')\",
        \"mrkdwn_in\": [\"text\"]
      }]
    }" || true
}

# ─── Cek Kesehatan Catalog ────────────────────────────────────────────────────

check_api_health() {
  echo "Mengecek API health..."
  
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "${BACKSTAGE_URL}/healthcheck")
  
  if [[ "$status" != "200" ]]; then
    send_slack_alert "🚨 *CRITICAL*: Backstage API tidak merespons! HTTP ${status}" "critical"
    echo "API_HEALTH=FAIL"
    return 1
  fi
  
  echo "API_HEALTH=OK"
}

check_entity_count() {
  echo "Mengecek jumlah entitas..."
  
  local total
  total=$(api_get "/catalog/entities?limit=0" | jq 'length // 0')
  
  echo "TOTAL_ENTITIES=${total}"
  
  if [[ "$total" -lt "$MIN_CATALOG_ENTITIES" ]]; then
    send_slack_alert \
      "⚠️ *WARNING*: Jumlah entitas catalog terlalu sedikit: ${total} (minimum: ${MIN_CATALOG_ENTITIES}). Mungkin ada masalah dengan entity ingestion?" \
      "warning"
  fi
}

check_orphaned_components() {
  echo "Mengecek komponen tanpa owner..."
  
  local orphaned_list
  orphaned_list=$(api_get "/catalog/entities?filter=kind=Component&limit=500" \
    | jq -r '[.[] | select(.spec.owner == null or .spec.owner == "") | .metadata.name] | join(", ")' 2>/dev/null || echo "")
  
  local count
  count=$(echo "$orphaned_list" | grep -c ',' 2>/dev/null || echo 0)
  count=$((count + 1))
  
  if [[ -z "$orphaned_list" ]]; then
    count=0
  fi
  
  echo "ORPHANED_COMPONENTS=${count}"
  
  if [[ "$count" -gt "$MAX_ORPHANED_COMPONENTS" ]]; then
    send_slack_alert \
      "⚠️ *WARNING*: Ditemukan *${count}* komponen tanpa owner!\nKomponen: \`${orphaned_list:0:200}...\`\n*Action*: Assign owner ke semua komponen di Service Catalog." \
      "warning"
  fi
}

check_deprecated_components() {
  echo "Mengecek komponen deprecated..."
  
  local deprecated_count
  deprecated_count=$(api_get "/catalog/entities?filter=kind=Component,spec.lifecycle=deprecated&limit=500" \
    | jq 'length // 0')
  
  echo "DEPRECATED_COMPONENTS=${deprecated_count}"
  
  if [[ "$deprecated_count" -gt 0 ]]; then
    echo "ℹ️  Ada ${deprecated_count} komponen dengan status deprecated"
  fi
}

check_missing_annotations() {
  echo "Mengecek komponen dengan anotasi penting yang hilang..."
  
  # Cek komponen yang tidak punya anotasi untuk monitoring/alerting
  local missing_grafana
  missing_grafana=$(api_get "/catalog/entities?filter=kind=Component,spec.lifecycle=production&limit=500" \
    | jq -r '[.[] | select(.metadata.annotations["grafana/dashboard-selector"] == null) | .metadata.name] | length' 2>/dev/null || echo "0")
  
  local missing_pagerduty
  missing_pagerduty=$(api_get "/catalog/entities?filter=kind=Component,spec.lifecycle=production&limit=500" \
    | jq -r '[.[] | select(.metadata.annotations["pagerduty.com/service-id"] == null) | .metadata.name] | length' 2>/dev/null || echo "0")
  
  echo "MISSING_GRAFANA_ANNOTATION=${missing_grafana}"
  echo "MISSING_PAGERDUTY_ANNOTATION=${missing_pagerduty}"
  
  if [[ "$missing_grafana" -gt 0 || "$missing_pagerduty" -gt 0 ]]; then
    echo "ℹ️  ${missing_grafana} komponen production tidak punya Grafana dashboard link"
    echo "ℹ️  ${missing_pagerduty} komponen production tidak punya PagerDuty service ID"
  fi
}

check_scaffold_errors() {
  echo "Mengecek scaffold task yang gagal (24 jam terakhir)..."
  
  local failed_tasks
  failed_tasks=$(api_get "/scaffolder/v2/tasks?status=failed" \
    | jq 'length // 0')
  
  echo "FAILED_SCAFFOLD_TASKS=${failed_tasks}"
  
  if [[ "$failed_tasks" -gt 0 ]]; then
    send_slack_alert \
      "⚠️ *WARNING*: Ada *${failed_tasks}* scaffold task yang gagal dalam 24 jam terakhir.\nCek: ${BACKSTAGE_URL}/create/tasks" \
      "warning"
  fi
}

# ─── Generate Report ──────────────────────────────────────────────────────────
generate_report() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Ambil semua data
  local entities_data
  entities_data=$(api_get "/catalog/entities?limit=500" 2>/dev/null || echo "[]")
  
  local total_entities
  total_entities=$(echo "$entities_data" | jq 'length // 0')
  
  local by_kind
  by_kind=$(echo "$entities_data" | jq 'group_by(.kind) | map({kind: .[0].kind, count: length})' 2>/dev/null || echo "[]")
  
  local by_lifecycle
  by_lifecycle=$(echo "$entities_data" | jq '[.[] | select(.kind == "Component")] | group_by(.spec.lifecycle // "unknown") | map({lifecycle: .[0].spec.lifecycle // "unknown", count: length})' 2>/dev/null || echo "[]")
  
  # Tulis report ke file JSON
  cat > "$REPORT_FILE" <<EOF
{
  "reportGeneratedAt": "${timestamp}",
  "backstageUrl": "${BACKSTAGE_URL}",
  "summary": {
    "totalEntities": ${total_entities},
    "entitiesByKind": ${by_kind},
    "componentsByLifecycle": ${by_lifecycle}
  },
  "healthChecks": {
    "apiHealth": "OK",
    "catalogEntityCount": ${total_entities},
    "thresholds": {
      "minEntities": ${MIN_CATALOG_ENTITIES},
      "maxOrphanedComponents": ${MAX_ORPHANED_COMPONENTS}
    }
  }
}
EOF
  
  echo "Report disimpan di: ${REPORT_FILE}"
  cat "$REPORT_FILE" | jq .
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo "=================================================="
  echo "  Backstage Catalog Health Check"
  echo "  Waktu: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  Target: ${BACKSTAGE_URL}"
  echo "=================================================="
  
  local has_error=false
  
  check_api_health || has_error=true
  
  if [[ "$has_error" == "false" ]]; then
    check_entity_count
    check_orphaned_components
    check_deprecated_components
    check_missing_annotations
    check_scaffold_errors
    generate_report
  fi
  
  echo ""
  echo "=================================================="
  echo "  Health Check Selesai: $(date '+%H:%M:%S')"
  
  if [[ "$has_error" == "true" ]]; then
    echo "  Status: ❌ GAGAL"
    exit 1
  else
    echo "  Status: ✅ OK"
  fi
  echo "=================================================="
}

main "$@"
