#!/usr/bin/env bash
# =============================================================================
# verify-mesh.sh — Verifikasi Health Service Mesh Istio
# =============================================================================
# Jalankan script ini untuk diagnosa cepat kondisi service mesh
# Penggunaan: ./scripts/verify-mesh.sh [--namespace production]
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
VERBOSE="${VERBOSE:-false}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_header() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }
log_ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
log_error()  { echo -e "  ${RED}✗${NC} $*"; }
log_info()   { echo -e "  ${BLUE}ℹ${NC} $*"; }

PASS=0
WARN=0
FAIL=0

check_pass() { log_ok "$1"; ((PASS++)); }
check_warn() { log_warn "$1"; ((WARN++)); }
check_fail() { log_error "$1"; ((FAIL++)); }

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE="true"; shift ;;
    --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Redirect output jika diperlukan
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee "$OUTPUT_FILE") 2>&1
fi

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Istio Service Mesh Health Verification      ║${NC}"
echo -e "${BOLD}║   Namespace: ${NAMESPACE}$(printf '%*s' $((31 - ${#NAMESPACE})) '')║${NC}"
echo -e "${BOLD}║   $(date '+%Y-%m-%d %H:%M:%S')$(printf '%*s' 21 '')║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"

# ─────────────────────────────────────────────────────────────────
log_header "1. Istio Control Plane"
# ─────────────────────────────────────────────────────────────────

