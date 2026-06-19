# Cloud Cost Optimization & FinOps

## Pendahuluan

Cost optimization adalah salah satu pilar utama dalam Cloud Well-Architected Framework. Penelitian menunjukkan bahwa 30-40% pengeluaran cloud terbuang karena resource yang tidak terpakai, oversized instances, dan kurangnya governance. Playbook ini memberikan panduan praktis untuk mengimplementasikan FinOps (Financial Operations) dalam infrastruktur cloud Anda.

## Masalah yang Diselesaikan

1. **Zombie Resources** - Resource yang berjalan tapi tidak digunakan
2. **Overprovisioning** - Instance yang terlalu besar untuk workload aktual
3. **Kurangnya Visibilitas** - Tidak tahu siapa yang spending berapa untuk apa
4. **Idle Resources** - Development/testing environments yang berjalan 24/7
5. **Storage Waste** - Snapshot lama, unattached volumes, incorrect storage classes
6. **Lack of Accountability** - Tidak ada ownership atas biaya

## Konsep Utama FinOps

### 1. Inform (Visibilitas)
Memberikan visibilitas real-time terhadap spending patterns dengan proper tagging dan cost allocation.

### 2. Optimize (Optimasi)
Implementasi best practices untuk mengurangi waste tanpa mengorbankan performa.

### 3. Operate (Operasi)
Continuous monitoring dan automation untuk memastikan optimasi berkelanjutan.

## Implementasi

### Phase 1: Cost Visibility & Tagging Strategy

#### Tagging Convention
```yaml
# Mandatory Tags
Environment: production|staging|development|testing
Owner: team-name
Project: project-identifier
CostCenter: department-budget-code
Application: app-name
ManagedBy: terraform|manual|cloudformation

# Optional but Recommended
Compliance: pci|hipaa|sox|none
DataClassification: public|internal|confidential|restricted
BackupPolicy: daily|weekly|none
AutoShutdown: enabled|disabled
```

#### AWS Cost Allocation Tags
Aktifkan User-Defined Cost Allocation Tags di AWS Billing Console untuk tracking granular.

### Phase 2: Resource Right-Sizing

#### Compute Right-Sizing
- Analisis CPU & Memory utilization rata-rata 2-4 minggu
- Target: CPU 40-60%, Memory 60-80% untuk production
- Gunakan AWS Compute Optimizer atau Azure Advisor

#### Storage Optimization
- Review unattached EBS volumes (billing tanpa usage)
- Lifecycle policies untuk S3/Blob storage
- Move infrequent access data ke cheaper tier (S3 IA, Glacier, Archive)

### Phase 3: Automated Scheduling

Shutdown non-production resources di luar jam kerja.

**Savings Estimation:**
- Development: 65% savings (8h/weekday usage)
- Testing: 75% savings (on-demand only)
- Staging: 50% savings (business hours only)

### Phase 4: Reserved Instances & Savings Plans

**Commitment Strategy:**
- Steady-state workloads: 1-year RI (40% discount)
- Long-term predictable: 3-year RI (60% discount)
- Variable workloads: Compute Savings Plans (flexible, 15-30% discount)

**Risk Mitigation:**
- Start with 50% commitment coverage
- Analyze 3-6 months of actual usage
- Increment by 10-20% quarterly

### Phase 5: Spot Instances for Fault-Tolerant Workloads

Workload yang cocok untuk Spot:
- Batch processing
- Big data analytics
- CI/CD build workers
- Machine learning training
- Stateless web servers dengan ASG

**Savings:** 70-90% vs on-demand

## Tools & Implementation

### 1. Terraform Cost Estimation (Infracost)

Infracost memberikan cost estimation sebelum apply infrastructure changes.

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh

# Setup
infracost auth login
infracost configure set currency IDR

# Usage
infracost breakdown --path .
infracost diff --path . --compare-to main
```

### 2. AWS Cost Anomaly Detection

Setup automated alerts untuk spending spikes.

### 3. Cloud Custodian (Policy as Code)

Automated enforcement untuk cost policies.

### 4. Kubecost (Kubernetes)

Real-time cost allocation per namespace, deployment, pod.

## Best Practices

### 1. Tag Everything
```hcl
# Terraform: Default tags untuk semua resources
provider "aws" {
  region = "ap-southeast-1"
  
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Environment = var.environment
      Project     = var.project_name
      Owner       = var.team_name
    }
  }
}
```

### 2. Implement Budget Alerts
- Set alerts di 50%, 80%, 100% of budget
- Weekly cost reports ke team leads
- Monthly breakdown per project/team

### 3. Automate Cleanup
- Unattached volumes > 7 days
- Snapshots > 90 days (kecuali yang di-tag retention)
- Unused elastic IPs
- Old AMIs/images

### 4. Development Environment Policies
- Auto-shutdown setelah jam kerja
- Weekend shutdown (Jumat malam - Senin pagi)
- Maximum instance sizes (no i3.16xlarge untuk dev!)

### 5. Optimize Data Transfer
- Use CloudFront/CDN untuk mengurangi egress costs
- VPC Endpoints untuk AWS services (avoid NAT Gateway charges)
- Compress data before transfer

## Monitoring & Dashboards

### Key Metrics
1. **Total Monthly Spend** - Trend bulan ke bulan
2. **Cost per Environment** - Production vs Non-Production ratio
3. **Cost per Service** - EC2, RDS, S3, Data Transfer breakdown
4. **Cost per Team** - Accountability tracking
5. **Waste Metrics** - Unused resources, idle time
6. **Savings Realized** - From RI, Spot, Scheduling

### Grafana Dashboard
- Real-time cost tracking
- Budget vs Actual
- Top 10 expensive resources
- Trend analysis

## Troubleshooting

### Issue: Biaya Tiba-Tiba Melonjak

**Diagnosis:**
```bash
# AWS CLI: Cek daily costs 7 hari terakhir
aws ce get-cost-and-usage \
  --time-period Start=2026-06-12,End=2026-06-19 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=SERVICE

