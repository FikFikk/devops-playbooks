#!/bin/bash
# ArgoCD Installation Script
# Usage: ./argocd-install.sh [method]
# method: manifests (default) atau helm

set -e

METHOD=${1:-manifests}
NAMESPACE="argocd"

echo "🚀 Installing ArgoCD using: $METHOD"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

# Create namespace
echo "📦 Creating namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

if [ "$METHOD" == "helm" ]; then
    # Install using Helm
    if ! command -v helm &> /dev/null; then
        echo "❌ helm not found. Please install helm first."
        exit 1
    fi
    
    echo "📦 Adding ArgoCD Helm repository"
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    echo "📦 Installing ArgoCD via Helm"
    helm install argocd argo/argo-cd \
        --namespace $NAMESPACE \
        --set server.service.type=LoadBalancer \
        --wait --timeout=10m

else
    # Install using manifests
    echo "📦 Installing ArgoCD via manifests"
    kubectl apply -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    echo "⏳ Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n $NAMESPACE \
        --timeout=600s
fi

echo "✅ ArgoCD installed successfully!"
echo ""
echo "🔑 Initial admin password:"
kubectl -n $NAMESPACE get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "Secret not found yet, wait a moment..."
echo ""
echo ""
echo "🌐 Access ArgoCD:"
echo "   Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Then open: https://localhost:8080"
echo ""
echo "📥 Install ArgoCD CLI:"
echo "   Linux: curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
echo "   macOS: brew install argocd"
