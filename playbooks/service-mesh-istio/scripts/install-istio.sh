#!/usr/bin/env bash
# =============================================================================
# install-istio.sh — Instalasi Istio Production-Ready
# =============================================================================
# Penggunaan:
#   chmod +x scripts/install-istio.sh
#   ./scripts/install-istio.sh [--profile production|demo] [--version 1.23.0]
#
# Prasyarat:
#   - kubectl terinstall dan konfigurasi sudah pointing ke cluster target
#   - Minimal: 4 CPU core, 8GB RAM di cluster
#   - Helm 3+ (opsional, untuk addons)
# =============================================================================

set -euo pipefail

# ─── Default Values ──────────────────────────────────────────────
ISTIO_VERSION="${ISTIO_VERSION:-1.23.0}"
PROFILE="${PROFILE:-default}"
NAMESPACE="istio-system"
ADDONS_INSTALL="${ADDONS_INSTALL:-true}"
DRY_RUN="${DRY_RUN:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Fungsi Helper ───────────────────────────────────────────────
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) ISTIO_VERSION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-addons) ADDONS_INSTALL="false"; shift ;;
    -h|--help)
      echo "Penggunaan: $0 [--version X.Y.Z] [--profile default|demo|production] [--dry-run] [--skip-addons]"
      exit 0 ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
done

# ─── Cek Prasyarat ───────────────────────────────────────────────
check_prerequisites() {
  log_info "Memeriksa prasyarat..."

  # kubectl
  if ! command -v kubectl &>/dev/null; then
    die "kubectl tidak ditemukan. Install dulu: https://kubernetes.io/docs/tasks/tools/"
  fi

  # Koneksi ke cluster
  if ! kubectl cluster-info &>/dev/null; then
    die "Tidak bisa koneksi ke Kubernetes cluster. Cek kubeconfig Anda."
  fi

  # Kubernetes version
  K8S_VERSION=$(kubectl version --output=json 2>/dev/null | python3 -c "
import json, sys
v = json.load(sys.stdin)
server_v = v.get('serverVersion', {}).get('gitVersion', 'unknown')
print(server_v)
  " || echo "unknown")
  log_info "Kubernetes version: $K8S_VERSION"

  # Resource check (kasar)
  TOTAL_CPU=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.cpu}{"\n"}{end}' \
    2>/dev/null | awk '{sum+=$1} END {print sum}')
  TOTAL_MEM=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.memory}{"\n"}{end}' \
    2>/dev/null | awk '{gsub(/Ki/,""); sum+=$1} END {printf "%.0f\n", sum/1024/1024}')

  log_info "Total cluster resources: ${TOTAL_CPU} CPU, ${TOTAL_MEM} GB RAM"

  if [[ "${TOTAL_CPU:-0}" -lt 4 ]]; then
    log_warn "CPU total kurang dari 4 core — Istio production perlu minimal 4 core"
  fi

  log_ok "Prasyarat OK"
}

# ─── Download Istio ──────────────────────────────────────────────
download_istio() {
  log_info "Mengunduh Istio ${ISTIO_VERSION}..."

  if [[ -d "$HOME/istio-${ISTIO_VERSION}" ]]; then
    log_info "Istio ${ISTIO_VERSION} sudah ada di $HOME/istio-${ISTIO_VERSION}"
  else
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
    mv "istio-${ISTIO_VERSION}" "$HOME/"
  fi

  export PATH="$HOME/istio-${ISTIO_VERSION}/bin:$PATH"

  if ! command -v istioctl &>/dev/null; then
    die "istioctl tidak ditemukan setelah download. Cek instalasi manual."
  fi

  ACTUAL_VERSION=$(istioctl version --remote=false 2>/dev/null || echo "unknown")
  log_ok "istioctl siap: $ACTUAL_VERSION"
}

# ─── Pre-flight Check ────────────────────────────────────────────
preflight_check() {
  log_info "Menjalankan pre-flight check Istio..."

  OUTPUT=$(istioctl x precheck 2>&1)

  if echo "$OUTPUT" | grep -q "No issues found"; then
    log_ok "Pre-flight check lulus"
  elif echo "$OUTPUT" | grep -q "error\|Error"; then
    log_error "Pre-flight check menemukan masalah:"
    echo "$OUTPUT"
    die "Perbaiki masalah di atas sebelum install Istio"
  else
    log_warn "Pre-flight check selesai dengan warning:"
    echo "$OUTPUT"
    read -r -p "Lanjutkan instalasi? (y/N) " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || die "Instalasi dibatalkan"
  fi
}

