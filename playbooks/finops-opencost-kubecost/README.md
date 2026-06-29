# FinOps: Multi-Cloud Cost Management dengan OpenCost & Kubecost

## 📊 Overview

FinOps (Financial Operations) adalah praktik cloud financial management yang menggabungkan sistem, best practices, dan budaya untuk meningkatkan cost visibility dan optimization di cloud-native environment. Playbook ini fokus pada implementasi real-time cost monitoring, attribution, dan optimization untuk Kubernetes clusters menggunakan OpenCost (CNCF) dan Kubecost.

## 🎯 Masalah yang Diselesaikan

### Problem Statement
- **Blind Spending**: Team tidak tahu berapa cost workload mereka
- **No Accountability**: Tidak ada ownership atas cloud spending
- **Manual Reports**: Cost reporting manual via billing dashboard, delayed 24-48 jam
- **Wasted Resources**: Over-provisioned pods, idle resources tidak terdeteksi
- **Multi-Cloud Chaos**: AWS, GCP, Azure billing terpisah, sulit compare

### Impact
- 30-40% cloud spending adalah waste (idle resources, over-provisioning)
- Rata-rata 6-8 jam/week engineer time untuk manual cost analysis
- Cost anomalies terdeteksi setelah akhir bulan (terlambat)

## 🏗️ Arsitektur Solusi

```
┌─────────────────────────────────────────────────────┐
│                  FinOps Platform                     │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌──────────────┐      ┌──────────────┐             │
│  │   OpenCost   │      │   Kubecost   │             │
│  │  (CNCF OSS)  │      │ (Enterprise) │             │
│  └──────┬───────┘      └──────┬───────┘             │
│         │                     │                      │
│         └──────────┬──────────┘                      │
│                    │                                 │
│         ┌──────────▼──────────┐                      │
│         │  Prometheus TSDB    │                      │
│         │  (Cost Metrics)     │                      │
│         └──────────┬──────────┘                      │
│                    │                                 │
│    ┌───────────────┼───────────────┐                │
│    │               │               │                │
│ ┌──▼───┐      ┌───▼────┐    ┌────▼─────┐           │
│ │ AWS  │      │  GCP   │    │  Azure   │           │
│ │ CUR  │      │ BigQuery    │  Export  │           │
│ └──────┘      └────────┘    └──────────┘           │
│                                                       │
│         ┌─────────────────────┐                      │
│         │  Grafana Dashboards │                      │
│         │  - Cost per NS      │                      │
│         │  - Efficiency Score │                      │
│         │  - Anomaly Alerts   │                      │
│         └─────────────────────┘                      │
└─────────────────────────────────────────────────────┘
```

## 📦 Komponen

### 1. OpenCost
- **Open-source** cost monitoring (CNCF Sandbox project)
- Real-time Kubernetes cost allocation
- Per-pod, per-namespace, per-label granularity
- Multi-cloud pricing API integration

### 2. Kubecost (Optional)
- Enterprise features: showback/chargeback, unified multi-cluster view
- Automated rightsizing recommendations
- Anomaly detection & alerting
- Budget enforcement

### 3. Prometheus
- Time-series storage untuk cost metrics
- Retention: 30 days local, 1 year remote (Thanos/Mimir)

### 4. Grafana
- Visualization & alerting
- Pre-built dashboards untuk cost analysis

## 🚀 Implementation Guide

### Prerequisites
- Kubernetes cluster 1.24+ (EKS, GKE, AKS, atau on-prem)
- Prometheus operator installed
- kubectl & helm CLI
- Cloud provider billing export configured
- Terraform 1.5+

### Step 1: Setup Cloud Billing Export

#### AWS (Cost and Usage Report)
```bash
# Terraform akan create:
# - S3 bucket untuk CUR
# - IAM role untuk OpenCost access
# - CUR report definition

cd terraform/
terraform init
terraform plan -var="cloud_provider=aws"
terraform apply
```

Output akan berisi S3 bucket name dan IAM role ARN.

#### GCP (BigQuery Export)
```bash
# Enable di GCP Console:
# Billing > Billing Export > BigQuery Export
# Atau via Terraform:

terraform plan -var="cloud_provider=gcp"
terraform apply
```

