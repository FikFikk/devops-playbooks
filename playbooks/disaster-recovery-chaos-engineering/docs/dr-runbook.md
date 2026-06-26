# 🚨 DR Runbook — Panduan Emergency Response

> **PENTING**: Dokumen ini harus dibaca dan dipahami oleh seluruh anggota tim sebelum terjadi insiden. Jangan baca untuk pertama kali saat sedang panik.

---

## Quick Decision Matrix

```
ANDA MENGALAMI APA?
│
├── 🔴 Seluruh primary region down?
│   └── Goto: SKENARIO 1 — Region Failure
│
├── 🟠 Database corrupt/data loss?
│   └── Goto: SKENARIO 2 — Database Corruption
│
├── 🟡 Kubernetes cluster tidak bisa diakses?
│   └── Goto: SKENARIO 3 — Cluster Failure
│
├── ⚫ Suspected ransomware/breach?
│   └── Goto: SKENARIO 4 — Security Breach
│
├── 🟤 Satu AZ down?
│   └── Goto: SKENARIO 5 — AZ Failure
│
└── ❓ Tidak yakin?
    └── Goto: DIAGNOSTIK AWAL
```

---

## Diagnostik Awal

Jalankan checklist ini jika belum yakin skenario apa yang terjadi:

```bash
# 1. Cek konektivitas ke cluster
kubectl cluster-info

# 2. Cek status nodes
kubectl get nodes

# 3. Cek status pods di production
kubectl get pods -n production

# 4. Cek AWS region health
aws health describe-events --region ap-southeast-1

# 5. Cek Route 53 health check
aws route53 get-health-check-status --health-check-id <id>

# 6. Cek database status
aws rds describe-db-clusters --db-cluster-identifier myapp-primary-db

# 7. Cek DR status lengkap
./scripts/failover.sh --status
```

---

## SKENARIO 1: Region Failure {#region-failure}

### Gejala
- AWS Status Page menunjukkan outage di primary region
- Tidak bisa mengakses EC2, EKS, RDS di primary region
- Route 53 health check gagal
- Customer melaporkan layanan tidak bisa diakses

### RTO Target: 15 menit
### RPO Target: 5 menit (continuous replication)

### Langkah-langkah

#### ⏱️ Menit 0-2: Konfirmasi dan Komunikasi

```bash
# Konfirmasi region benar-benar down (bukan masalah lokal)
curl -s https://status.aws.amazon.com/ | grep "ap-southeast-1"

# Coba akses dari network berbeda
# Cek AWS Health Dashboard

# KOMUNIKASI: Kirim notifikasi ke tim
./scripts/failover.sh --status
```

**Kirim pesan ke Slack/PagerDuty:**
```
🚨 CONFIRMED: Primary region (ap-southeast-1) DOWN
   Initiating DR failover to ap-northeast-1
   ETA: 15 menit
   PIC: [nama anda]
   War room: [link]
```

#### ⏱️ Menit 2-5: Cek DR Readiness

```bash
# Verifikasi DR cluster accessible
kubectl --context=dr-cluster cluster-info

# Cek nodes
kubectl --context=dr-cluster get nodes

# Cek replication lag terakhir yang diketahui
# (mungkin tidak bisa query primary DB saat down)
```

#### ⏱️ Menit 5-10: Initiate Failover

```bash
# Jalankan automated failover
./scripts/failover.sh --initiate --target dr-region
```

Jika script gagal, lakukan manual:

```bash
# 1. Scale up DR nodes
aws eks update-nodegroup-config \
  --cluster-name myapp-dr \
  --nodegroup-name main \
  --scaling-config minSize=3,maxSize=10,desiredSize=5 \
  --region ap-northeast-1

# 2. Promote DR database
aws rds promote-read-replica-db-cluster \
  --db-cluster-identifier myapp-dr-db \
  --region ap-northeast-1

# 3. Tunggu DB available
aws rds wait db-cluster-available \
  --db-cluster-identifier myapp-dr-db \
  --region ap-northeast-1

# 4. Update app config dan restart
kubectl --context=dr-cluster -n production \
  set env deployment/backend-api \
  DB_HOST=myapp-dr-db.cluster-xxx.ap-northeast-1.rds.amazonaws.com

# 5. Restart deployments
kubectl --context=dr-cluster -n production rollout restart deployment --all
```

#### ⏱️ Menit 10-15: Verifikasi

