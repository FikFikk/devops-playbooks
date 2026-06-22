#!/bin/bash
# =============================================================================
# install-backstage.sh
# Script instalasi Backstage end-to-end untuk lingkungan production
# 
# Usage: ./install-backstage.sh [--env staging|production] [--skip-db]
# =============================================================================

set -euo pipefail

# ─── Warna untuk output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Variabel Konfigurasi ──────────────────────────────────────────────────────
ENVIRONMENT="${ENVIRONMENT:-staging}"
BACKSTAGE_VERSION="${BACKSTAGE_VERSION:-1.0.0}"
NAMESPACE="${NAMESPACE:-backstage}"
REGISTRY="${REGISTRY:-registry.mycompany.com/platform}"
APP_DIR="${APP_DIR:-/opt/backstage}"

# ─── Fungsi Helper ────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}ℹ️  [INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}✅ [OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}⚠️  [WARN]${NC} $*"; }
log_error()   { echo -e "${RED}❌ [ERROR]${NC} $*"; exit 1; }

print_banner() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║       Backstage IDP Installation Script              ║"
  echo "║       Environment: ${ENVIRONMENT}                          ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

check_prerequisites() {
  log_info "Memeriksa prasyarat..."
  
  local missing=()
  
  # Cek tools yang required
  for tool in node npm yarn docker kubectl helm curl jq; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Tool berikut tidak ditemukan: ${missing[*]}"
  fi
  
  # Cek versi Node.js (minimal 18.x)
  NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
  if [[ "$NODE_VERSION" -lt 18 ]]; then
    log_error "Node.js 18+ diperlukan. Versi saat ini: $(node -v)"
  fi
  
  # Cek kubectl context
  CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
  if [[ -z "$CURRENT_CONTEXT" ]]; then
    log_error "kubectl tidak terkonfigurasi. Pastikan kubeconfig sudah di-set."
  fi
  log_info "kubectl context aktif: ${CURRENT_CONTEXT}"
  
  # Cek environment variables yang required
  local required_vars=(
    "POSTGRES_HOST" "POSTGRES_PASSWORD"
    "GITHUB_CLIENT_ID" "GITHUB_CLIENT_SECRET"
    "GITHUB_APP_ID" "GITHUB_APP_PRIVATE_KEY"
  )
  
  local missing_vars=()
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing_vars+=("$var")
    fi
  done
  
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log_error "Environment variable berikut belum di-set: ${missing_vars[*]}"
  fi
  
  log_success "Semua prasyarat terpenuhi"
}

setup_namespace() {
  log_info "Membuat namespace ${NAMESPACE}..."
  
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml \
    | kubectl apply -f -
  
  # Label namespace
  kubectl label namespace "$NAMESPACE" \
    app.kubernetes.io/name=backstage \
    environment="${ENVIRONMENT}" \
    --overwrite
  
  log_success "Namespace '${NAMESPACE}' siap"
}

deploy_postgres() {
  log_info "Deploying PostgreSQL..."
  
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update
  
  helm upgrade --install backstage-postgres bitnami/postgresql \
    --namespace "$NAMESPACE" \
    --set auth.username=backstage \
    --set auth.password="${POSTGRES_PASSWORD}" \
    --set auth.database=backstage \
    --set primary.persistence.size=20Gi \
    --set primary.resources.requests.memory=256Mi \
    --set primary.resources.requests.cpu=100m \
    --set primary.resources.limits.memory=512Mi \
    --set primary.resources.limits.cpu=500m \
    --wait \
    --timeout 5m
  
  log_success "PostgreSQL deployed"
}

deploy_redis() {
  log_info "Deploying Redis (untuk caching)..."
  
  helm upgrade --install backstage-redis bitnami/redis \
    --namespace "$NAMESPACE" \
    --set auth.enabled=true \
    --set auth.password="${REDIS_PASSWORD:-changeme}" \
    --set master.persistence.enabled=false \
    --set replica.replicaCount=0 \
    --wait \
    --timeout 3m
  
  log_success "Redis deployed"
}

