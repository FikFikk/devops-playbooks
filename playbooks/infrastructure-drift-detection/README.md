# Infrastructure Drift Detection & Remediation

## Pengantar

**Infrastructure drift** adalah perbedaan antara konfigurasi infrastruktur yang sebenarnya berjalan di production dengan state yang dideklarasikan dalam Infrastructure as Code (IaC). Drift terjadi ketika ada perubahan manual langsung ke infrastruktur, baik disengaja (emergency hotfix) maupun tidak (misconfig, automation error, atau human error).

### Masalah yang Diselesaikan

1. **Konsistensi Infrastruktur**: Tanpa drift detection, infra production bisa berbeda dari yang didefinisikan di Git
2. **Audit & Compliance**: Sulit melacak siapa mengubah apa, kapan, dan kenapa
3. **Disaster Recovery**: State drift membuat disaster recovery plan tidak reliable
4. **Security Posture**: Perubahan security group atau IAM policy yang tidak terdeteksi menciptakan celah keamanan
5. **Reproducibility**: Drift membuat environment sulit di-reproduce (dev/staging vs production mismatch)

### Kapan Drift Terjadi

- Emergency hotfix langsung via console/CLI tanpa update IaC
- Automation tools lain (CloudFormation, AWS Config remediation) memodifikasi resources
- Manual scaling atau troubleshooting yang lupa di-revert
- Tag management dan labeling yang tidak konsisten
- Permissions drift di IAM/RBAC

## Strategi Deteksi Drift

### 1. Terraform State Diff (Native)

Terraform memiliki built-in drift detection:

```bash
# Basic drift check
terraform plan -refresh-only

# Detailed diff output
terraform plan -detailed-exitcode
# Exit code: 0 = no changes, 1 = error, 2 = changes detected

# Refresh state tanpa apply
terraform refresh
```

**Kelebihan**: Native, akurat, zero-cost
**Kekurangan**: Hanya detect resources yang dimanage Terraform, butuh credentials setiap run

### 2. Terraform Cloud / HCP Terraform Drift Detection

```hcl
# terraform.tf
terraform {
  cloud {
    organization = "my-org"
    workspaces {
      name = "production"
    }
  }
}

# Enable drift detection di Terraform Cloud
# Health Assessments → Drift Detection → Continuous
```

**Kelebihan**: Automated scheduling, Slack/email notifications, UI dashboard
**Kekurangan**: Paid tier untuk continuous drift detection

### 3. Open Source: Driftctl

