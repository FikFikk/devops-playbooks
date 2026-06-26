# 🔥 Disaster Recovery & Chaos Engineering Playbook

> **Panduan lengkap membangun strategi Disaster Recovery (DR) yang teruji dengan Chaos Engineering untuk memastikan ketahanan infrastruktur di lingkungan production.**

> **Level:** Intermediate–Advanced  
> **Estimasi Waktu:** 6–10 jam implementasi penuh  
> **Stack:** Kubernetes, Terraform, Litmus Chaos, Velero, AWS/GCP/Azure  

---

## 📑 Daftar Isi

- [Pendahuluan](#pendahuluan)
- [Masalah yang Diselesaikan](#masalah-yang-diselesaikan)
- [Konsep Inti](#konsep-inti)
- [Arsitektur DR](#arsitektur-dr)
- [Step-by-Step Implementation](#step-by-step-implementation)
  - [Fase 1: Multi-Region Infrastructure](#fase-1-multi-region-infrastructure)
  - [Fase 2: Backup & Restore dengan Velero](#fase-2-backup--restore-dengan-velero)
  - [Fase 3: Chaos Engineering dengan Litmus](#fase-3-chaos-engineering-dengan-litmus)
  - [Fase 4: Automated Failover](#fase-4-automated-failover)
  - [Fase 5: Monitoring & Alerting DR](#fase-5-monitoring--alerting-dr)
- [Eksperimen Chaos Engineering](#eksperimen-chaos-engineering)
- [DR Runbook](#dr-runbook)
- [Best Practices & Pitfalls](#best-practices--pitfalls)
- [Troubleshooting](#troubleshooting)
- [Referensi & Tool Recommendations](#referensi--tool-recommendations)

---

## Pendahuluan

Disaster Recovery (DR) dan Chaos Engineering adalah dua sisi mata uang yang sama: DR membangun kemampuan pemulihan dari bencana, sedangkan Chaos Engineering **membuktikan** bahwa kemampuan tersebut benar-benar bekerja sebelum bencana sesungguhnya terjadi.

### Mengapa Ini Penting di 2026?

- **Downtime mahal**: Rata-rata biaya downtime perusahaan enterprise mencapai $5.600/menit (Gartner).
- **Kompleksitas meningkat**: Arsitektur microservices dan multi-cloud membuat failure mode semakin sulit diprediksi.
- **Compliance ketat**: Regulasi seperti DORA (Digital Operational Resilience Act) di EU mewajibkan pengujian resilience berkala.
- **Customer expectation**: SLA 99.99% (52 menit downtime/tahun) sudah menjadi standar minimum.

---

## Masalah yang Diselesaikan

| Masalah | Dampak | Solusi |
|---------|--------|--------|
| Tidak ada rencana DR tertulis | Tim panik saat insiden, recovery lambat | DR Runbook + automated failover |
| Backup tidak pernah diuji restore-nya | Backup corrupt tidak terdeteksi sampai dibutuhkan | Scheduled restore testing |
| Single point of failure | Satu komponen gagal = seluruh sistem down | Multi-region + redundancy |
| "Works on my laptop" resilience | Asumsi sistem tahan gangguan tanpa bukti | Chaos experiments membuktikan ketahanan |
| MTTR (Mean Time To Recovery) tinggi | Downtime berkepanjangan | Automated failover + runbook drill |
| Tidak tahu failure boundaries | Tidak paham batas toleransi sistem | Steady-state hypothesis testing |

---

## Konsep Inti

### Recovery Objectives

```
RPO (Recovery Point Objective)
├── Berapa banyak data yang boleh hilang?
├── Contoh: RPO 1 jam = backup setiap jam
└── Makin kecil RPO = makin mahal (sync replication)

RTO (Recovery Time Objective)
├── Berapa lama boleh down sebelum recover?
├── Contoh: RTO 15 menit = automated failover wajib
└── Makin kecil RTO = makin kompleks
```

### DR Tiers

| Tier | Strategi | RPO | RTO | Biaya |
|------|----------|-----|-----|-------|
| Tier 1 | Backup & Restore | Jam | Jam | $ |
| Tier 2 | Pilot Light | Menit | 30 menit | $$ |
| Tier 3 | Warm Standby | Detik | Menit | $$$ |
| Tier 4 | Multi-Site Active/Active | ~0 | ~0 | $$$$ |

### Prinsip Chaos Engineering

Berdasarkan [Principles of Chaos Engineering](https://principlesofchaos.org/):

1. **Definisikan Steady State** — Apa perilaku normal sistem? (latency, error rate, throughput)
2. **Hipotesis** — "Sistem akan tetap di steady state meskipun X terjadi"
3. **Variasikan Event Dunia Nyata** — Simulasikan kegagalan yang realistis
4. **Jalankan di Production** — Mulai kecil, tapi targetnya adalah environment production
5. **Otomatisasi** — Jadikan bagian dari CI/CD pipeline
6. **Minimize Blast Radius** — Mulai dari scope kecil, perluas bertahap

---

## Arsitektur DR

```
┌──────────────────────────────────────────────────────────────────┐
│                    ARSITEKTUR DR MULTI-REGION                     │
├──────────────────────────┬───────────────────────────────────────┤
│     PRIMARY REGION       │         DR REGION                     │
│     (ap-southeast-1)     │        (ap-northeast-1)               │
│                          │                                       │
│  ┌─────────────────┐     │    ┌─────────────────┐               │
│  │   Route 53 /    │◄────┼───►│   Route 53 /    │               │
│  │   Cloud DNS     │     │    │   Cloud DNS     │               │
│  │  (Health Check) │     │    │  (Failover)     │               │
│  └───────┬─────────┘     │    └───────┬─────────┘               │
│          │               │            │                          │
│  ┌───────▼─────────┐     │    ┌───────▼─────────┐               │
│  │   ALB / NLB     │     │    │   ALB / NLB     │               │
│  └───────┬─────────┘     │    └───────┬─────────┘               │
│          │               │            │                          │
│  ┌───────▼─────────┐     │    ┌───────▼─────────┐               │
│  │  K8s Cluster    │     │    │  K8s Cluster    │               │
│  │  (Active)       │     │    │  (Standby/      │               │
│  │                 │     │    │   Warm)          │               │
│  │  ┌───────────┐  │     │    │  ┌───────────┐  │               │
│  │  │ App Pods  │  │     │    │  │ App Pods  │  │               │
│  │  │ (scaled)  │  │     │    │  │ (min)     │  │               │
│  │  └───────────┘  │     │    │  └───────────┘  │               │
│  └───────┬─────────┘     │    └───────┬─────────┘               │
│          │               │            │                          │
│  ┌───────▼─────────┐     │    ┌───────▼─────────┐               │
│  │  Database       │─────┼───►│  Database       │               │
│  │  (Primary)      │ rep │    │  (Read Replica)  │               │
│  └─────────────────┘     │    └─────────────────┘               │
│                          │                                       │
│  ┌─────────────────┐     │    ┌─────────────────┐               │
│  │  Velero Backup  │─────┼───►│  S3/GCS Bucket  │               │
│  │  (Scheduled)    │     │    │  (Cross-Region)  │               │
│  └─────────────────┘     │    └─────────────────┘               │
│                          │                                       │
│  ┌─────────────────┐     │                                       │
│  │  Litmus Chaos   │     │                                       │
│  │  Engine         │     │                                       │
│  └─────────────────┘     │                                       │
└──────────────────────────┴───────────────────────────────────────┘
```

---

## Step-by-Step Implementation

### Fase 1: Multi-Region Infrastructure

#### Prasyarat

```bash
# Tool yang dibutuhkan
terraform --version    # >= 1.7
kubectl version        # >= 1.29
helm version           # >= 3.14
velero version         # >= 1.13
litmusctl version      # >= 1.8
```

#### Provisioning dengan Terraform

Lihat file: [`terraform/main.tf`](terraform/main.tf)

File Terraform ini menyediakan:
- VPC multi-region dengan peering
- EKS cluster di primary dan DR region
- RDS dengan cross-region read replica
- S3 bucket dengan cross-region replication untuk backup
- Route 53 health check dan failover routing

```bash
# Deploy infrastructure
cd terraform/
terraform init
terraform plan -var-file=production.tfvars
terraform apply -var-file=production.tfvars
```

---

### Fase 2: Backup & Restore dengan Velero

Velero adalah tool standar untuk backup dan restore resource serta persistent volume Kubernetes.

#### Install Velero

```bash
# Install Velero di primary cluster
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backup-primary \
  --backup-location-config region=ap-southeast-1 \
  --snapshot-location-config region=ap-southeast-1 \
  --secret-file ./credentials-velero \
  --use-restic

# Verifikasi instalasi
velero get backup-locations
velero get snapshot-locations
```

#### Konfigurasi Backup Schedule

Lihat file: [`configs/velero-schedule.yaml`](configs/velero-schedule.yaml)

```bash
# Apply backup schedule
kubectl apply -f configs/velero-schedule.yaml

# Verifikasi schedule
velero get schedules

# Manual backup (untuk testing)
velero backup create manual-test-$(date +%Y%m%d) \
  --include-namespaces production,staging \
  --ttl 720h

# Cek status backup
velero backup describe manual-test-$(date +%Y%m%d)
```

#### Test Restore

```bash
# Restore ke cluster DR (pindah context dulu)
kubectl config use-context dr-cluster

# Restore dari backup terakhir
velero restore create --from-backup daily-production-backup-YYYYMMDD \
  --namespace-mappings production:dr-production

# Verifikasi
kubectl get pods -n dr-production
kubectl get pvc -n dr-production
```

Lihat script otomatis: [`scripts/test-restore.sh`](scripts/test-restore.sh)

---

### Fase 3: Chaos Engineering dengan Litmus

#### Install LitmusChaos

```bash
# Install Litmus ChaosCenter
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update

helm install litmus litmuschaos/litmus \
  --namespace litmus \
  --create-namespace \
  --set portal.frontend.service.type=LoadBalancer \
  --set portal.server.service.type=ClusterIP

# Tunggu sampai ready
kubectl wait --for=condition=ready pods --all -n litmus --timeout=300s

# Install Chaos Experiments
kubectl apply -f \
  https://hub.litmuschaos.io/api/chaos/3.8.0?file=charts/generic/experiments.yaml \
  -n litmus
```

#### Eksperimen Chaos

Lihat folder: [`experiments/`](experiments/)

**Eksperimen yang tersedia:**

| No | Eksperimen | File | Tujuan |
|----|-----------|------|--------|
| 1 | Pod Delete | `experiments/01-pod-delete.yaml` | Uji self-healing Kubernetes |
| 2 | Node Drain | `experiments/02-node-drain.yaml` | Simulasi node failure |
| 3 | Network Latency | `experiments/03-network-latency.yaml` | Uji toleransi latency |
| 4 | DNS Chaos | `experiments/04-dns-chaos.yaml` | Uji DNS failure handling |
| 5 | Disk Fill | `experiments/05-disk-fill.yaml` | Uji disk pressure handling |
| 6 | AZ Failure | `experiments/06-az-failure.yaml` | Simulasi kegagalan availability zone |

```bash
# Jalankan eksperimen pod-delete
kubectl apply -f experiments/01-pod-delete.yaml

# Monitor progress
kubectl get chaosresult -n production --watch

# Lihat detail hasil
kubectl describe chaosresult pod-delete-result -n production
```

---

### Fase 4: Automated Failover

#### DNS-Based Failover

Lihat file: [`terraform/main.tf`](terraform/main.tf) — section Route 53.

#### Application-Level Failover Script

Lihat file: [`scripts/failover.sh`](scripts/failover.sh)

```bash
# Inisiasi failover manual (jika automated failover belum trigger)
./scripts/failover.sh --initiate --target dr-region

# Failback setelah primary pulih
./scripts/failover.sh --failback --verify
```

---

### Fase 5: Monitoring & Alerting DR

#### Prometheus Rules untuk DR

Lihat file: [`monitoring/prometheus-dr-alerts.yaml`](monitoring/prometheus-dr-alerts.yaml)

#### Grafana Dashboard

Lihat file: [`monitoring/grafana-dr-dashboard.json`](monitoring/grafana-dr-dashboard.json)

Dashboard menampilkan:
- Status backup (sukses/gagal) per schedule
- RPO actual vs target
- RTO dari drill terakhir
- Chaos experiment results timeline
- Cross-region replication lag
- Health check status per region

---

## Eksperimen Chaos Engineering

### Bagaimana Menjalankan Game Day

Game Day adalah sesi terstruktur untuk menjalankan chaos experiments. Berikut prosesnya:

```
📅 GAME DAY WORKFLOW
═══════════════════

1. PERSIAPAN (1-2 hari sebelum)
   ├── Pilih eksperimen dari katalog
   ├── Definisikan steady-state metrics
   ├── Pastikan rollback plan siap
   ├── Notify stakeholder
   └── Pastikan on-call team aware

2. PRE-GAME CHECK (30 menit sebelum)
   ├── Cek semua monitoring dashboard
   ├── Verifikasi baseline metrics
   ├── Pastikan tidak ada deployment/maintenance lain
   └── Konfirmasi abort criteria

3. EKSEKUSI
   ├── Mulai recording (screen + metrics)
   ├── Jalankan eksperimen
   ├── Monitor real-time
   ├── Catat semua observasi
   └── Abort jika melewati threshold

4. POST-GAME (segera setelah)
   ├── Verifikasi system recovered
   ├── Review metrics
   ├── Document findings
   └── Create action items

5. RETROSPEKTIF (1-2 hari setelah)
   ├── Analisis root cause jika ada failure
   ├── Update runbook
   ├── Prioritaskan fix
   └── Schedule follow-up experiment
```

### Maturity Model Chaos Engineering

```
Level 0: AD HOC
├── Tidak ada chaos practice
├── Panic saat production incident
└── "Kita belum pernah test DR"

Level 1: REACTIVE
├── Manual chaos experiments sesekali
├── DR drill setahun sekali
└── Runbook ada tapi jarang di-update

Level 2: PROACTIVE (TARGET MINIMUM)
├── Scheduled chaos experiments bulanan
├── Automated backup testing
├── DR drill per kuartal
└── Runbook ter-update dan dilatih

Level 3: ADVANCED
├── Chaos experiments di CI/CD pipeline
├── Automated failover teruji
├── Continuous verification
└── Game days rutin

Level 4: EXPERT
├── Chaos di production (controlled)
├── Self-healing infrastructure
├── Automated remediation
└── Chaos as a service untuk semua tim
```

---

## DR Runbook

Lihat file lengkap: [`docs/dr-runbook.md`](docs/dr-runbook.md)

### Quick Reference

```
🚨 SKENARIO EMERGENCY
═════════════════════

SKENARIO 1: Primary Region Down
  → Jalankan: ./scripts/failover.sh --initiate --target dr-region
  → RTO Target: 15 menit
  → Checklist: docs/dr-runbook.md#region-failure

SKENARIO 2: Database Corruption
  → Jalankan: ./scripts/db-restore.sh --point-in-time "2024-01-15 14:30:00"
  → RPO Target: 5 menit (continuous WAL archiving)
  → Checklist: docs/dr-runbook.md#database-corruption

SKENARIO 3: Kubernetes Cluster Failure
  → Jalankan: velero restore create --from-backup latest-daily
  → RTO Target: 30 menit
  → Checklist: docs/dr-runbook.md#cluster-failure

SKENARIO 4: Ransomware / Security Breach
  → ISOLASI dulu: ./scripts/failover.sh --isolate primary
  → Restore dari immutable backup
  → Checklist: docs/dr-runbook.md#security-breach
```

---

## Best Practices & Pitfalls

### ✅ Best Practices

1. **Test backup restore SETIAP MINGGU**
   - Backup yang tidak pernah di-test = backup yang tidak ada
   - Otomatisasi test restore dan alert jika gagal

2. **Mulai chaos dari staging, BUKAN production**
   - Bangun kepercayaan diri tim dulu
   - Naik ke production hanya setelah 3+ kali sukses di staging

3. **Definisikan abort criteria SEBELUM eksperimen**
   - "Jika error rate > 5% selama > 2 menit, abort"
   - Assign satu orang sebagai "safety officer"

4. **Gunakan Infrastructure as Code untuk DR**
   - DR region harus bisa di-provision dari nol dalam jam, bukan hari
   - Terraform/Pulumi code harus identical antara primary dan DR

5. **Dokumentasi adalah bagian dari DR**
   - Runbook harus bisa diikuti oleh engineer yang baru join
   - Review dan update runbook setiap kuartal

6. **Immutable backups untuk ransomware protection**
   - S3 Object Lock / GCS Retention Policy
   - Separate AWS account untuk backup (air-gapped)

7. **RTO/RPO harus terukur dan divalidasi**
   - Ukur dari drill, bukan estimasi
   - Track trend RTO/RPO actual dari waktu ke waktu

### ❌ Pitfalls yang Harus Dihindari

1. **"Kita punya backup, jadi kita aman"**
   - ❌ Backup tanpa tested restore = false sense of security
   - ✅ Schedule automated restore test weekly

2. **DR plan hanya di dokumen, tidak pernah di-drill**
   - ❌ Dokumen 50 halaman yang tidak pernah dibaca
   - ✅ Quarterly DR drill dengan seluruh tim

3. **Chaos experiment tanpa steady-state definition**
   - ❌ "Kita delete pod dan lihat apa yang terjadi"
   - ✅ "Dengan pod dihapus, response time harus tetap < 200ms"

4. **Skip monitoring saat chaos experiment**
   - ❌ Jalankan chaos lalu cek setelah selesai
   - ✅ Real-time monitoring dengan dashboard dedicated

5. **Tidak memperhitungkan data consistency**
   - ❌ Failover tanpa cek data sync status
   - ✅ Verifikasi replication lag sebelum promote DR

6. **Single person dependency untuk DR**
   - ❌ Hanya satu orang yang tahu cara failover
   - ✅ Rotasi on-call, setiap orang pernah jalankan drill

7. **Chaos di production tanpa rollback plan**
   - ❌ "YOLO, let's break prod"
   - ✅ Blast radius terkontrol, abort criteria jelas, rollback otomatis

---

## Troubleshooting

### Velero Backup Gagal

```bash
# Cek logs Velero
kubectl logs -n velero deployment/velero --tail=100

# Common issues:
# 1. IAM permissions kurang
velero backup describe <backup-name> --details

# 2. PV snapshot gagal (CSI driver issue)
kubectl get volumesnapshotcontents
kubectl describe volumesnapshotcontent <name>

# 3. Backup terlalu besar / timeout
# → Tambahkan resource limits dan timeout
velero backup create mybackup \
  --include-namespaces production \
  --default-volumes-to-fs-backup \
  --item-operation-timeout 4h
```

### Litmus Experiment Stuck

```bash
# Cek ChaosEngine status
kubectl get chaosengine -n <namespace>
kubectl describe chaosengine <name> -n <namespace>

# Cek runner pod
kubectl get pods -n <namespace> | grep runner
kubectl logs <runner-pod> -n <namespace>

# Force cleanup jika stuck
kubectl delete chaosengine <name> -n <namespace>
kubectl delete pods -l chaosUID=<uid> -n <namespace>
```

### Failover Tidak Bekerja

```bash
# Cek Route 53 health check
aws route53 get-health-check-status --health-check-id <id>

# Cek DNS propagation
dig +short @8.8.8.8 app.example.com
dig +short @1.1.1.1 app.example.com

# Cek DR cluster readiness
kubectl --context=dr-cluster get nodes
kubectl --context=dr-cluster get pods -n production

# Cek database replication lag
aws rds describe-db-instances \
  --db-instance-identifier dr-replica \
  --query 'DBInstances[0].StatusInfos'
```

### Restore Gagal

```bash
# Cek restore status detail
velero restore describe <restore-name> --details

# Common fixes:
# 1. Namespace conflict (sudah ada)
velero restore create --from-backup <backup> \
  --namespace-mappings old-ns:new-ns

# 2. StorageClass tidak ada di target cluster
kubectl get sc
# → Buat StorageClass yang sama atau mapping

# 3. CRD belum ter-install
velero restore create --from-backup <backup> \
  --restore-crds
```

---

## Referensi & Tool Recommendations

### Tools Utama

| Tool | Fungsi | Link |
|------|--------|------|
| **Velero** | K8s backup & restore | https://velero.io |
| **LitmusChaos** | Chaos engineering platform | https://litmuschaos.io |
| **Chaos Mesh** | Alternatif chaos platform (CNCF) | https://chaos-mesh.org |
| **Gremlin** | Enterprise chaos engineering | https://gremlin.com |
| **AWS Fault Injection Service** | Managed chaos di AWS | https://aws.amazon.com/fis |
| **Terraform** | Infrastructure as Code | https://terraform.io |
| **Crossplane** | K8s-native IaC | https://crossplane.io |

### Bacaan Wajib

1. **"Chaos Engineering" oleh Casey Rosenthal & Nora Jones** — Bible of Chaos Engineering
2. **"Designing Data-Intensive Applications" oleh Martin Kleppmann** — Bab tentang replication & consistency
3. **"Site Reliability Engineering" oleh Google** — Bab 26: Data Integrity
4. **Netflix Tech Blog** — Chaos Monkey & FIT (Fault Injection Testing)
5. **AWS Well-Architected Framework — Reliability Pillar**
6. **Principles of Chaos Engineering** — https://principlesofchaos.org

### Standar & Framework

- **ISO 22301** — Business Continuity Management Systems
- **NIST SP 800-34** — Contingency Planning Guide
- **DORA (EU)** — Digital Operational Resilience Act
- **SOC 2 Type II** — Availability & Processing Integrity

---

## Struktur File

```
disaster-recovery-chaos-engineering/
├── README.md                              # Dokumen ini
├── terraform/
│   └── main.tf                            # Multi-region infrastructure
├── configs/
│   ├── velero-schedule.yaml               # Backup schedules
│   └── velero-bsl.yaml                    # Backup storage locations
├── experiments/
│   ├── 01-pod-delete.yaml                 # Pod delete chaos
│   ├── 02-node-drain.yaml                 # Node drain chaos
│   ├── 03-network-latency.yaml            # Network latency injection
│   ├── 04-dns-chaos.yaml                  # DNS failure simulation
│   ├── 05-disk-fill.yaml                  # Disk pressure test
│   └── 06-az-failure.yaml                 # AZ failure simulation
├── scripts/
│   ├── failover.sh                        # Automated failover script
│   ├── test-restore.sh                    # Backup restore testing
│   └── gameday-checklist.sh               # Pre-gameday verification
├── monitoring/
│   ├── prometheus-dr-alerts.yaml          # DR-specific alerts
│   └── grafana-dr-dashboard.json          # DR dashboard
└── docs/
    └── dr-runbook.md                      # Emergency runbook
```

---

> 💡 **Tips**: Mulailah dari Level 1 (backup testing) sebelum langsung ke chaos engineering. Bangun fondasi DR yang solid, baru tambahkan chaos experiments untuk menguji fondasinya.

> ⚠️ **Peringatan**: JANGAN jalankan chaos experiments di production tanpa persetujuan stakeholder, monitoring yang memadai, dan rollback plan yang teruji. Mulai SELALU dari staging/development environment.