# Cari resource yang baru dibuat
aws ec2 describe-instances \
  --filters "Name=launch-time,Values=2026-06-12T*" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,Tags[?Key==`Name`].Value|[0]]'
```

**Common Causes:**
- Instance type accidentally upgraded (t3.small → m5.4xlarge)
- Data transfer spike (check CloudWatch metrics)
- Accidental resource creation (loop/automation error)
- Snapshot/AMI accumulation

### Issue: Tagging Tidak Konsisten

**Solution:**
```python
# Script untuk enforce tagging (AWS Lambda)
# Auto-tag resources berdasarkan creator atau shut down untagged
```

Gunakan AWS Config Rules atau Azure Policy untuk enforcement.

### Issue: Team Tidak Aware dengan Biaya

**Solution:**
- Weekly cost report email otomatis per team
- Grafana dashboard publik di office TV
- Quarterly FinOps review meeting
- Gamifikasi: "Most Cost-Efficient Team" award

## Pitfalls to Avoid

### ❌ Over-Optimization
Jangan sacrifice performa production demi savings kecil. Production uptime > cost savings.

### ❌ No Baseline
Ukur dulu sebelum optimize. Tanpa baseline, Anda tidak tahu impact dari perubahan.

### ❌ Set & Forget
Cost optimization adalah continuous process, bukan one-time project.

### ❌ Ignoring Small Wins
$10/hari = $3,650/tahun. Small optimizations compound.

### ❌ No Accountability
Tanpa ownership, tidak ada yang peduli dengan biaya. Assign cost center ke teams.

### ❌ Premature Commitment
Jangan beli 3-year RI sebelum usage pattern stabil. Start conservative.

## Implementation Checklist

**Week 1: Discovery & Baseline**
- [ ] Enable AWS Cost Explorer / Azure Cost Management
- [ ] Export 3 bulan historical cost data
- [ ] Identify top 10 spending services
- [ ] Inventory semua resources

**Week 2: Quick Wins**
- [ ] Delete unattached volumes
- [ ] Delete old snapshots
- [ ] Release unused Elastic IPs
- [ ] Terminate stopped instances > 7 days

**Week 3: Tagging**
- [ ] Define tagging convention
- [ ] Script untuk bulk tagging existing resources
- [ ] Enable AWS Config for tag compliance
- [ ] Enforce tags di Terraform/IaC

**Week 4: Automation**
- [ ] Setup scheduler untuk dev/test environments
- [ ] Implement budget alerts
- [ ] Setup cost anomaly detection
- [ ] Create Grafana dashboard

**Month 2: Right-Sizing**
- [ ] Analyze 30-day utilization metrics
- [ ] Create right-sizing recommendations
- [ ] Execute changes di non-production first
- [ ] Measure savings

**Month 3: Advanced**
- [ ] Purchase Reserved Instances (conservative coverage)
- [ ] Implement Spot Instances for suitable workloads
- [ ] Setup S3 Intelligent-Tiering
- [ ] Implement Cloud Custodian policies

## Tools & Resources

### Open Source
- **Infracost** - Terraform cost estimation
- **Cloud Custodian** - Policy as code
- **Komiser** - Cloud environment inspector
- **Kubecost** - Kubernetes cost monitoring

### Cloud Native
- **AWS Cost Explorer** - Cost analysis & forecasting
- **AWS Compute Optimizer** - Right-sizing recommendations
- **Azure Cost Management** - Azure cost tracking
- **GCP Billing** - GCP cost breakdown

### SaaS (Premium)
- **CloudHealth** - Multi-cloud cost management
- **Cloudability** - FinOps platform
- **Spot.io** - Automated cloud optimization
- **Vantage** - Cloud cost transparency

## ROI Estimation

**Typical Savings by Category:**
- Zombie resources cleanup: 10-15%
- Right-sizing: 20-30%
- Reserved Instances: 30-50% on committed workloads
- Spot Instances: 70-90% on suitable workloads
- Auto-scheduling: 50-75% on non-production
- Storage optimization: 40-60%

**Total Expected Savings:** 30-50% of cloud bill dalam 6 bulan

**Example:**
- Current monthly bill: $50,000
- Target savings: 40%
- Monthly savings: $20,000
- Annual savings: $240,000

**Implementation Cost:**
- Engineering time: 2 engineers × 1 month = ~$30K
- Tools (if using SaaS): $2-5K/month
- **ROI:** Payback dalam 1-2 bulan

## Conclusion

Cost optimization bukan tentang berhemat secara membabi buta, tapi tentang **spending smart**. Investasi di infrastructure yang benar-benar digunakan, eliminate waste, dan maintain visibility untuk decision making yang informed.

FinOps adalah culture shift: semua orang bertanggung jawab atas cloud costs, bukan hanya finance team. Dengan tools, automation, dan accountability yang tepat, Anda bisa potong 30-50% cloud bill tanpa sacrifice performa.

## Next Steps

1. Review current cloud bill Anda
2. Jalankan cost analysis dengan tools di playbook ini
3. Prioritize quick wins (zombie resources, unattached volumes)
4. Implement tagging strategy
5. Setup monitoring dashboard
6. Schedule regular FinOps review meetings

**Remember:** Measure, optimize, automate, repeat.
