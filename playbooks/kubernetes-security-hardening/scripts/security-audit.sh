#!/usr/bin/env bash
# =============================================================================
# K8s Security Audit Script
# =============================================================================
# Script ini melakukan audit keamanan cluster Kubernetes dan menghasilkan
# laporan dalam format yang mudah dibaca.
#
# Cara pakai:
#   chmod +x scripts/security-audit.sh
#   ./scripts/security-audit.sh
#   ./scripts/security-audit.sh --namespace production  # Audit namespace tertentu
#   ./scripts/security-audit.sh --output json           # Output JSON
#
# Requirement: kubectl, jq, curl (semua biasanya sudah ada)
# =============================================================================

set -euo pipefail

# Warna untuk output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Variabel default
NAMESPACE_FILTER=""
OUTPUT_FORMAT="text"
CRITICAL_COUNT=0
WARNING_COUNT=0
PASS_COUNT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE_FILTER="$2"; shift 2 ;;
    --output|-o) OUTPUT_FORMAT="$2"; shift 2 ;;
    --help|-h)
      echo "Penggunaan: $0 [--namespace <ns>] [--output text|json]"
      exit 0 ;;
    *) echo "Argumen tidak dikenal: $1"; exit 1 ;;
  esac
done

# =============================================================================
# Helper functions
# =============================================================================

log_critical() {
  echo -e "${RED}[KRITIS]${NC} $1"
  ((CRITICAL_COUNT++))
}

log_warning() {
  echo -e "${YELLOW}[PERINGATAN]${NC} $1"
  ((WARNING_COUNT++))
}

log_pass() {
  echo -e "${GREEN}[OK]${NC} $1"
  ((PASS_COUNT++))
}

log_info() {
  echo -e "${CYAN}[INFO]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BOLD}${BLUE}═══ $1 ═══${NC}"
}

check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl tidak ditemukan!"
    exit 1
  fi

  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Tidak bisa connect ke cluster Kubernetes!"
    echo "Pastikan KUBECONFIG dikonfigurasi dengan benar."
    exit 1
  fi
}

# =============================================================================
# AUDIT CHECKS
# =============================================================================

check_privileged_pods() {
  log_section "Cek Pod Privileged"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  fi

  local found_privileged=false
  for ns in $namespaces; do
    # Skip system namespaces
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease)$ ]]; then
      continue
    fi

    local pods
    pods=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | 
        select(.spec.containers[]?.securityContext.privileged == true) |
        "\(.metadata.name) (\(.spec.containers[] | select(.securityContext.privileged == true) | .name))"' 2>/dev/null || true)

    if [[ -n "$pods" ]]; then
      found_privileged=true
      while IFS= read -r pod; do
        log_critical "Pod privileged di $ns: $pod"
      done <<< "$pods"
    fi
  done

  if [[ "$found_privileged" == false ]]; then
    log_pass "Tidak ada pod privileged ditemukan (kecuali kube-system)"
  fi
}

check_root_containers() {
  log_section "Cek Container yang Berjalan Sebagai Root (UID 0)"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  fi

  local found_root=false
  for ns in $namespaces; do
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease|falco|monitoring)$ ]]; then
      continue
    fi

    # Cek runAsUser: 0 atau runAsNonRoot: false
    local risky_pods
    risky_pods=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | 
        select(
          (.spec.securityContext.runAsUser == 0) or
          (.spec.securityContext.runAsNonRoot == false) or
          (.spec.containers[]?.securityContext.runAsUser == 0)
        ) | .metadata.name' 2>/dev/null || true)

    if [[ -n "$risky_pods" ]]; then
      found_root=true
      while IFS= read -r pod; do
        log_warning "Kemungkinan root container di $ns: $pod"
      done <<< "$risky_pods"
    fi
  done

  if [[ "$found_root" == false ]]; then
    log_pass "Tidak ada container yang terdeteksi berjalan sebagai root"
  fi
}

check_rbac_cluster_admin() {
  log_section "Cek Binding cluster-admin yang Berlebihan"

  # Cari semua ClusterRoleBinding ke cluster-admin
  local bindings
  bindings=$(kubectl get clusterrolebindings -o json | \
    jq -r '.items[] | 
      select(.roleRef.name == "cluster-admin") |
      select(.metadata.name != "cluster-admin") |
      "\(.metadata.name) -> \(.subjects // [] | map("\(.kind)/\(.name)") | join(", "))"' 2>/dev/null || true)

  if [[ -n "$bindings" ]]; then
    log_warning "ClusterRoleBinding ke cluster-admin:"
    while IFS= read -r binding; do
      echo "  • $binding"
    done <<< "$bindings"
    log_warning "Pastikan semua binding di atas benar-benar diperlukan!"
  else
    log_pass "Tidak ada binding cluster-admin yang mencurigakan"
  fi
}

check_network_policies() {
  log_section "Cek Network Policies"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    # Hanya cek namespace non-system
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | \
      tr ' ' '\n' | grep -v -E '^(kube-system|kube-public|kube-node-lease)$' || true)
  fi

  for ns in $namespaces; do
    local np_count
    np_count=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ "$np_count" -eq 0 ]]; then
      local pod_count
      pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
      if [[ "$pod_count" -gt 0 ]]; then
        log_warning "Namespace '$ns' tidak punya NetworkPolicy ($pod_count pods berjalan)"
      fi
    else
      log_pass "Namespace '$ns' punya $np_count NetworkPolicy"
    fi
  done
}

