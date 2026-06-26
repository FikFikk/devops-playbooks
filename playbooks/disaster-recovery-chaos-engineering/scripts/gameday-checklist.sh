#!/usr/bin/env bash
# =============================================================================
# gameday-checklist.sh — Pre-Game Day Verification
# Jalankan script ini sebelum memulai chaos engineering game day
# untuk memastikan semua prerequisite terpenuhi
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
    local name="$1"
    local result="$2"

    if [[ "${result}" == "PASS" ]]; then
        echo -e "  ${GREEN}✅ PASS${NC} — ${name}"
        ((PASS++))
    elif [[ "${result}" == "WARN" ]]; then
        echo -e "  ${YELLOW}⚠️  WARN${NC} — ${name}"
        ((WARN++))
    else
        echo -e "  ${RED}❌ FAIL${NC} — ${name}"
        ((FAIL++))
    fi
}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   🎮 CHAOS ENGINEERING GAME DAY CHECKLIST   ║${NC}"
echo -e "${BLUE}║   Date: $(date '+%Y-%m-%d %H:%M')                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# 1. Tool Availability
# =============================================================================

echo -e "${BLUE}1. TOOL AVAILABILITY${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for tool in kubectl helm velero litmusctl aws jq curl; do
    if command -v "${tool}" &>/dev/null; then
        check "${tool} installed ($(${tool} version --short 2>/dev/null || ${tool} --version 2>/dev/null | head -1))" "PASS"
    else
        check "${tool} not found" "FAIL"
    fi
done

echo ""

# =============================================================================
# 2. Cluster Health
# =============================================================================

echo -e "${BLUE}2. CLUSTER HEALTH${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Node status
not_ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -v Ready | wc -l || echo "999")
total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${not_ready_nodes}" -eq 0 && "${total_nodes}" -gt 0 ]]; then
    check "All ${total_nodes} nodes Ready" "PASS"
else
    check "Not Ready nodes: ${not_ready_nodes}/${total_nodes}" "FAIL"
fi

# Pod status di production
crashing_pods=$(kubectl get pods -n production --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error|OOMKilled" | wc -l || echo "0")
if [[ "${crashing_pods}" -eq 0 ]]; then
    check "No crashing pods in production namespace" "PASS"
else
    check "${crashing_pods} pods crashing in production" "FAIL"
fi

# Pending pods
pending_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep Pending | wc -l || echo "0")
if [[ "${pending_pods}" -eq 0 ]]; then
    check "No pending pods" "PASS"
else
    check "${pending_pods} pending pods" "WARN"
fi

echo ""

# =============================================================================
# 3. Monitoring & Alerting
# =============================================================================

echo -e "${BLUE}3. MONITORING & ALERTING${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Prometheus
prom_status=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c Running || echo "0")
if [[ "${prom_status}" -gt 0 ]]; then
    check "Prometheus running (${prom_status} pods)" "PASS"
else
    check "Prometheus tidak berjalan" "FAIL"
fi

# Grafana
grafana_status=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c Running || echo "0")
if [[ "${grafana_status}" -gt 0 ]]; then
    check "Grafana running" "PASS"
else
    check "Grafana tidak berjalan" "WARN"
fi

# AlertManager
alertmanager_status=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -c Running || echo "0")
if [[ "${alertmanager_status}" -gt 0 ]]; then
    check "AlertManager running" "PASS"
else
    check "AlertManager tidak berjalan" "FAIL"
fi

echo ""

# =============================================================================
# 4. Litmus Chaos
# =============================================================================

echo -e "${BLUE}4. LITMUS CHAOS ENGINE${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

litmus_ns=$(kubectl get namespace litmus --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${litmus_ns}" -gt 0 ]]; then
    check "Litmus namespace exists" "PASS"
else
    check "Litmus namespace not found" "FAIL"
fi

litmus_pods=$(kubectl get pods -n litmus --no-headers 2>/dev/null | grep -c Running || echo "0")
if [[ "${litmus_pods}" -gt 0 ]]; then
    check "Litmus pods running (${litmus_pods})" "PASS"
else
    check "No Litmus pods running" "FAIL"
fi

# ChaosServiceAccount
chaos_sa=$(kubectl get serviceaccount litmus-admin -n production --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${chaos_sa}" -gt 0 ]]; then
    check "Chaos ServiceAccount (litmus-admin) exists" "PASS"
else
    check "Chaos ServiceAccount not found — buat dulu!" "FAIL"
fi

echo ""

# =============================================================================
# 5. Backup Status
# =============================================================================

echo -e "${BLUE}5. BACKUP STATUS${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

latest_backup=$(kubectl get backup -n velero --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${latest_backup}" ]]; then
    backup_status=$(kubectl get backup "${latest_backup}" -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    backup_time=$(kubectl get backup "${latest_backup}" -n velero -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "Unknown")
    if [[ "${backup_status}" == "Completed" ]]; then
        check "Latest backup: ${latest_backup} (${backup_status}, ${backup_time})" "PASS"
    else
        check "Latest backup status: ${backup_status}" "WARN"
    fi
else
    check "No backups found" "FAIL"
fi

echo ""

# =============================================================================
# 6. No Active Deployments/Maintenance
# =============================================================================

echo -e "${BLUE}6. DEPLOYMENT ACTIVITY${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

progressing=$(kubectl get deployments -n production -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Progressing")].reason}{"\n"}{end}' 2>/dev/null | grep -v ReplicaSetUpdated | grep -v NewReplicaSetAvailable | wc -l || echo "0")
if [[ "${progressing}" -le 1 ]]; then
    check "No active deployments in progress" "PASS"
else
    check "Active deployments detected — tunggu selesai dulu" "FAIL"
fi

# Active ChaosEngines
active_chaos=$(kubectl get chaosengine --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${active_chaos}" -eq 0 ]]; then
    check "No existing ChaosEngines running" "PASS"
else
    check "${active_chaos} ChaosEngine(s) active — bersihkan dulu" "WARN"
fi

echo ""

# =============================================================================
# 7. PodDisruptionBudgets
# =============================================================================

echo -e "${BLUE}7. POD DISRUPTION BUDGETS${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

pdb_count=$(kubectl get pdb -n production --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${pdb_count}" -gt 0 ]]; then
    check "PDBs configured in production (${pdb_count})" "PASS"
    kubectl get pdb -n production --no-headers 2>/dev/null | while read -r line; do
        name=$(echo "${line}" | awk '{print $1}')
        allowed=$(echo "${line}" | awk '{print $6}')
        check "  PDB '${name}' — disruptions allowed: ${allowed}" "PASS"
    done
else
    check "No PDBs found — chaos experiments mungkin menyebabkan full outage" "WARN"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================

echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${BLUE}SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: ${PASS}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN}${NC}"
echo -e "  ${RED}FAIL: ${FAIL}${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "${RED}❌ GAME DAY TIDAK SIAP — Perbaiki FAIL items di atas terlebih dahulu!${NC}"
    exit 1
elif [[ "${WARN}" -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  GAME DAY BISA DILANJUTKAN (dengan catatan WARN items)${NC}"
    exit 0
else
    echo -e "${GREEN}✅ GAME DAY SIAP — Semua checks passed!${NC}"
    exit 0
fi