#### Azure (Cost Export)
```bash
# Azure Cost Management > Exports
# Atau via Terraform:

terraform plan -var="cloud_provider=azure"
terraform apply
```

### Step 2: Install OpenCost

```bash
# Via Helm
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo update

# Install dengan custom values
helm install opencost opencost/opencost \
  --namespace opencost-system \
  --create-namespace \
  -f manifests/opencost-values.yaml

# Verify
kubectl get pods -n opencost-system
kubectl logs -n opencost-system -l app=opencost
```

**opencost-values.yaml** sudah include:
- Prometheus integration
- Cloud provider pricing API config
- Resource requests/limits
- ServiceMonitor untuk metrics scraping

### Step 3: Configure Cloud Provider Credentials

```bash
# AWS
kubectl create secret generic aws-billing \
  -n opencost-system \
  --from-literal=aws-access-key-id=${AWS_ACCESS_KEY_ID} \
  --from-literal=aws-secret-access-key=${AWS_SECRET_ACCESS_KEY} \
  --from-literal=s3-bucket=${CUR_BUCKET_NAME}

# GCP
kubectl create secret generic gcp-billing \
  -n opencost-system \
  --from-file=service-account.json=./gcp-sa-key.json \
  --from-literal=bigquery-dataset=${BQ_DATASET}

# Azure
kubectl create secret generic azure-billing \
  -n opencost-system \
  --from-literal=subscription-id=${AZURE_SUBSCRIPTION_ID} \
  --from-literal=tenant-id=${AZURE_TENANT_ID} \
  --from-literal=client-id=${AZURE_CLIENT_ID} \
  --from-literal=client-secret=${AZURE_CLIENT_SECRET}
```

### Step 4: Setup Cost Allocation Labels

Best practice: standardize labels across all resources.

```yaml
# manifests/namespace-labels.yaml
# Apply labels untuk cost attribution
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    team: platform
    cost-center: engineering
    environment: production
    app: ecommerce
---
apiVersion: v1
kind: Namespace
metadata:
  name: staging
  labels:
    team: platform
    cost-center: engineering
    environment: staging
    app: ecommerce
```

Apply ke semua pods via admission webhook atau pod defaults:

```bash
kubectl apply -f manifests/namespace-labels.yaml
kubectl apply -f manifests/pod-label-defaults.yaml
```

### Step 5: Deploy Grafana Dashboards

```bash
# Import pre-built dashboards
kubectl apply -f dashboards/opencost-dashboard.json
kubectl apply -f dashboards/finops-executive-dashboard.json
kubectl apply -f dashboards/cost-anomaly-dashboard.json

# Access Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80
# Open http://localhost:3000
```

Dashboards include:
1. **Cost per Namespace**: Real-time spend by team/project
2. **Efficiency Score**: CPU/Memory utilization vs cost
3. **Idle Resources**: Pods dengan usage <20%
4. **Cost Trends**: 7d/30d comparison, forecast
5. **Anomaly Detection**: Unexpected spend spikes

### Step 6: Setup Alerting

```bash
# Deploy Prometheus alerts
kubectl apply -f manifests/cost-alerts.yaml

# Configure notification channels (Slack, PagerDuty, email)
kubectl apply -f manifests/alertmanager-config.yaml
```

Alert rules:
- **Budget Exceeded**: Namespace cost >110% of monthly budget
- **Cost Spike**: >30% increase in 1 hour
- **Idle Resources**: Pod dengan CPU <5% for 24h
- **Expensive Pods**: Single pod >$100/day

### Step 7: Chargeback/Showback Implementation

```bash
# Generate monthly cost reports per team
./scripts/generate-chargeback-report.sh --month 2026-06 --team platform

# Output: CSV report dengan breakdown:
# - Compute cost (CPU, memory)
# - Storage cost (PV, PVC)
# - Network cost (egress, load balancer)
# - Shared cost allocation (overhead)
```

## 🎛️ Configuration Examples

### OpenCost Custom Pricing

Edit `manifests/opencost-values.yaml` untuk custom on-prem pricing:

