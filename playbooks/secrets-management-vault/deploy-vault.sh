#!/bin/bash
set -euo pipefail

# Deployment script untuk Vault di Kubernetes
# Usage: ./deploy-vault.sh [dev|prod]

ENV=${1:-dev}

echo "=================================================="
echo "🚀 Deploying HashiCorp Vault - Environment: $ENV"
echo "=================================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."
    
    command -v kubectl >/dev/null 2>&1 || error "kubectl tidak ditemukan"
    command -v helm >/dev/null 2>&1 || error "helm tidak ditemukan"
    
    kubectl cluster-info >/dev/null 2>&1 || error "Tidak bisa connect ke Kubernetes cluster"
    
    info "✅ Prerequisites OK"
}

# Create namespace
create_namespace() {
    info "Creating namespace vault..."
    
    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
    
    info "✅ Namespace created"
}

# Generate TLS certificates (self-signed untuk dev)
generate_tls_certs() {
    if [ "$ENV" = "dev" ]; then
        info "Generating self-signed TLS certificates untuk dev..."
        
        # Generate CA
        openssl genrsa -out ca.key 2048
        openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -out ca.crt \
            -subj "/C=US/ST=State/L=City/O=Org/CN=Vault CA"
        
        # Generate server cert
        openssl genrsa -out tls.key 2048
        openssl req -new -key tls.key -out tls.csr \
            -subj "/C=US/ST=State/L=City/O=Org/CN=vault.vault.svc.cluster.local"
        
        # Sign with CA
        openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
            -out tls.crt -days 365 -sha256
        
        # Create Kubernetes secret
        kubectl -n vault create secret generic vault-tls \
            --from-file=ca.crt=ca.crt \
            --from-file=tls.crt=tls.crt \
            --from-file=tls.key=tls.key \
            --dry-run=client -o yaml | kubectl apply -f -
        
        # Cleanup
        rm -f ca.key ca.crt ca.srl tls.key tls.crt tls.csr
        
        info "✅ TLS certificates generated"
    else
        warn "Production mode: pastikan TLS certificates sudah ada di secret vault-tls"
    fi
}

# Install Vault via Helm
install_vault() {
    info "Installing Vault via Helm..."
    
    # Add HashiCorp repo
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update
    
    # Install/upgrade Vault
    if [ "$ENV" = "dev" ]; then
        # Dev mode: simplified config
        helm upgrade --install vault hashicorp/vault \
            --namespace vault \
            --set server.dev.enabled=true \
            --set server.dev.devRootToken=*** \
            --set ui.enabled=true \
            --wait
    else
        # Production mode: HA with Raft
        helm upgrade --install vault hashicorp/vault \
            --namespace vault \
            -f vault-values.yaml \
            --wait
    fi
    
    info "✅ Vault installed"
}

# Initialize Vault (production only)
initialize_vault() {
    if [ "$ENV" = "prod" ]; then
        warn "Production mode detected!"
        echo ""
        echo "Vault perlu di-initialize dan unseal secara manual:"
        echo ""
        echo "  1. Exec ke pod:"
        echo "     kubectl -n vault exec -it vault-0 -- sh"
        echo ""
        echo "  2. Initialize (SEKALI saja!):"
        echo "     vault operator init -key-shares=5 -key-threshold=3"
        echo ""
        echo "  3. SIMPAN unseal keys dan root token di tempat aman!"
        echo ""
        echo "  4. Unseal (butuh 3 dari 5 keys):"
        echo "     vault operator unseal <key-1>"
        echo "     vault operator unseal <key-2>"
        echo "     vault operator unseal <key-3>"
        echo ""
        echo "  5. Repeat untuk vault-1 dan vault-2"
        echo ""
        warn "Press Enter setelah initialize & unseal selesai..."
        read -r
    else
        info "Dev mode: Vault sudah auto-initialized"
    fi
}

# Configure Vault
configure_vault() {
    info "Configuring Vault..."
    
    # Get Vault pod
    VAULT_POD=$(kubectl -n vault get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
    
    if [ "$ENV" = "dev" ]; then
        export VAULT_TOKEN=***     else
        warn "Gunakan root token untuk konfigurasi awal"
        echo -n "Enter root token: "
        read -rs VAULT_TOKEN
        echo ""
        export VAULT_TOKEN
    fi
    
    # Enable KV v2
    info "Enabling KV v2 secrets engine..."
    kubectl -n vault exec $VAULT_POD -- vault secrets enable -path=secret kv-v2 || true
    
    # Enable Kubernetes auth
    info "Enabling Kubernetes auth method..."
    kubectl -n vault exec $VAULT_POD -- vault auth enable kubernetes || true
    
    # Configure Kubernetes auth
    kubectl -n vault exec $VAULT_POD -- sh -c '
        vault write auth/kubernetes/config \
            kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
            token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
    '
    
    # Create example policy
    info "Creating example policy..."
    kubectl -n vault exec $VAULT_POD -- sh -c 'cat <<EOF | vault policy write myapp-policy -
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
EOF'
    
    # Create Kubernetes role
    info "Creating Kubernetes auth role..."
    kubectl -n vault exec $VAULT_POD -- vault write auth/kubernetes/role/myapp \
        bound_service_account_names=myapp \
        bound_service_account_namespaces=default \
        policies=myapp-policy \
        ttl=1h
    
    # Create example secret
    info "Creating example secret..."
    kubectl -n vault exec $VAULT_POD -- vault kv put secret/myapp/config \
        db_password="example-password" \
        api_key="example-api-key"
    
    info "✅ Vault configured"
}

# Install External Secrets Operator
install_external_secrets() {
    info "Installing External Secrets Operator..."
    
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets-system \
        --create-namespace \
        --wait
    
    info "✅ External Secrets Operator installed"
}

# Deploy example app
deploy_example_app() {
    info "Deploying example application..."
    
    # Apply External Secrets config
    kubectl apply -f external-secrets-config.yaml
    
    info "✅ Example app deployed"
    
    echo ""
    info "Verify dengan:"
    echo "  kubectl get externalsecret -n default"
    echo "  kubectl get secret myapp-secrets -n default"
}

# Print summary
print_summary() {
    echo ""
    echo "=================================================="
    echo "✅ Deployment Complete!"
    echo "=================================================="
    echo ""
    echo "Vault UI:"
    if [ "$ENV" = "dev" ]; then
        echo "  kubectl -n vault port-forward svc/vault-ui 8200:8200"
        echo "  Open: http://localhost:8200"
        echo "  Token: ***"
    else
        echo "  kubectl -n vault port-forward svc/vault-ui 8200:8200"
        echo "  Open: http://localhost:8200"
        echo "  Token: <your-root-token>"
    fi
    echo ""
    echo "Vault CLI:"
    echo "  export VAULT_ADDR=http://localhost:8200"
    echo "  export VAULT_TOKEN=<your-token>"
    echo "  vault status"
    echo ""
    echo "Logs:"
    echo "  kubectl -n vault logs -f vault-0"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    create_namespace
    
    if [ "$ENV" = "dev" ]; then
        generate_tls_certs
    fi
    
    install_vault
    initialize_vault
    configure_vault
    install_external_secrets
    deploy_example_app
    print_summary
}

main