[Driftctl](https://driftctl.com/) (discontinued, tapi masih berguna untuk reference) memberikan coverage report:

```bash
# Install
curl -L https://github.com/snyk/driftctl/releases/latest/download/driftctl_linux_amd64 -o driftctl
chmod +x driftctl

# Scan AWS
./driftctl scan --from tfstate+s3://bucket/terraform.tfstate --to aws+tf

# Output: resources unmanaged, missing, changed
```

### 4. Cloud-Native Tools

**AWS Config**: Detect configuration drift untuk AWS resources
**Azure Policy**: Guest configuration compliance
**GCP Config Controller**: K8s-style drift detection untuk GCP

### 5. Open Policy Agent (OPA) + Conftest

Enforce policies pada Terraform plan:

```rego
# policy/drift_policy.rego
package terraform.drift

deny[msg] {
  input.resource_changes[_].change.actions[_] == "update"
  msg = "Drift detected: resource akan di-update"
}

deny[msg] {
  input.resource_changes[_].change.actions[_] == "delete"
  msg = "Drift detected: resource missing dari infra"
}
```

```bash
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan | conftest test -p policy/ -
```

## Implementation Guide

### Step 1: Setup Terraform Remote State

Drift detection membutuhkan shared state yang reliable.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "production/infrastructure.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

**Alternatif backends**: Terraform Cloud, Consul, Azure Blob, GCS

### Step 2: Automated Drift Detection Script

```bash
#!/bin/bash
# scripts/detect-drift.sh

set -euo pipefail

WORKSPACE="${1:-production}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL}"

echo "🔍 Checking drift for workspace: $WORKSPACE"

cd "/path/to/terraform/$WORKSPACE"

# Initialize
terraform init -input=false -backend-config="key=$WORKSPACE/terraform.tfstate"

# Run plan in refresh-only mode
if terraform plan -refresh-only -detailed-exitcode -out=drift.tfplan; then
  echo "✅ No drift detected"
  exit 0
elif [ $? -eq 2 ]; then
  echo "⚠️  DRIFT DETECTED"
  
  # Generate readable diff
  terraform show drift.tfplan > drift-report.txt
  
  # Extract changed resources
  CHANGES=$(terraform show -json drift.tfplan | jq -r '
    .resource_changes[] | 
    select(.change.actions != ["no-op"]) | 
    "\(.address): \(.change.actions | join(", "))"
  ')
  
  # Send to Slack
  curl -X POST "$SLACK_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{
      \"text\": \"🚨 Infrastructure Drift Detected in $WORKSPACE\",
      \"blocks\": [
        {
          \"type\": \"section\",
          \"text\": {
            \"type\": \"mrkdwn\",
            \"text\": \"*Drift Report*\n\`\`\`$CHANGES\`\`\`\"
          }
        },
        {
          \"type\": \"actions\",
          \"elements\": [
            {
              \"type\": \"button\",
              \"text\": {\"type\": \"plain_text\", \"text\": \"View Details\"},
              \"url\": \"https://github.com/my-org/terraform/actions\"
            }
          ]
        }
      ]
    }"
  
  # Upload report sebagai artifact (CI/CD context)
  if [ -n "${CI:-}" ]; then
    echo "Uploading drift report..."
    # GitHub Actions
    echo "::set-output name=drift_detected::true"
  fi
  
  exit 1
else
  echo "❌ Terraform plan failed"
  exit 1
fi
```

### Step 3: GitHub Actions Scheduled Drift Check

```yaml
# .github/workflows/drift-detection.yml
name: Infrastructure Drift Detection

on:
  schedule:
    # Setiap hari jam 9 pagi WIB
    - cron: '0 2 * * *'
  workflow_dispatch: # Manual trigger

jobs:
  detect-drift:
    name: Check Drift - ${{ matrix.environment }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [production, staging]
      fail-fast: false
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789:role/GithubActionsTerraformRead
          aws-region: ap-southeast-1
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.8.0
      
      - name: Run Drift Detection
        id: drift
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
        run: |
          chmod +x scripts/detect-drift.sh
          ./scripts/detect-drift.sh ${{ matrix.environment }}
      
      - name: Upload Drift Report
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: drift-report-${{ matrix.environment }}
          path: drift-report.txt
          retention-days: 30
      
      - name: Create Issue on Drift
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const report = fs.readFileSync('drift-report.txt', 'utf8');
            
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: `🚨 Infrastructure Drift Detected: ${{ matrix.environment }}`,
              body: `## Drift Report\n\nEnvironment: **${{ matrix.environment }}**\nDetected: ${new Date().toISOString()}\n\n### Changes\n\`\`\`\n${report}\n\`\`\`\n\n### Action Required\n1. Review changes\n2. Update Terraform code if intended\n3. Run \`terraform apply\` to remediate if unintended\n\n---\n_Auto-generated by [drift-detection workflow](https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }})_`,
              labels: ['infrastructure', 'drift', 'priority:high']
            });
```

### Step 4: Remediation Strategies

**A. Automatic Remediation (Hati-hati!)**

```bash
#!/bin/bash
# scripts/auto-remediate.sh
# ⚠️ DANGER: Auto-apply hanya untuk non-critical resources

set -euo pipefail

ALLOWED_RESOURCES=(
  "aws_s3_bucket_versioning"
  "aws_s3_bucket_lifecycle_configuration"
  "aws_cloudwatch_log_group"
)

terraform plan -refresh-only -out=drift.tfplan

