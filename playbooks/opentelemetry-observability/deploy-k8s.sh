#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenTelemetry Stack Deployment Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found. Please install kubectl first.${NC}"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}helm not found. Please install helm first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites met${NC}"
echo ""

# Create namespace
echo -e "${YELLOW}Creating observability namespace...${NC}"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace created${NC}"
echo ""

# Install cert-manager (required for OTel Operator)
echo -e "${YELLOW}Installing cert-manager...${NC}"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
echo -e "${GREEN}✓ Cert-manager installed${NC}"
echo ""

# Wait for cert-manager to be ready
echo -e "${YELLOW}Waiting for cert-manager to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
echo -e "${GREEN}✓ Cert-manager ready${NC}"
echo ""

# Add Helm repos
echo -e "${YELLOW}Adding Helm repositories...${NC}"
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
echo -e "${GREEN}✓ Helm repos added${NC}"
echo ""

# Install Prometheus Stack (includes Grafana)
echo -e "${YELLOW}Installing Prometheus Stack...${NC}"
helm install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f prometheus-values.yaml \
  --wait
echo -e "${GREEN}✓ Prometheus Stack installed${NC}"
echo ""

# Install Grafana Tempo
echo -e "${YELLOW}Installing Grafana Tempo...${NC}"
helm install tempo grafana/tempo \
  --namespace observability \
  -f tempo-values.yaml \
  --wait
echo -e "${GREEN}✓ Tempo installed${NC}"
echo ""

# Install Grafana Loki
echo -e "${YELLOW}Installing Grafana Loki...${NC}"
helm install loki grafana/loki-stack \
  --namespace observability \
  -f loki-values.yaml \
  --wait
echo -e "${GREEN}✓ Loki installed${NC}"
echo ""

# Deploy OpenTelemetry Collector
echo -e "${YELLOW}Deploying OpenTelemetry Collector...${NC}"
kubectl apply -f otel-collector-k8s.yaml
echo -e "${GREEN}✓ OTel Collector deployed${NC}"
echo ""

# Wait for all pods to be ready
echo -e "${YELLOW}Waiting for all pods to be ready...${NC}"
kubectl wait --for=condition=ready pod --all -n observability --timeout=600s
echo -e "${GREEN}✓ All pods ready${NC}"
echo ""

# Get Grafana password
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Grafana Login:${NC}"
echo "  Username: admin"
echo "  Password: $(kubectl get secret -n observability prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)"
echo ""
echo -e "${YELLOW}Access Grafana:${NC}"
echo "  kubectl port-forward -n observability svc/prometheus-stack-grafana 3000:80"
echo "  Then visit: http://localhost:3000"
echo ""
echo -e "${YELLOW}Access Prometheus:${NC}"
echo "  kubectl port-forward -n observability svc/prometheus-operated 9090:9090"
echo "  Then visit: http://localhost:9090"
echo ""
echo -e "${YELLOW}OTel Collector Endpoint:${NC}"
echo "  gRPC: otel-collector.observability.svc.cluster.local:4317"
echo "  HTTP: otel-collector.observability.svc.cluster.local:4318"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Instrument your applications with OpenTelemetry SDK"
echo "  2. Point them to: otel-collector.observability.svc.cluster.local:4317"
echo "  3. View traces in Grafana → Explore → Tempo"
echo "  4. View metrics in Grafana → Explore → Prometheus"
echo "  5. View logs in Grafana → Explore → Loki"
echo ""
