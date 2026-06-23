#!/usr/bin/env bash
# =============================================================================
# K8s Hardening Setup Script
# =============================================================================
# Script otomatis untuk menerapkan semua security hardening sekaligus.
# Jalankan SETELAH memahami setiap step di README.md
#
# PERINGATAN: Baca dan pahami script ini sebelum dijalankan di production!
# Test di environment development/staging dulu.
#
# Cara pakai:
#   chmod +x scripts/apply-hardening.sh
#   ./scripts/apply-hardening.sh --dry-run    # Preview tanpa apply
#   ./scripts/apply-hardening.sh              # Apply semua
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_DIR="$(dirname "$SCRIPT_DIR")"
DRY_RUN=false
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) SKIP_CONFIRM=true; shift ;;
    --help|-h)
      echo "Penggunaan: $0 [--dry-run] [--yes]"
      echo "  --dry-run  : Preview perubahan tanpa apply"
      echo "  --yes      : Lewati konfirmasi interaktif"
      exit 0 ;;
    *) echo "Argumen tidak dikenal: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

apply_manifest() {
  local file="$1"
  local description="$2"

  echo -e "\n${BOLD}▶ $description${NC}"
  echo "  File: $file"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY RUN] kubectl apply -f $file${NC}"
    kubectl apply -f "$file" --dry-run=client 2>&1 | sed 's/^/  /'
  else
    kubectl apply -f "$file"
    echo -e "  ${GREEN}✓ Berhasil diterapkan${NC}"
  fi
}

label_namespace() {
  local ns="$1"
  local level="$2"

  echo -e "\n${BOLD}▶ Label namespace '$ns' dengan PSA level '$level'${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY RUN] kubectl label namespace $ns pod-security.kubernetes.io/enforce=$level${NC}"
  else
    kubectl label namespace "$ns" \
      "pod-security.kubernetes.io/enforce=$level" \
      "pod-security.kubernetes.io/audit=$level" \
      "pod-security.kubernetes.io/warn=$level" \
      --overwrite
    echo -e "  ${GREEN}✓ Label diterapkan${NC}"
  fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   K8s Security Hardening - Auto Setup Script            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"

if [[ "$DRY_RUN" == true ]]; then
  echo -e "\n${YELLOW}⚠️  MODE DRY RUN - Tidak ada yang akan diubah${NC}"
fi

echo -e "\nCluster: $(kubectl config current-context)"
echo -e "Server: $(kubectl cluster-info 2>/dev/null | grep -i 'control plane' | head -1 | awk '{print $NF}' || echo 'N/A')"

if [[ "$SKIP_CONFIRM" == false && "$DRY_RUN" == false ]]; then
  echo ""
  echo -e "${RED}${BOLD}PERINGATAN:${NC} Script ini akan mengubah konfigurasi keamanan cluster!"
  echo "Pastikan sudah:"
  echo "  1. ✅ Baca dan pahami README.md"
  echo "  2. ✅ Test di dev/staging environment"
  echo "  3. ✅ Backup konfigurasi yang ada"
  echo "  4. ✅ Punya rollback plan"
  echo ""
  read -rp "Lanjutkan? (ketik 'ya' untuk konfirmasi): " confirm
  if [[ "$confirm" != "ya" ]]; then
    echo "Dibatalkan."
    exit 0
  fi
fi

echo ""
echo -e "${BOLD}═══ Step 1: RBAC ═══${NC}"
apply_manifest "$PLAYBOOK_DIR/rbac/readonly-role.yaml" \
  "Terapkan ClusterRole monitoring-reader"

echo ""
echo -e "${BOLD}═══ Step 2: Network Policies ═══${NC}"
echo -e "${YELLOW}  INFO: Pastikan ada traffic yang diizinkan sebelum apply default-deny!${NC}"

# Terapkan allow policies dulu, baru default-deny
apply_manifest "$PLAYBOOK_DIR/network-policies/allow-monitoring.yaml" \
  "Izinkan Prometheus scrape metrics"
apply_manifest "$PLAYBOOK_DIR/network-policies/allow-frontend-to-backend.yaml" \
  "Izinkan traffic frontend ke backend"

echo ""
echo -e "${BOLD}═══ Step 3: Pod Security Admission ═══${NC}"
# Label namespace berdasarkan lingkungan
for ns in production; do
  if kubectl get namespace "$ns" &>/dev/null; then
    label_namespace "$ns" "restricted"
  else
    echo "  Namespace '$ns' tidak ditemukan, dilewati."
  fi
done

for ns in staging development; do
  if kubectl get namespace "$ns" &>/dev/null; then
    label_namespace "$ns" "baseline"
  else
    echo "  Namespace '$ns' tidak ditemukan, dilewati."
  fi
done

echo ""
echo -e "${BOLD}═══ Step 4: Audit Logging ═══${NC}"
echo -e "${YELLOW}  INFO: Konfigurasi audit logging memerlukan akses ke control plane.${NC}"
echo "  Salin file berikut ke control plane node:"
echo "    $PLAYBOOK_DIR/policies/audit-policy.yaml"
echo "    → /etc/kubernetes/audit-policy.yaml"
echo ""
echo "  Tambahkan ke /etc/kubernetes/manifests/kube-apiserver.yaml:"
echo "    --audit-log-path=/var/log/kubernetes/audit.log"
echo "    --audit-log-maxage=30"
echo "    --audit-log-maxbackup=10"
echo "    --audit-log-maxsize=100"
echo "    --audit-policy-file=/etc/kubernetes/audit-policy.yaml"

echo ""
echo -e "${BOLD}═══ Step 5: Install Security Tools ═══${NC}"

echo "  Falco (Runtime Security):"
echo "    helm repo add falcosecurity https://falcosecurity.github.io/charts"
echo "    helm install falco falcosecurity/falco -n falco --create-namespace \\"
echo "      --set falcosidekick.enabled=true \\"
echo "      --set falcosidekick.webui.enabled=true \\"
echo "      --set driver.kind=ebpf"

echo ""
echo "  Kyverno (Policy Engine):"
echo "    helm repo add kyverno https://kyverno.github.io/kyverno/"
echo "    helm install kyverno kyverno/kyverno -n kyverno --create-namespace"

echo ""
echo -e "${BOLD}═══ Step 6: Jalankan Security Audit ═══${NC}"
echo "  Setelah semua diterapkan, jalankan audit:"
echo "    ./scripts/security-audit.sh"

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}✅ Dry run selesai. Jalankan tanpa --dry-run untuk apply.${NC}"
else
  echo -e "${GREEN}✅ Hardening selesai!${NC}"
  echo ""
  echo "Langkah selanjutnya:"
  echo "  1. Jalankan: ./scripts/security-audit.sh"
  echo "  2. Check Falco alerts: kubectl logs -n falco -l app.kubernetes.io/name=falco"
  echo "  3. Verifikasi app masih berjalan: kubectl get pods -A"
fi