check_secrets_in_env() {
  log_section "Cek Secrets yang Terekspos sebagai Environment Variables"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  fi

  local found_secrets_env=false
  for ns in $namespaces; do
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease)$ ]]; then
      continue
    fi

    # Cari pod yang inject secret sebagai env var
    local pods_with_secrets
    pods_with_secrets=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | 
        select(.spec.containers[]?.env[]?.valueFrom.secretKeyRef != null) |
        .metadata.name' 2>/dev/null | sort -u || true)

    if [[ -n "$pods_with_secrets" ]]; then
      found_secrets_env=true
      while IFS= read -r pod; do
        log_warning "Pod '$pod' di $ns inject secret sebagai env var (lebih aman pakai volume mount)"
      done <<< "$pods_with_secrets"
    fi
  done

  if [[ "$found_secrets_env" == false ]]; then
    log_pass "Tidak ada secret yang diinjeksikan sebagai environment variable"
  fi
}

check_resource_limits() {
  log_section "Cek Resource Limits"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  fi

  local total_no_limits=0
  for ns in $namespaces; do
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease)$ ]]; then
      continue
    fi

    local pods_no_limits
    pods_no_limits=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | 
        select(.spec.containers[]? | 
          (.resources.limits == null or .resources.limits == {})) | 
        .metadata.name' 2>/dev/null | sort -u || true)

    if [[ -n "$pods_no_limits" ]]; then
      local count
      count=$(echo "$pods_no_limits" | wc -l)
      total_no_limits=$((total_no_limits + count))
      log_warning "$count pod di '$ns' tidak punya resource limits"
    fi
  done

  if [[ "$total_no_limits" -eq 0 ]]; then
    log_pass "Semua pod memiliki resource limits"
  fi
}

check_psa_labels() {
  log_section "Cek Pod Security Admission Labels"

  local namespaces
  namespaces=$(kubectl get namespaces -o json 2>/dev/null | \
    jq -r '.items[] | 
      select(.metadata.name | test("^(kube-|local-path)") | not) |
      .metadata.name' || true)

  for ns in $namespaces; do
    local has_psa
    has_psa=$(kubectl get namespace "$ns" -o json 2>/dev/null | \
      jq -r '.metadata.labels | 
        to_entries[] | 
        select(.key | startswith("pod-security.kubernetes.io")) | 
        "\(.key)=\(.value)"' | head -1 || true)

    if [[ -z "$has_psa" ]]; then
      local pod_count
      pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
      if [[ "$pod_count" -gt 0 ]]; then
        log_warning "Namespace '$ns' tidak punya Pod Security Admission labels"
      fi
    else
      log_pass "Namespace '$ns' PSA: $has_psa"
    fi
  done
}

check_image_latest_tag() {
  log_section "Cek Image yang Menggunakan Tag 'latest'"

  local namespaces
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    namespaces="$NAMESPACE_FILTER"
  else
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  fi

  local found_latest=false
  for ns in $namespaces; do
    if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease)$ ]]; then
      continue
    fi

    local latest_images
    latest_images=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      jq -r '.items[] | 
        .metadata.name as $pod |
        .spec.containers[] | 
        select(.image | endswith(":latest") or (test(":[^:]+") | not)) |
        "\($pod): \(.image)"' 2>/dev/null || true)

    if [[ -n "$latest_images" ]]; then
      found_latest=true
      while IFS= read -r img; do
        log_warning "Tag 'latest' atau tanpa tag di $ns: $img"
      done <<< "$latest_images"
    fi
  done

  if [[ "$found_latest" == false ]]; then
    log_pass "Tidak ada image dengan tag 'latest' atau tanpa tag"
  fi
}

print_summary() {
  log_section "RINGKASAN AUDIT KEAMANAN"

  echo ""
  echo -e "  ${RED}${BOLD}KRITIS   : $CRITICAL_COUNT${NC}"
  echo -e "  ${YELLOW}${BOLD}PERINGATAN: $WARNING_COUNT${NC}"
  echo -e "  ${GREEN}${BOLD}OK       : $PASS_COUNT${NC}"
  echo ""

  local total=$((CRITICAL_COUNT + WARNING_COUNT + PASS_COUNT))
  local score=0
  if [[ "$total" -gt 0 ]]; then
    score=$(echo "scale=0; $PASS_COUNT * 100 / $total" | bc)
  fi

  echo -e "  ${BOLD}Security Score: $score/100${NC}"

  if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}⚠️  Ada $CRITICAL_COUNT masalah KRITIS yang harus segera diperbaiki!${NC}"
    exit 2
  elif [[ "$WARNING_COUNT" -gt 5 ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠️  Ada $WARNING_COUNT peringatan. Harap tinjau dan perbaiki.${NC}"
    exit 1
  else
    echo ""
    echo -e "  ${GREEN}✅ Cluster dalam kondisi keamanan yang baik.${NC}"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   K8s Security Audit - DevOps Playbooks          ║${NC}"
echo -e "${BOLD}${CYAN}║   Dijalankan: $(date '+%Y-%m-%d %H:%M:%S')           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"

# Pastikan kubectl ada dan cluster accessible
check_kubectl

log_info "Cluster: $(kubectl config current-context)"
log_info "Server: $(kubectl cluster-info 2>/dev/null | grep 'control plane' | awk '{print $NF}' || echo 'N/A')"

if [[ -n "$NAMESPACE_FILTER" ]]; then
  log_info "Filter namespace: $NAMESPACE_FILTER"
fi

# Jalankan semua checks
check_privileged_pods
check_root_containers
check_rbac_cluster_admin
check_network_policies
check_secrets_in_env
check_resource_limits
check_psa_labels
check_image_latest_tag

# Tampilkan summary
print_summary