# Parse drift
DRIFTED=$(terraform show -json drift.tfplan | jq -r '
  .resource_changes[] | 
  select(.change.actions != ["no-op"]) | 
  .address
')

for resource in $DRIFTED; do
  resource_type=$(echo "$resource" | cut -d. -f1)
  
  if [[ " ${ALLOWED_RESOURCES[@]} " =~ " ${resource_type} " ]]; then
    echo "✅ Auto-remediating: $resource"
    terraform apply -target="$resource" -auto-approve
  else
    echo "⛔ Manual review required: $resource"
  fi
done
```

**B. Manual Remediation Workflow**

1. Review drift report
2. Investigasi: apakah perubahan disengaja?
   - Jika iya: Update Terraform code → commit → apply
   - Jika tidak: `terraform apply` untuk revert ke state yang diinginkan
3. Post-mortem: kenapa drift terjadi? Improve process

**C. Import Drift ke State (untuk perubahan yang ingin dipertahankan)**

```bash
# Contoh: ada SG rule baru yang ditambah manual, mau di-adopt
terraform import aws_security_group_rule.new_rule sg-12345_ingress_tcp_443_0.0.0.0/0

# Update code untuk match state
cat >> main.tf <<EOF
resource "aws_security_group_rule" "new_rule" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.main.id
}
EOF

terraform plan # Harusnya no changes
```

### Step 5: Drift Prevention

**1. Enforce IaC-Only Changes**

```json
// AWS SCP (Service Control Policy)
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateSecurityGroup",
        "rds:CreateDBInstance"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::123456789:role/TerraformExecutionRole",
            "arn:aws:iam::123456789:role/BreakGlassEmergencyRole"
          ]
        }
      }
    }
  ]
}
```

**2. Resource Tagging untuk Tracking**

```hcl
# terraform/locals.tf
locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Repository  = "github.com/my-org/infrastructure"
    Environment = var.environment
    Owner       = "platform-team"
    LastUpdated = timestamp()
  }
}

# Gunakan di semua resources
resource "aws_instance" "app" {
  ami           = "ami-12345"
  instance_type = "t3.medium"
  
  tags = merge(local.common_tags, {
    Name = "app-server"
  })
}
```

**3. AWS Config Rules untuk Detect Untagged Resources**

```hcl
# terraform/aws-config.tf
resource "aws_config_config_rule" "required_tags" {
  name = "required-tags-check"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "ManagedBy"
    tag2Key = "Environment"
  })

  depends_on = [aws_config_configuration_recorder.main]
}
```

## Monitoring & Alerting

### Metrics to Track

1. **Drift Frequency**: Berapa sering drift terjadi per environment
2. **Time to Remediation**: Waktu dari deteksi sampai resolved
3. **Drift by Resource Type**: Resource mana yang paling sering drift
4. **Manual Changes Count**: Jumlah perubahan manual per bulan

### Grafana Dashboard

```yaml
# grafana/drift-dashboard.json
{
  "dashboard": {
    "title": "Infrastructure Drift Monitoring",
    "panels": [
      {
        "title": "Drift Events (30d)",
        "targets": [
          {
            "expr": "sum(increase(terraform_drift_detected_total[30d])) by (environment)"
          }
        ]
      },
      {
        "title": "Unmanaged Resources",
        "targets": [
          {
            "expr": "terraform_unmanaged_resources_total"
          }
        ]
      }
    ]
  }
}
```

### Prometheus Exporter untuk Terraform

```python
# scripts/terraform_exporter.py
from prometheus_client import start_http_server, Gauge
import subprocess
import json
import time

drift_gauge = Gauge('terraform_drift_detected', 'Infrastructure drift detected', ['environment', 'workspace'])
unmanaged_gauge = Gauge('terraform_unmanaged_resources', 'Unmanaged resources count', ['environment'])

