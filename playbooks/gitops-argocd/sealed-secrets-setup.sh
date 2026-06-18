#!/bin/bash
# ArgoCD Sealed Secrets Setup Script
# Install Sealed Secrets controller dan buat sample encrypted secret

set -e

NAMESPACE="kube-system"
VERSION="v0.24.0"

echo "🔐 Installing Sealed Secrets Controller"

# Install controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/controller.yaml

echo "⏳ Waiting for controller to be ready..."
kubectl wait --for=condition=ready pod \
    -l name=sealed-secrets-controller \
    -n $NAMESPACE \
    --timeout=300s

echo "✅ Sealed Secrets Controller installed!"

# Install kubeseal CLI
echo "📥 Installing kubeseal CLI..."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    wget https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/kubeseal-${VERSION#v}-linux-amd64.tar.gz
    tar xfz kubeseal-${VERSION#v}-linux-amd64.tar.gz
    sudo install -m 755 kubeseal /usr/local/bin/kubeseal
    rm kubeseal kubeseal-${VERSION#v}-linux-amd64.tar.gz
elif [[ "$OSTYPE" == "darwin"* ]]; then
    brew install kubeseal
fi

echo "✅ kubeseal CLI installed!"
echo ""
echo "🔑 Example usage:"
echo "  # Create a secret"
echo "  kubectl create secret generic mysecret --from-literal=password=mypassword --dry-run=client -o yaml | \\"
echo "    kubeseal -o yaml > mysealedsecret.yaml"
echo ""
echo "  # Apply to cluster (controller will decrypt it)"
echo "  kubectl apply -f mysealedsecret.yaml"