# Cek istiod
ISTIOD_READY=$(kubectl get deployment istiod -n istio-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
ISTIOD_DESIRED=$(kubectl get deployment istiod -n istio-system \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

if [[ "$ISTIOD_READY" -ge 1 ]]; then
  check_pass "istiod: ${ISTIOD_READY}/${ISTIOD_DESIRED} replicas ready"
else
  check_fail "istiod: ${ISTIOD_READY}/${ISTIOD_DESIRED} ready — control plane bermasalah!"
  echo "    Debug: kubectl logs -n istio-system -l app=istiod --tail=50"
fi

# Cek Ingress Gateway
IGW_READY=$(kubectl get deployment istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$IGW_READY" -ge 1 ]]; then
  check_pass "Ingress Gateway: ${IGW_READY} replicas ready"
else
  check_fail "Ingress Gateway tidak ready"
fi

# Cek versi
ISTIO_VERSION=$(istioctl version --remote=true --short 2>/dev/null | head -1 || echo "unknown")
log_info "Istio version: $ISTIO_VERSION"

# ─────────────────────────────────────────────────────────────────
log_header "2. Sidecar Injection di Namespace '$NAMESPACE'"
# ─────────────────────────────────────────────────────────────────

# Cek label namespace
INJECTION_LABEL=$(kubectl get namespace "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")

if [[ "$INJECTION_LABEL" == "enabled" ]]; then
  check_pass "Namespace '$NAMESPACE' → istio-injection=enabled"
else
  check_warn "Namespace '$NAMESPACE' tidak punya label istio-injection=enabled"
  echo "    Fix: kubectl label namespace $NAMESPACE istio-injection=enabled"
fi

# Cek berapa pod yang punya sidecar
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
PODS_WITH_SIDECAR=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | \
  python3 -c "
import json, sys
pods = json.load(sys.stdin)['items']
count = sum(
  1 for p in pods
  if any(c['name'] == 'istio-proxy' for c in p.get('spec', {}).get('containers', []))
)
print(count)
" 2>/dev/null || echo "0")

if [[ "$TOTAL_PODS" -gt 0 ]]; then
  MISSING=$((TOTAL_PODS - PODS_WITH_SIDECAR))
  if [[ "$MISSING" -eq 0 ]]; then
    check_pass "Semua ${TOTAL_PODS} pod punya sidecar istio-proxy"
  else
    check_warn "${PODS_WITH_SIDECAR}/${TOTAL_PODS} pod punya sidecar (${MISSING} missing)"
    echo "    Cek pod tanpa sidecar:"
    kubectl get pods -n "$NAMESPACE" -o json | python3 -c "
import json, sys
pods = json.load(sys.stdin)['items']
for p in pods:
    names = [c['name'] for c in p.get('spec', {}).get('containers', [])]
    if 'istio-proxy' not in names:
        print(f'    - {p[\"metadata\"][\"name\"]} (containers: {names})')
" 2>/dev/null || true
  fi
else
  log_info "Tidak ada pod di namespace '$NAMESPACE'"
fi

# ─────────────────────────────────────────────────────────────────
log_header "3. Proxy Sync Status"
# ─────────────────────────────────────────────────────────────────

PROXY_STATUS=$(istioctl proxy-status 2>/dev/null | tail -n +2 | head -20)
if [[ -n "$PROXY_STATUS" ]]; then
  TOTAL_PROXY=$(echo "$PROXY_STATUS" | wc -l)
  NOT_SYNCED=$(echo "$PROXY_STATUS" | grep -v "SYNCED" | grep -v "IGNORED" | wc -l || echo 0)
  
  if [[ "$NOT_SYNCED" -eq 0 ]]; then
    check_pass "Semua ${TOTAL_PROXY} proxy tersync dengan istiod"
  else
    check_warn "${NOT_SYNCED}/${TOTAL_PROXY} proxy belum sync"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "$PROXY_STATUS" | grep -v "SYNCED"
    fi
  fi
else
  log_info "Tidak ada proxy terhubung atau istioctl tidak bisa akses control plane"
fi

# ─────────────────────────────────────────────────────────────────
log_header "4. mTLS Status"
# ─────────────────────────────────────────────────────────────────

# Cek PeerAuthentication
PA_COUNT=$(kubectl get peerauthentication -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
GLOBAL_PA=$(kubectl get peerauthentication default -n istio-system --no-headers 2>/dev/null | wc -l)

if [[ "$GLOBAL_PA" -gt 0 ]]; then
  GLOBAL_MODE=$(kubectl get peerauthentication default -n istio-system \
    -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "PERMISSIVE")
  if [[ "$GLOBAL_MODE" == "STRICT" ]]; then
    check_pass "Global mTLS: STRICT (cluster-wide zero-trust aktif)"
  else
    check_warn "Global mTLS mode: $GLOBAL_MODE (bukan STRICT)"
  fi
else
  check_warn "Tidak ada global PeerAuthentication — mTLS mungkin tidak dikonfigurasi"
fi

if [[ "$PA_COUNT" -gt 0 ]]; then
  log_info "PeerAuthentication policies di namespace $NAMESPACE: $PA_COUNT"
  kubectl get peerauthentication -n "$NAMESPACE" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────
log_header "5. Authorization Policies"
# ─────────────────────────────────────────────────────────────────

AUTHZ_COUNT=$(kubectl get authorizationpolicy -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [[ "$AUTHZ_COUNT" -gt 0 ]]; then
  check_pass "${AUTHZ_COUNT} AuthorizationPolicy ditemukan"
  if [[ "$VERBOSE" == "true" ]]; then
    kubectl get authorizationpolicy -n "$NAMESPACE" 2>/dev/null
  fi
else
  check_warn "Tidak ada AuthorizationPolicy — jalankan tanpa zero-trust"
  echo "    Pertimbangkan apply: configs/security/authz-deny-all.yaml"
fi

# ─────────────────────────────────────────────────────────────────
log_header "6. Istio Configuration Analysis"
# ─────────────────────────────────────────────────────────────────

log_info "Menjalankan 'istioctl analyze'..."
ANALYSIS=$(istioctl analyze -n "$NAMESPACE" 2>&1 || true)

if echo "$ANALYSIS" | grep -q "No validation issues found"; then
  check_pass "Tidak ada isu konfigurasi Istio ditemukan"
elif echo "$ANALYSIS" | grep -q "Error\|error"; then
  check_fail "Ditemukan konfigurasi error:"
  echo "$ANALYSIS" | grep -i "error" | head -10
elif echo "$ANALYSIS" | grep -q "Warning\|warning"; then
  check_warn "Ditemukan konfigurasi warning:"
  echo "$ANALYSIS" | grep -i "warning" | head -10
else
  log_info "$ANALYSIS"
fi

# ─────────────────────────────────────────────────────────────────
log_header "7. Observability Stack"
# ─────────────────────────────────────────────────────────────────

ADDONS=("prometheus" "grafana" "kiali" "jaeger")
for addon in "${ADDONS[@]}"; do
  READY=$(kubectl get deployment "$addon" -n istio-system \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  if [[ "$READY" -ge 1 ]]; then
    check_pass "$addon: running (${READY} replica)"
  else
    check_warn "$addon: tidak ditemukan atau tidak running"
  fi
done

# ─────────────────────────────────────────────────────────────────
log_header "8. Resource Usage Sidecar"
# ─────────────────────────────────────────────────────────────────

log_info "Top 5 pod dengan sidecar paling banyak makan memory:"
kubectl top pods -n "$NAMESPACE" --containers 2>/dev/null | \
  grep "istio-proxy" | sort -k4 -rh | head -5 || \
  log_info "metrics-server tidak tersedia (skip)"

# ─────────────────────────────────────────────────────────────────
log_header "Ringkasan Hasil"
# ─────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS + WARN + FAIL))
echo -e "  Total checks: $TOTAL"
echo -e "  ${GREEN}Passed:  $PASS${NC}"
echo -e "  ${YELLOW}Warning: $WARN${NC}"
echo -e "  ${RED}Failed:  $FAIL${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "  ${RED}Status: TIDAK SEHAT — ada $FAIL check yang gagal${NC}"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo -e "  ${YELLOW}Status: PERHATIAN — ada $WARN warning yang perlu ditinjau${NC}"
  exit 0
else
  echo -e "  ${GREEN}Status: SEHAT — Service mesh berjalan dengan baik ✓${NC}"
  exit 0
fi