def check_drift(workspace):
    result = subprocess.run(
        ['terraform', 'plan', '-refresh-only', '-detailed-exitcode', '-json'],
        capture_output=True,
        text=True,
        cwd=f'/infra/{workspace}'
    )
    
    if result.returncode == 2:
        drift_gauge.labels(environment='production', workspace=workspace).set(1)
    else:
        drift_gauge.labels(environment='production', workspace=workspace).set(0)

if __name__ == '__main__':
    start_http_server(9090)
    while True:
        check_drift('production')
        check_drift('staging')
        time.sleep(3600)  # Check setiap jam
```

## Best Practices

### 1. Read-Only Drift Detection

Jangan auto-apply tanpa review. Drift detection harus read-only by default.

### 2. Separate Credentials

Gunakan read-only credentials untuk drift detection, write credentials hanya untuk apply.

```hcl
# IAM Policy untuk drift detection
data "aws_iam_policy_document" "drift_detector" {
  statement {
    actions = [
      "ec2:Describe*",
      "rds:Describe*",
      "s3:GetBucketPolicy",
      "iam:Get*",
      "iam:List*"
    ]
    resources = ["*"]
  }
}
```

### 3. Schedule Strategis

- **Production**: Daily pada off-peak hours
- **Staging**: Setiap 6 jam
- **Development**: Weekly (lebih toleran terhadap drift)

### 4. Tiered Response

- **Critical drift** (security groups, IAM): Immediate alert + manual review
- **Medium drift** (tags, lifecycle policies): Daily summary
- **Low drift** (descriptions, non-functional): Weekly report

### 5. Documentation

Setiap drift yang di-approve harus didokumentasikan:

```markdown
## Drift Log

### 2026-07-01: Production RDS Instance Size
**Drift**: `db.t3.medium` → `db.t3.large`
**Reason**: Emergency performance issue, approved by CTO
**Action**: Updated Terraform code in PR #456
**Status**: Resolved
```

## Pitfalls to Avoid

### ❌ Auto-Remediation Tanpa Review

**Jangan**: Langsung `terraform apply` saat detect drift

**Kenapa**: Perubahan manual bisa disengaja (emergency fix), auto-revert bisa break production

**Solusi**: Selalu review drift report, klasifikasikan, baru action

### ❌ Ignore Drift Reports

**Jangan**: "Drift report lagi, biarin aja"

**Kenapa**: Drift yang dibiarkan akumulasi, akhirnya IaC jadi tidak trustworthy

**Solusi**: SLA untuk remediation (contoh: critical drift < 4 jam, normal < 2 hari)

### ❌ False Positive Hell

**Jangan**: Alert untuk setiap perubahan kecil (timestamps, auto-generated IDs)

**Kenapa**: Alert fatigue, team mulai ignore semua alert

**Solusi**: Filter noise dengan lifecycle ignore_changes:

```hcl
resource "aws_instance" "app" {
  ami           = "ami-12345"
  instance_type = "t3.medium"
  
  lifecycle {
    ignore_changes = [
      tags["LastUpdated"],
      user_data_base64,  # Sering berubah karena secrets rotation
    ]
  }
}
```

### ❌ Drift Detection Tanpa Remediation Plan

**Jangan**: Setup drift detection tapi tidak ada proses untuk handle-nya

**Kenapa**: Alert tanpa action plan = noise

**Solusi**: Buat runbook remediation, assign on-call rotation

### ❌ Credentials Overprivileged

**Jangan**: Pakai admin credentials untuk drift detection

**Kenapa**: Security risk, drift detector tidak butuh write access

**Solusi**: Least privilege IAM role, read-only kecuali untuk remediation workflow

## Troubleshooting

### Issue: False Positives dari Computed Values

**Symptom**: Drift terdeteksi padahal tidak ada perubahan manual

**Cause**: Computed attributes (ARNs, IDs) berubah di refresh

**Solution**:
```hcl
lifecycle {
  ignore_changes = [
    arn,
    id,
    tags["LastModified"]
  ]
}
```

### Issue: State Lock Timeout

**Symptom**: `Error acquiring state lock` saat drift check

**Cause**: Apply lain sedang berjalan atau lock tidak ter-release

**Solution**:
```bash
# Check lock
terraform force-unlock <LOCK_ID>