```yaml
opencost:
  exporter:
    cloudProviderApiKey: "" # Kosongkan untuk on-prem
    customPricing:
      enabled: true
      # Custom pricing untuk bare-metal
      cpu: "0.031"  # $/core/hour
      memory: "0.004"  # $/GB/hour
      storage: "0.00005"  # $/GB/hour (SSD)
      storageClass:
        fast-ssd: "0.0002"
        standard-hdd: "0.00003"
```

### Multi-Cluster Aggregation

Untuk multi-cluster view, setup OpenCost di setiap cluster + Thanos/Prometheus federation:

```bash
# Install OpenCost di cluster-2
helm install opencost opencost/opencost \
  --namespace opencost-system \
  --create-namespace \
  -f manifests/opencost-values-cluster2.yaml

# Configure Thanos query untuk aggregate
kubectl apply -f manifests/thanos-query.yaml
```

### Budget Enforcement via Kyverno

```yaml
# manifests/budget-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-namespace-budget
spec:
  validationFailureAction: enforce
  rules:
  - name: check-namespace-cost
    match:
      resources:
        kinds:
        - Pod
    context:
    - name: namespaceCost
      apiCall:
        urlPath: "/api/v1/namespaces/{{request.namespace}}/cost"
        service: opencost.opencost-system:9003
    validate:
      message: "Namespace {{request.namespace}} exceeded monthly budget"
      deny:
        conditions:
        - key: "{{namespaceCost.totalCost}}"
          operator: GreaterThan
          value: 5000  # $5000/month budget
```

## 📊 Cost Allocation Models

### 1. Showback (Reporting Only)
Teams dapat lihat cost, tidak di-charge. Goal: awareness & optimization.

```bash
# Monthly showback report
./scripts/generate-showback-report.sh \
  --start 2026-06-01 \
  --end 2026-06-30 \
  --output-format pdf

# Send via email
./scripts/send-cost-report.sh \
  --recipients platform-team@company.com \
  --report showback-2026-06.pdf
```

### 2. Chargeback (Actual Billing)
Teams di-invoice untuk actual usage. Requires finance integration.

```bash
# Generate invoice
./scripts/generate-chargeback-report.sh \
  --team platform \
  --month 2026-06 \
  --format invoice \
  --cost-center ENG-001

# Export ke finance system (SAP, NetSuite, etc)
./scripts/export-to-erp.sh \
  --report chargeback-2026-06.csv \
  --erp-system netsuite \
  --credentials /secrets/netsuite-api-key
```

### 3. Hybrid Model
Shared infrastructure (monitoring, ingress) = showback
Application workloads = chargeback

```yaml
# Cost allocation config
costAllocation:
  sharedServices:
    - namespace: monitoring
      allocationMethod: proportional  # Split by cluster usage
    - namespace: ingress-nginx
      allocationMethod: equal  # Split equally across teams
  
  teamWorkloads:
    - namespace: app-platform
      team: platform
      allocationMethod: direct  # Direct charge
      budget: 5000  # $/month
    - namespace: app-ml
      team: data-science
      allocationMethod: direct
      budget: 12000
```

## 🔍 Monitoring & Troubleshooting

### Key Metrics

```promql
# Total cluster cost ($/hour)
sum(node_total_hourly_cost)

# Cost per namespace ($/day)
sum by (namespace) (
  container_cpu_allocation * on (node) group_left node_cpu_hourly_cost +
  container_memory_allocation_bytes / 1e9 * on (node) group_left node_ram_hourly_cost
) * 24

# Efficiency score (0-100)
100 * (
  avg(rate(container_cpu_usage_seconds_total[5m])) / 
  avg(container_cpu_allocation)
)

# Idle cost (resources allocated but not used)
sum(
  (container_cpu_allocation - container_cpu_usage) * node_cpu_hourly_cost +
  (container_memory_allocation_bytes - container_memory_usage_bytes) / 1e9 * node_ram_hourly_cost
)
```

### Common Issues

#### 1. Missing Cost Data
```bash
# Check OpenCost logs
kubectl logs -n opencost-system -l app=opencost --tail=100

# Verify cloud provider API connectivity
kubectl exec -n opencost-system deploy/opencost -- curl -v https://pricing.api.aws.com

# Check Prometheus metrics
kubectl port-forward -n opencost-system svc/opencost 9003:9003
curl http://localhost:9003/metrics | grep opencost
```