```bash
# Cek pods running
kubectl --context=dr-cluster get pods -n production

# Health check
curl -v https://app.example.com/health

# Cek DNS sudah pointing ke DR
dig +short app.example.com

# Cek database accessible
kubectl --context=dr-cluster -n production exec -it deploy/backend-api -- \
  python -c "import psycopg2; print('DB OK')"
```

#### ⏱️ Setelah Stabil: Update Status

```
✅ FAILOVER COMPLETE
   Region: ap-northeast-1 (DR)
   Status: Operational (degraded capacity)
   Data loss: ~[X] seconds (replication lag terakhir)
   Affected: [daftar service]
   Next: Monitor + siapkan failback saat primary pulih
```

---

## SKENARIO 2: Database Corruption {#database-corruption}

### Gejala
- Error 500 di aplikasi terkait database query
- Data inconsistency dilaporkan oleh user
- PostgreSQL error logs menunjukkan data corruption

### RTO Target: 30 menit
### RPO Target: 5 menit (Point-in-Time Recovery)

### Langkah-langkah

```bash
# 1. ISOLASI: Matikan akses write ke database
kubectl -n production scale deployment/backend-api --replicas=0

# 2. Analisis kerusakan
kubectl -n production exec -it statefulset/postgresql -- \
  psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE state='active';"

# 3. Cek kapan corruption mulai terjadi
# Lihat log PostgreSQL
kubectl -n production logs statefulset/postgresql --since=2h | grep ERROR

# 4. Point-in-Time Recovery
# Tentukan waktu sebelum corruption (dari analisis log)
RESTORE_TIME="2024-01-15T14:30:00Z"

aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier myapp-primary-db \
  --db-cluster-identifier myapp-restored-$(date +%Y%m%d%H%M) \
  --restore-to-time "${RESTORE_TIME}" \
  --restore-type full-copy \
  --region ap-southeast-1

# 5. Tunggu restore selesai
aws rds wait db-cluster-available \
  --db-cluster-identifier myapp-restored-$(date +%Y%m%d%H%M) \
  --region ap-southeast-1

# 6. Verifikasi data di restored cluster
# (Connect langsung ke restored DB dan query data critical)

# 7. Swap database endpoint
kubectl -n production set env deployment/backend-api \
  DB_HOST=myapp-restored-XXX.cluster-xxx.ap-southeast-1.rds.amazonaws.com

# 8. Restore write access
kubectl -n production scale deployment/backend-api --replicas=3

# 9. Verifikasi aplikasi berjalan normal
```

---

## SKENARIO 3: Cluster Failure {#cluster-failure}

### Gejala
- `kubectl cluster-info` gagal
- Semua pods unreachable
- EKS API server tidak merespons

### RTO Target: 30 menit
### RPO Target: Sesuai backup terakhir

### Langkah-langkah

```bash
# 1. Cek apakah masalah EKS control plane atau worker nodes
aws eks describe-cluster --name myapp-primary --region ap-southeast-1

# 2. Jika control plane OK tapi nodes bermasalah:
aws eks describe-nodegroup \
  --cluster-name myapp-primary \
  --nodegroup-name main \
  --region ap-southeast-1

# Coba recycle node group
aws eks update-nodegroup-config \
  --cluster-name myapp-primary \
  --nodegroup-name main \
  --scaling-config minSize=0,maxSize=10,desiredSize=0 \
  --region ap-southeast-1

# Tunggu, lalu scale up
sleep 60
aws eks update-nodegroup-config \
  --cluster-name myapp-primary \
  --nodegroup-name main \
  --scaling-config minSize=3,maxSize=10,desiredSize=3 \
  --region ap-southeast-1

# 3. Jika control plane down → failover ke DR
./scripts/failover.sh --initiate --target dr-region

# 4. Atau restore dari Velero backup ke cluster baru
# Buat cluster baru (via Terraform)
cd terraform/
terraform apply -target=module.eks_primary

# Install Velero di cluster baru
velero install --provider aws ...

# Restore
velero restore create full-restore \
  --from-backup weekly-full-backup-latest \
  --restore-pvs
```

---

## SKENARIO 4: Security Breach / Ransomware {#security-breach}

### Gejala
- File ter-enkripsi oleh ransomware
- Akses tidak sah terdeteksi
- Data exfiltration alerts
- Unusual resource consumption

### ⚠️ PRIORITAS: CONTAINMENT, bukan recovery

### Langkah-langkah

