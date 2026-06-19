#!/bin/bash
# Kubernetes Cost Monitoring dengan Kubecost
# Install Kubecost untuk Kubernetes cost visibility

set -e

echo "🚀 Installing Kubecost for Kubernetes Cost Monitoring"
echo "====================================================="
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

# Check helm
if ! command -v helm &> /dev/null; then
    echo "📦 Helm not found. Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "✓ Prerequisites satisfied"
echo ""

# Add Kubecost Helm repo
echo "📥 Adding Kubecost Helm repository..."
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm repo update

# Install Kubecost
NAMESPACE="kubecost"
RELEASE_NAME="kubecost"

echo "🔧 Installing Kubecost in namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $RELEASE_NAME kubecost/cost-analyzer \
    --namespace $NAMESPACE \
    --set kubecostToken="aGVsbUBrdWJlY29zdC5jb20=xm343yadf98" \
    --set prometheus.server.global.external_labels.cluster_id="my-cluster" \
    --set prometheus.server.persistentVolume.enabled=true \
    --set prometheus.server.persistentVolume.size=32Gi

echo ""
echo "✅ Kubecost installed successfully!"
echo ""
echo "🌐 Access Kubecost UI:"
echo "   kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090"
echo "   Open: http://localhost:9090"
echo ""
echo "📊 Key Features:"
echo "   • Cost allocation by namespace, deployment, pod, label"
echo "   • Real-time cost monitoring"
echo "   • Showback/chargeback reports"
echo "   • Resource efficiency metrics"
echo "   • Rightsizing recommendations"
echo ""
echo "📖 Documentation: https://docs.kubecost.com"