create_secrets() {
  log_info "Membuat Kubernetes secrets..."
  
  # Hapus secret lama jika ada
  kubectl delete secret backstage-secrets -n "$NAMESPACE" --ignore-not-found
  
  kubectl create secret generic backstage-secrets \
    --namespace="$NAMESPACE" \
    --from-literal=POSTGRES_HOST="${POSTGRES_HOST}" \
    --from-literal=POSTGRES_PORT="${POSTGRES_PORT:-5432}" \
    --from-literal=POSTGRES_USER="${POSTGRES_USER:-backstage}" \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    --from-literal=REDIS_HOST="backstage-redis-master.${NAMESPACE}.svc.cluster.local" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD:-changeme}" \
    --from-literal=GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID}" \
    --from-literal=GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET}" \
    --from-literal=AUTH_SESSION_SECRET="$(openssl rand -base64 32)" \
    --from-literal=K8S_PROD_URL="${K8S_PROD_URL:-}" \
    --from-literal=K8S_PROD_TOKEN="${K8S_PROD_TOKEN:-}" \
    --from-literal=K8S_STAGING_URL="${K8S_STAGING_URL:-}" \
    --from-literal=K8S_STAGING_TOKEN="${K8S_STAGING_TOKEN:-}"
  
  # Secret untuk GitHub App
  kubectl create secret generic backstage-github-app \
    --namespace="$NAMESPACE" \
    --from-literal=appId="${GITHUB_APP_ID}" \
    --from-literal=privateKey="${GITHUB_APP_PRIVATE_KEY}" \
    --from-literal=clientId="${GITHUB_CLIENT_ID}" \
    --from-literal=clientSecret="${GITHUB_CLIENT_SECRET}" \
    --from-literal=webhookSecret="${GITHUB_WEBHOOK_SECRET:-}" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  log_success "Secrets berhasil dibuat"
}

deploy_backstage() {
  log_info "Deploying Backstage aplikasi..."
  
  # Apply Kubernetes manifests
  kubectl apply -f kubernetes/backstage-deployment.yaml -n "$NAMESPACE"
  
  # Tunggu deployment rollout selesai
  log_info "Menunggu deployment selesai (max 5 menit)..."
  kubectl rollout status deployment/backstage \
    --namespace="$NAMESPACE" \
    --timeout=5m
  
  log_success "Backstage berhasil deployed"
}

setup_monitoring() {
  log_info "Mengkonfigurasi monitoring (ServiceMonitor untuk Prometheus)..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: backstage
  namespace: ${NAMESPACE}
  labels:
    app: backstage
spec:
  selector:
    matchLabels:
      app: backstage
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
EOF
  
  log_success "ServiceMonitor untuk Prometheus dikonfigurasi"
}

run_smoke_tests() {
  log_info "Menjalankan smoke tests..."
  
  # Tunggu pod ready
  kubectl wait pod \
    --selector=app=backstage \
    --for=condition=Ready \
    --namespace="$NAMESPACE" \
    --timeout=120s
  
  # Port-forward untuk test
  kubectl port-forward svc/backstage 7007:80 -n "$NAMESPACE" &
  PF_PID=$!
  sleep 5
  
  # Test health endpoint
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:7007/healthcheck)
  
  kill $PF_PID 2>/dev/null || true
  
  if [[ "$HTTP_STATUS" == "200" ]]; then
    log_success "Smoke test PASSED — Health check: ${HTTP_STATUS}"
  else
    log_error "Smoke test FAILED — Health check returned: ${HTTP_STATUS}"
  fi
}

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✅ INSTALASI BACKSTAGE SELESAI!        ${NC}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BOLD}📎 Informasi Akses:${NC}"
  
  EXTERNAL_IP=$(kubectl get ingress backstage -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  
  echo "   🌐 URL: https://backstage.mycompany.com"
  echo "   🔌 External IP: ${EXTERNAL_IP}"
  echo "   🏠 Namespace: ${NAMESPACE}"
  echo ""
  echo -e "${BOLD}📋 Perintah Berguna:${NC}"
  echo "   kubectl get pods -n ${NAMESPACE}                    # Cek status pod"
  echo "   kubectl logs -n ${NAMESPACE} deploy/backstage -f    # Lihat logs"
  echo "   kubectl rollout restart deploy/backstage -n ${NAMESPACE}  # Restart"
  echo ""
  echo -e "${BOLD}📚 Dokumentasi:${NC}"
  echo "   https://backstage.io/docs"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  print_banner
  
  # Parse arguments
  SKIP_DB=false
  SKIP_MONITORING=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --env) ENVIRONMENT="$2"; shift 2 ;;
      --skip-db) SKIP_DB=true; shift ;;
      --skip-monitoring) SKIP_MONITORING=true; shift ;;
      *) log_warn "Argumen tidak dikenal: $1"; shift ;;
    esac
  done
  
  check_prerequisites
  setup_namespace
  
  if [[ "$SKIP_DB" == "false" ]]; then
    deploy_postgres
    deploy_redis
  else
    log_warn "Melewati instalasi database (--skip-db)"
  fi
  
  create_secrets
  deploy_backstage
  
  if [[ "$SKIP_MONITORING" == "false" ]]; then
    setup_monitoring
  fi
  
  run_smoke_tests
  print_summary
}

main "$@"