#### 2. Incorrect Pricing
```bash
# Refresh pricing data (OpenCost caches for 24h)
kubectl delete pod -n opencost-system -l app=opencost

# Verify pricing API
kubectl logs -n opencost-system -l app=opencost | grep "pricing update"

# Manual pricing override
kubectl edit configmap -n opencost-system opencost-config
# Update custom pricing section
```

#### 3. High Memory Usage (OpenCost)
```bash
# Default retention: 15 days
# Reduce if memory constrained
kubectl edit deployment -n opencost-system opencost

# Add env var:
- name: RETENTION_DAYS
  value: "7"
```

#### 4. Missing Cloud Billing Data
```bash
# AWS CUR delay: 24 hours
# Check S3 bucket
aws s3 ls s3://${CUR_BUCKET_NAME}/cur-data/ --recursive

# GCP BigQuery delay: 24-48 hours
bq query --nouse_legacy_sql "
SELECT MAX(export_time) 
FROM \`${PROJECT}.${DATASET}.gcp_billing_export_v1\`
"

# Force reconciliation
kubectl exec -n opencost-system deploy/opencost -- \
  curl -X POST http://localhost:9003/refreshPricing
```

## 🏆 Best Practices

### 1. Label Standardization
```yaml
# Required labels untuk semua resources
labels:
  team: <team-name>              # Owner
  cost-center: <cc-code>         # Finance code
  environment: <env>             # prod/staging/dev
  app: <app-name>                # Application
  component: <component>         # frontend/backend/db
```

Enforce via admission controller (Kyverno/OPA Gatekeeper).

### 2. Right-Sizing Strategy
```bash
# Run weekly right-sizing analysis
./scripts/analyze-rightsizing.sh --namespace production

# Output:
# - Over-provisioned pods (>50% idle)
# - Recommended requests/limits
# - Estimated savings

# Apply recommendations via VPA (Vertical Pod Autoscaler)
kubectl apply -f manifests/vpa-rightsizing.yaml
```

### 3. Cost Anomaly Detection
```yaml
# Alert on unexpected cost spikes
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cost-anomaly-detection
spec:
  groups:
  - name: cost-anomalies
    interval: 5m
    rules:
    - alert: NamespaceCostSpike
      expr: |
        (
          sum by (namespace) (rate(container_cost[1h]))
          /
          sum by (namespace) (avg_over_time(container_cost[7d]))
        ) > 1.5
      for: 30m
      annotations:
        summary: "Cost spike in namespace {{ $labels.namespace }}"
        description: "Current hourly cost is 50% higher than 7-day average"
```

### 4. Reserved Instance / Savings Plan Tracking
```bash
# Import RI/SP commitment data
./scripts/import-commitments.sh \
  --file aws-ri-inventory.csv \
  --provider aws

# Track utilization
curl http://localhost:9003/api/v1/savings/utilization
```

### 5. Cost Allocation for Shared Resources
```yaml
# Allocate shared ingress controller cost proportionally
costAllocation:
  sharedCost:
    - namespace: ingress-nginx
      allocationMethod: network  # By ingress traffic
      targetNamespaces:
        - production
        - staging
```

## 🚨 Pitfalls to Avoid

### ❌ Don't
1. **Mencoba 100% accuracy** — billing data delayed 24-48h, accept ±5% variance
2. **Over-optimize too early** — fokus ke workload dengan cost >$1000/month dulu
3. **Ignore shared costs** — monitoring, logging, ingress perlu di-allocate
4. **No ownership** — setiap namespace harus punya team owner
5. **Manual reporting** — automate weekly/monthly reports
6. **Ignore idle resources** — set PodDisruptionBudget untuk cegah over-replicas
7. **Skip budget alerts** — implement soft (80%) dan hard (100%) budget alerts

### ✅ Do
1. **Start simple** — deploy OpenCost, enable dashboards, educate teams
2. **Standardize labels** — enforce via admission controller
3. **Automate reports** — weekly showback, monthly chargeback
4. **Celebrate wins** — recognize teams yang optimize cost
5. **Iterate** — mulai showback → hybrid → full chargeback (6-12 bulan)
6. **Integrate finance** — export data ke ERP/finance system
7. **Right-size incrementally** — pakai VPA, monitor impact