```bash
# 1. 🔒 ISOLASI SEGERA — Jangan matikan, ISOLASI
./scripts/failover.sh --isolate primary

# Revoke semua access keys yang terkompromi
aws iam update-access-key --access-key-id AKIA... --status Inactive

# 2. Jangan connect ke DR dari jaringan yang terkompromi
# Gunakan out-of-band access (console langsung, backup laptop)

# 3. Preserve evidence — JANGAN delete atau clean up
# Snapshot semua EBS volumes
aws ec2 describe-instances --region ap-southeast-1 \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
  --output text | while read vol; do
    aws ec2 create-snapshot --volume-id "$vol" --description "forensic-$(date +%Y%m%d)"
done

# 4. Restore dari IMMUTABLE backup (Object Lock)
# Backup di S3 dengan Object Lock tidak bisa dimodifikasi/dihapus
velero restore create clean-restore \
  --from-backup weekly-full-backup-YYYYMMDD \
  --restore-pvs

# 5. Rotate SEMUA credentials
# - AWS IAM keys
# - Database passwords
# - API keys
# - TLS certificates
# - Kubernetes service account tokens

# 6. Contact: Security team, Management, Legal (jika ada data breach)
```

**JANGAN:**
- ❌ Bayar ransom
- ❌ Delete evidence
- ❌ Coba "fix" tanpa isolasi dulu
- ❌ Connect ke DR dari mesin yang mungkin terkompromi

---

## SKENARIO 5: AZ Failure {#az-failure}

### Gejala
- Beberapa pods/nodes down tapi tidak semua
- AWS melaporkan degraded performance di satu AZ
- Partial service degradation

### RTO Target: 5 menit (auto-recovery)
### RPO Target: 0 (tidak ada data loss)

### Langkah-langkah

```bash
# 1. Identifikasi AZ yang bermasalah
kubectl get nodes -o wide | head -20

# Cek node distribution per AZ
kubectl get nodes -L topology.kubernetes.io/zone

# 2. Kubernetes seharusnya auto-reschedule pods ke AZ lain
# Verifikasi PDB dan topology spread
kubectl get pdb -n production
kubectl get pods -n production -o wide

# 3. Jika auto-recovery tidak bekerja:
# Cordon nodes di AZ bermasalah
kubectl get nodes -l topology.kubernetes.io/zone=ap-southeast-1a \
  -o name | xargs -I{} kubectl cordon {}

# Drain pods dari AZ bermasalah
kubectl get nodes -l topology.kubernetes.io/zone=ap-southeast-1a \
  -o name | xargs -I{} kubectl drain {} --ignore-daemonsets --delete-emptydir-data

# 4. Scale up di AZ lain jika perlu
# Cluster Autoscaler seharusnya menangani ini otomatis

# 5. Setelah AZ pulih:
kubectl get nodes -l topology.kubernetes.io/zone=ap-southeast-1a \
  -o name | xargs -I{} kubectl uncordon {}
```

---

## Kontak Darurat

| Role | Nama | Contact |
|------|------|---------|
| On-Call Primary | [rotation] | PagerDuty |
| On-Call Secondary | [rotation] | PagerDuty |
| Engineering Manager | [nama] | [phone] |
| VP Engineering | [nama] | [phone] |
| Security Team | | security@company.com |
| AWS Support | | Enterprise Support ticket |

---

## Post-Incident

Setelah insiden selesai, wajib:

1. **Blameless Post-Mortem** dalam 48 jam
2. **Timeline** lengkap dari awal deteksi sampai recovery
3. **Ukur RTO/RPO actual** vs target
4. **Action items** dengan deadline dan PIC
5. **Update runbook** ini jika ada yang perlu diperbaiki
6. **Share learnings** ke seluruh engineering team

### Template Post-Mortem

```markdown
## Incident Report: [Title]
**Date**: YYYY-MM-DD
**Duration**: X hours Y minutes
**Severity**: P1/P2/P3
**PIC**: [nama]

### Timeline
- HH:MM - Event detected
- HH:MM - Response started
- HH:MM - Root cause identified
- HH:MM - Mitigation applied
- HH:MM - Service fully restored

### Root Cause
[Penjelasan teknis tanpa blame]

### Impact
- Users affected: X
- Revenue impact: $Y
- Data loss: Z records/minutes

### Recovery Metrics
- RTO Actual: XX minutes (target: YY minutes)
- RPO Actual: XX minutes (target: YY minutes)

### Action Items
| Item | Priority | PIC | Deadline |
|------|----------|-----|----------|
| | | | |

### Lessons Learned
1. Apa yang berjalan baik?
2. Apa yang bisa diperbaiki?
3. Apa yang beruntung kita lolos? (near misses)
```