# ─── Install Istio ───────────────────────────────────────────────
install_istio() {
  log_info "Menginstall Istio dengan profile: ${PROFILE}"

  # Buat namespace jika belum ada
  kubectl get namespace "$NAMESPACE" &>/dev/null || \
    kubectl create namespace "$NAMESPACE"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Command yang akan dijalankan:"
    echo "istioctl install --set profile=${PROFILE} -y"
    return
  fi

  # Cek apakah ada custom operator config
  OPERATOR_CONFIG=""
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/../configs/istio-operator.yaml" ]]; then
    OPERATOR_CONFIG="-f ${SCRIPT_DIR}/../configs/istio-operator.yaml"
    log_info "Menggunakan custom operator config: configs/istio-operator.yaml"
  fi

  # Install
  # shellcheck disable=SC2086
  istioctl install \
    --set profile="${PROFILE}" \
    ${OPERATOR_CONFIG} \
    --verify \
    -y

  log_ok "Istio berhasil diinstall"
}

# ─── Label Namespaces ────────────────────────────────────────────
setup_namespaces() {
  log_info "Mengkonfigurasi sidecar injection untuk namespaces..."

  NAMESPACES_WITH_INJECTION=("default" "production" "staging")

  for ns in "${NAMESPACES_WITH_INJECTION[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
      kubectl label namespace "$ns" istio-injection=enabled --overwrite
      log_ok "Namespace '$ns' → istio-injection=enabled"
    else
      log_warn "Namespace '$ns' tidak ditemukan, skip"
    fi
  done
}

# ─── Install Observability Addons ────────────────────────────────
install_addons() {
  if [[ "$ADDONS_INSTALL" != "true" ]]; then
    log_info "Addons dilewati (--skip-addons)"
    return
  fi

  log_info "Menginstall observability addons..."

  ISTIO_ADDONS_URL="https://raw.githubusercontent.com/istio/istio/release-${ISTIO_VERSION%.*}/samples/addons"

  ADDONS=("prometheus" "grafana" "jaeger" "kiali")

  for addon in "${ADDONS[@]}"; do
    log_info "  Installing $addon..."
    kubectl apply -f "${ISTIO_ADDONS_URL}/${addon}.yaml" 2>&1 | tail -3
    log_ok "  $addon diinstall"
  done

  log_info "Menunggu addons ready (max 3 menit)..."
  kubectl wait --for=condition=ready pod \
    -l app=kiali -n istio-system \
    --timeout=180s 2>/dev/null && log_ok "Kiali ready" || log_warn "Kiali timeout — cek manual"

  kubectl wait --for=condition=ready pod \
    -l app=prometheus -n istio-system \
    --timeout=180s 2>/dev/null && log_ok "Prometheus ready" || log_warn "Prometheus timeout"
}

# ─── Verifikasi ──────────────────────────────────────────────────
verify_installation() {
  log_info "Memverifikasi instalasi..."

  # Cek semua pod istio-system running
  log_info "Status pod di istio-system:"
  kubectl get pods -n istio-system

  echo ""
  # Verifikasi istiod
  if kubectl rollout status deployment/istiod -n istio-system --timeout=120s &>/dev/null; then
    log_ok "istiod: Running ✓"
  else
    log_warn "istiod belum ready — cek: kubectl get pods -n istio-system"
  fi

  # istioctl verify
  log_info "Menjalankan istioctl verify-install..."
  istioctl verify-install 2>&1 | tail -5 || true

  echo ""
  log_ok "═══════════════════════════════════════════════════════"
  log_ok " Istio ${ISTIO_VERSION} berhasil diinstall!"
  log_ok "═══════════════════════════════════════════════════════"
  echo ""
  echo "  Langkah selanjutnya:"
  echo "  1. Label namespace aplikasi Anda:"
  echo "     kubectl label namespace <your-ns> istio-injection=enabled"
  echo ""
  echo "  2. Restart deployments agar sidecar di-inject:"
  echo "     kubectl rollout restart deployment -n <your-ns>"
  echo ""
  echo "  3. Akses dashboards:"
  echo "     istioctl dashboard kiali    # Service graph"
  echo "     istioctl dashboard grafana  # Metrics"
  echo "     istioctl dashboard jaeger   # Tracing"
  echo ""
  echo "  4. Apply policy dari playbook ini:"
  echo "     kubectl apply -f configs/security/mtls-strict.yaml"
  echo "     kubectl apply -f monitoring/prometheus-rules.yaml"
  echo ""
}

# ─── Main ────────────────────────────────────────────────────────
main() {
  echo ""
  log_info "═══════════════════════════════════════════════════════"
  log_info " Istio Service Mesh Installer"
  log_info " Version: ${ISTIO_VERSION} | Profile: ${PROFILE}"
  log_info "═══════════════════════════════════════════════════════"
  echo ""

  check_prerequisites
  download_istio
  preflight_check
  install_istio
  setup_namespaces
  install_addons
  verify_installation
}

main "$@"