## 📈 Success Metrics

Track FinOps maturity via:

```yaml
finopsMetrics:
  awareness:
    - metricName: "Cost Visibility Coverage"
      target: 100%
      current: "{{ (namespaces_with_labels / total_namespaces) * 100 }}%"
  
  optimization:
    - metricName: "Idle Resource Reduction"
      target: "<5%"
      current: "{{ idle_cost / total_cost * 100 }}%"
    
    - metricName: "Efficiency Score"
      target: ">70%"
      current: "{{ avg(cpu_usage / cpu_allocation) * 100 }}%"
  
  accountability:
    - metricName: "Teams with Budget"
      target: 100%
      current: "{{ teams_with_budget / total_teams * 100 }}%"
    
    - metricName: "Chargeback Adoption"
      target: 100%
      current: "{{ namespaces_chargeback / total_namespaces * 100 }}%"
```

## 🔗 Referensi

### Documentation
- [OpenCost Docs](https://www.opencost.io/docs/)
- [Kubecost Guide](https://docs.kubecost.com/)
- [FinOps Foundation](https://www.finops.org/)
- [CNCF FinOps Whitepaper](https://www.cncf.io/reports/finops-kubernetes/)

### Tools
- **OpenCost** (CNCF): https://github.com/opencost/opencost
- **Kubecost**: https://www.kubecost.com/
- **Infracost** (Terraform cost estimation): https://www.infracost.io/
- **Cloud Custodian** (Policy-based cost optimization): https://cloudcustodian.io/

### Cloud Provider Pricing APIs
- AWS Pricing API: https://pricing.api.aws.com
- GCP Cloud Billing API: https://cloud.google.com/billing/docs/apis
- Azure Retail Prices API: https://prices.azure.com/api/retail/prices

### Learning Resources
- [FinOps Certified Practitioner](https://learn.finops.org/)
- [AWS Cost Optimization](https://aws.amazon.com/pricing/cost-optimization/)
- [GCP Cost Management Best Practices](https://cloud.google.com/cost-management)
- [Azure Cost Management + Billing](https://azure.microsoft.com/en-us/pricing/cost-management/)

## 📝 Example Use Cases

### Use Case 1: Multi-Tenant SaaS Platform
**Challenge**: 50 customers di shared cluster, perlu per-customer cost allocation

**Solution**:
```yaml
# Label by customer
labels:
  customer-id: "cust-12345"
  tier: "enterprise"  # pricing tier

# OpenCost allocation
costAllocation:
  groupBy: ["customer-id"]
  includeSharedCosts: true
  sharedCostSplitMethod: proportional
```

### Use Case 2: ML Training Workloads
**Challenge**: GPU instances mahal, perlu track cost per experiment

**Solution**:
```yaml
# Label by experiment
labels:
  experiment-id: "exp-2026-06-29-001"
  researcher: "data-science-team"
  gpu-type: "a100"

# Alert on long-running experiments
alert: ExperimentCostExceeded
expr: sum by (experiment_id) (gpu_cost) > 500  # $500 threshold
```

### Use Case 3: Multi-Cloud Cost Comparison
**Challenge**: Workloads di AWS & GCP, need apple-to-apple comparison

**Solution**:
```bash
# OpenCost normalize pricing across clouds
curl http://localhost:9003/api/v1/cost/compare \
  -d '{
    "clusters": ["aws-us-east-1", "gcp-us-central1"],
    "namespace": "production",
    "window": "7d"
  }'

# Output: normalized cost per CPU-hour, memory-GB-hour
```

## 🎓 Next Steps

1. **Week 1**: Deploy OpenCost, enable dashboards, educate teams
2. **Week 2-4**: Standardize labels, implement showback reports
3. **Month 2**: Setup alerting, anomaly detection
4. **Month 3**: Pilot chargeback dengan 1-2 teams
5. **Month 4-6**: Scale chargeback ke semua teams, integrate finance system
6. **Month 6+**: Continuous optimization, automated rightsizing

---

**Maintainer**: DevOps Platform Team  
**Last Updated**: 2026-06-29  
**Version**: 1.0.0  
**License**: MIT