# Atau implementasi timeout di script
terraform plan -lock-timeout=5m
```

### Issue: Credential Expiration

**Symptom**: Drift check gagal dengan `InvalidClientTokenId`

**Cause**: Temporary credentials expired (STS assume role)

**Solution**:
```bash
# Refresh credentials sebelum run
aws sts get-caller-identity

# Atau pakai credential_process di ~/.aws/config
[profile terraform]
credential_process = /usr/local/bin/aws-vault exec terraform --json
```

### Issue: Slow Drift Detection (>10 menit)

**Symptom**: Drift check timeout atau sangat lambat

**Cause**: Banyak resources, API rate limiting

**Solution**:
```hcl
# Split state files per layer
# backend-network.tf
backend "s3" {
  key = "production/network.tfstate"
}

# backend-compute.tf
backend "s3" {
  key = "production/compute.tfstate"
}

# Run drift check parallel per layer
```

## Tools & Resources

### Open Source Tools

- **[Terragrunt](https://terragrunt.gruntwork.io/)**: Wrapper untuk Terraform dengan drift detection helpers
- **[Atlantis](https://www.runatlantis.io/)**: Terraform PR automation, bisa detect drift di PR
- **[Spacelift](https://spacelift.io/)**: SaaS platform dengan built-in drift detection (free tier available)
- **[env0](https://www.env0.com/)**: Self-service IaC platform dengan drift detection

### Cloud-Native Services

- **AWS Config**: Configuration drift detection untuk AWS resources
- **Azure Policy Guest Configuration**: VM configuration drift
- **GCP Config Connector**: K8s-native drift detection untuk GCP
- **Terraform Cloud**: Built-in drift detection di paid plans

### Monitoring Integration

- **Datadog Terraform Integration**: Track Terraform runs & drift
- **Prometheus + Grafana**: Custom exporter untuk metrics
- **PagerDuty**: Alert routing untuk critical drift

## Contoh Implementasi Real-World

### Startup (< 50 resources)

- GitHub Actions scheduled job (daily)
- Slack notifications
- Manual remediation
- Cost: $0 (free tier semua tools)

### Scale-up (50-500 resources)

- Terraform Cloud Team plan
- Drift detection setiap 6 jam
- Automated remediation untuk approved resource types
- PagerDuty integration untuk critical drift
- Cost: ~$70/month (Terraform Cloud)

### Enterprise (> 500 resources)

- Self-hosted Atlantis + Terraform Enterprise
- Continuous drift detection
- Multi-environment, multi-region
- Automated remediation dengan approval workflow
- ServiceNow integration untuk change management
- Cost: ~$500-2000/month (platform + engineering time)

## Checklist Implementation

- [ ] Setup remote state backend dengan locking
- [ ] Buat drift detection script
- [ ] Implementasi scheduled check (GitHub Actions / Jenkins / Cron)
- [ ] Konfigurasi alerting (Slack / PagerDuty / Email)
- [ ] Define remediation runbook
- [ ] Setup read-only IAM credentials untuk detector
- [ ] Implement resource tagging standard
- [ ] Create drift remediation workflow
- [ ] Setup monitoring dashboard
- [ ] Document drift response SLA
- [ ] Train team tentang drift handling
- [ ] Quarterly review drift patterns & improve prevention

## Referensi

- [Terraform Drift Detection Best Practices](https://developer.hashicorp.com/terraform/tutorials/state/drift-detection)
- [AWS Config Rules](https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html)
- [Open Policy Agent Terraform](https://www.openpolicyagent.org/docs/latest/terraform/)
- [Infrastructure as Code Security Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/Infrastructure_as_Code_Security_Cheat_Sheet.html)

---

**Last Updated**: 2026-07-01
**Maintainer**: Hermes Agent
**Status**: Production Ready
