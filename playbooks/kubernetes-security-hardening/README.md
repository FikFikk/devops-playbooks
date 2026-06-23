# 🔒 Kubernetes Security Hardening Playbook

> **Topik:** Hardening keamanan cluster Kubernetes secara komprehensif  
> **Level:** Intermediate–Advanced  
> **Estimasi Waktu:** 4–8 jam implementasi penuh  
> **Terakhir Diperbarui:** Juni 2026

---

## 📋 Daftar Isi

1. [Pendahuluan & Mengapa Penting](#pendahuluan)
2. [Arsitektur Keamanan K8s](#arsitektur)
3. [RBAC (Role-Based Access Control)](#rbac)
4. [Pod Security Standards](#pod-security-standards)
5. [Network Policies](#network-policies)
6. [Secrets Management](#secrets-management)
7. [Image Security & Scanning](#image-security)
8. [Admission Controllers & OPA Gatekeeper](#admission-controllers)
9. [Runtime Security dengan Falco](#runtime-security)
10. [Audit Logging](#audit-logging)
11. [Monitoring & Alerting](#monitoring)
12. [Checklist Hardening](#checklist)
13. [Troubleshooting](#troubleshooting)
14. [Referensi](#referensi)

---

## 📖 Pendahuluan {#pendahuluan}

### Masalah yang Diselesaikan

Kubernetes secara default **tidak aman**. Konfigurasi default K8s mengutamakan kemudahan penggunaan daripada keamanan. Beberapa risiko nyata:

- **Container escape** – container mendapat akses ke host OS
- **Privilege escalation** – pod berhasil mendapatkan akses root cluster
- **Lateral movement** – pod yang terkompromi menyebar ke namespace lain
- **Supply chain attack** – image berbahaya dijalankan di cluster
- **Secrets exposure** – credential bocor via environment variables atau etcd

### Statistik Ancaman (2025–2026)

| Ancaman | Persentase Insiden |
|---------|-------------------|
| Misconfiguration | 67% |
| Supply chain attack | 42% |
| Excessive permissions | 58% |
| Unencrypted secrets | 39% |
| Missing network policies | 71% |

*Sumber: Cloud Native Security Report, CNCF 2025*

### Prinsip Dasar: Defense in Depth

```
┌───────────────────────────────────────────────────┐
│                  SUPPLY CHAIN                     │
│  (Image scanning, SBOM, signed images)            │
├───────────────────────────────────────────────────┤
│              ADMISSION CONTROL                    │
│  (OPA Gatekeeper, Kyverno, PSA)                   │
├───────────────────────────────────────────────────┤
│                    RBAC                           │
│  (Least privilege, Service Accounts)              │
├───────────────────────────────────────────────────┤
│              NETWORK POLICIES                     │
│  (Zero-trust networking, Calico/Cilium)           │
├───────────────────────────────────────────────────┤
│              RUNTIME SECURITY                     │
│  (Falco, seccomp, AppArmor)                       │
├───────────────────────────────────────────────────┤
│            AUDIT & OBSERVABILITY                  │
│  (Audit logs, metrics, alerts)                    │
└───────────────────────────────────────────────────┘
```

---

## 🏗️ Arsitektur Keamanan K8s {#arsitektur}

### Komponen yang Perlu Di-hardening

```
                    Internet
                       │
              ┌────────▼────────┐
              │   API Server    │◄── TLS, Auth, Authz, Audit
              │   (kube-api)    │
              └────────┬────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    ┌────▼────┐  ┌─────▼────┐  ┌────▼────┐
    │  etcd   │  │ kubelet  │  │  Nodes  │
    │(encrypt)│  │(restrict)│  │(CIS)    │
    └─────────┘  └──────────┘  └─────────┘
                       │
              ┌────────▼────────┐
              │    Workloads    │
              │  (PSS, RBAC,   │
              │  NetPol, Falco) │
              └─────────────────┘
```

---

## 👤 RBAC (Role-Based Access Control) {#rbac}

### Konsep RBAC

RBAC mengontrol siapa bisa melakukan apa terhadap resource K8s. Prinsip utama: **least privilege** (hanya berikan izin yang benar-benar diperlukan).

#### Hierarki RBAC

```
Subject (User/Group/ServiceAccount)
    │
    └── RoleBinding / ClusterRoleBinding
              │
              └── Role / ClusterRole
                        │
                        └── Rules (verbs + resources + apiGroups)
```

### Panduan Implementasi RBAC

#### Step 1: Audit Permission yang Ada

```bash
# Lihat semua ClusterRoleBinding
kubectl get clusterrolebindings -o wide

# Cari siapa yang punya akses cluster-admin
kubectl get clusterrolebindings -o json | \
  jq '.items[] | select(.roleRef.name == "cluster-admin") | 
  {name: .metadata.name, subjects: .subjects}'

# Audit permission ServiceAccount tertentu
kubectl auth can-i --list --as=system:serviceaccount:default:myapp
```

#### Step 2: Hapus Izin Berlebihan

```bash
# BAHAYA: Hapus binding cluster-admin yang tidak perlu
# (cek dulu sebelum hapus!)
kubectl delete clusterrolebinding <nama-binding>

# Hapus default ServiceAccount yang tidak dipakai
kubectl patch serviceaccount default -n <namespace> \
  -p '{"automountServiceAccountToken": false}'
```

### File Konfigurasi RBAC

Lihat direktori `rbac/` untuk implementasi lengkap:
- `rbac/developer-role.yaml` – Role untuk developer
- `rbac/readonly-role.yaml` – Role read-only untuk monitoring
- `rbac/ci-cd-role.yaml` – Role minimal untuk CI/CD pipeline
- `rbac/namespace-admin-role.yaml` – Admin terbatas per namespace

---

## 🛡️ Pod Security Standards (PSS) {#pod-security-standards}

### Penjelasan PSS

Mulai K8s 1.25, **PodSecurityPolicy (PSP) sudah deprecated** dan digantikan oleh **Pod Security Admission (PSA)** dengan tiga level:

| Level | Deskripsi |
|-------|-----------|
| `privileged` | Tidak ada restriksi (hanya untuk sistem) |
| `baseline` | Mencegah privilege escalation paling umum |
| `restricted` | Best practice keamanan tertinggi |

### Implementasi PSA per Namespace

```bash
# Label namespace dengan policy yang sesuai
# Mode: enforce (blokir), audit (log saja), warn (peringatan)

# Namespace production: restricted
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# Namespace staging: baseline
kubectl label namespace staging \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# Namespace system (kube-system): privileged (hati-hati!)
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged
```

### Contoh Pod Spec yang Aman (Restricted Level)

```yaml
# Lihat pod-security/secure-pod-template.yaml
```

---

## 🌐 Network Policies {#network-policies}

### Masalah Default K8s

Secara default, **semua pod bisa berkomunikasi dengan semua pod** di cluster. Ini sangat berbahaya jika ada pod yang terkompromi.

### Strategi Zero-Trust Networking

```
Tanpa Network Policy:          Dengan Network Policy:
                               
Pod A ──────────► Pod B        Pod A ──── ✗ ────► Pod B
Pod A ──────────► Pod C        Pod A ──── ✓ ────► Pod C (diizinkan)
Pod B ──────────► Pod C        Pod B ──── ✗ ────► Pod C
```

### Implementasi Bertahap

#### Step 1: Default Deny Semua Traffic

```bash
# Apply default-deny dulu di setiap namespace
kubectl apply -f network-policies/default-deny-all.yaml
```

#### Step 2: Buka Traffic yang Diperlukan Secara Eksplisit

```bash
kubectl apply -f network-policies/allow-frontend-to-backend.yaml
kubectl apply -f network-policies/allow-backend-to-db.yaml
kubectl apply -f network-policies/allow-monitoring.yaml
```

---

## 🔐 Secrets Management {#secrets-management}

### Masalah K8s Secrets Default

K8s Secrets secara default:
- **Hanya di-encode base64** (bukan dienkripsi!)
- Tersimpan di etcd tanpa enkripsi (secara default)
- Bisa dibaca siapapun yang punya akses ke namespace

### Solusi: Encrypt Secrets at Rest

```bash
# Aktifkan enkripsi etcd (edit kube-apiserver config)
# Lihat: policies/encryption-config.yaml

# Verifikasi enkripsi aktif
kubectl create secret generic test-secret \
  --from-literal=key=supersecret -n default

# Cek di etcd apakah terenkripsi
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get /registry/secrets/default/test-secret | hexdump -C | head
# Output harus menunjukkan "k8s:enc:aescbc:..." bukan teks biasa
```

### Alternatif Lebih Aman: External Secrets Operator

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Integrasikan dengan HashiCorp Vault atau AWS Secrets Manager
# Lihat: policies/external-secret-vault.yaml
```

---

## 🐳 Image Security & Scanning {#image-security}

### Praktik Terbaik Image

1. **Gunakan base image minimal** (distroless, Alpine)
2. **Jangan jalankan sebagai root** (`USER 1000`)
3. **Pin versi image** (jangan pakai `latest`)
4. **Scan image** sebelum deploy
5. **Sign image** dengan Cosign/Notary

### Tools Image Scanning

| Tool | Cara Pakai | Keunggulan |
|------|-----------|-----------|
| **Trivy** | CLI, CI/CD, K8s operator | Cepat, komprehensif |
| **Grype** | CLI, GitHub Actions | Akurat, false positive rendah |
| **Snyk** | SaaS, IDE plugin | Dev-friendly, auto-fix |
| **Clair** | Self-hosted API | Open source, scalable |

### Implementasi Trivy di CI/CD

```bash
# Scan image sebelum push
trivy image --exit-code 1 \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  myapp:latest

# Generate SBOM (Software Bill of Materials)
trivy image --format cyclonedx \
  --output sbom.json \
  myapp:latest

# Scan Kubernetes manifest
trivy config ./k8s-manifests/
```

### Dockerfile Aman

```dockerfile
# Lihat scanning/secure.Dockerfile
```

---

## 🚪 Admission Controllers & OPA Gatekeeper {#admission-controllers}

### Apa itu Admission Controller?

Admission controller adalah "penjaga pintu" yang memvalidasi atau memodifikasi request ke API Server **sebelum** resource dibuat.

```
Client Request
      │
      ▼
  API Server
      │
      ▼
Authentication → Authorization → Admission Control → etcd
                                       │
                              ┌────────┴────────┐
                              │                 │
                         Validating          Mutating
                         (tolak/izinkan)     (modifikasi)
```

### OPA Gatekeeper vs Kyverno

| Fitur | OPA Gatekeeper | Kyverno |
|-------|---------------|---------|
| Bahasa Policy | Rego | YAML |
| Kurva Belajar | Tinggi | Rendah |
| Komunitas | Besar | Berkembang |
| Generate Resource | Terbatas | Kuat |
| Mutasi | Ya | Ya |

### Install OPA Gatekeeper

```bash
# Install via Helm
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper/gatekeeper \
  --name-template=gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --set replicas=2

# Verifikasi
kubectl get pods -n gatekeeper-system
```

### Install Kyverno (Alternatif yang Lebih Mudah)

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno \
  -n kyverno \
  --create-namespace \
  --set replicaCount=3

# Lihat policies/kyverno-policies.yaml untuk policy siap pakai
```

---

## 🦅 Runtime Security dengan Falco {#runtime-security}

### Apa itu Falco?

Falco (CNCF project) adalah **runtime security tool** yang mendeteksi perilaku anomali di container berdasarkan system calls. Seperti antivirus untuk container.

### Contoh Ancaman yang Dideteksi Falco

```
✅ Shell terbuka di dalam container production
✅ File /etc/passwd dimodifikasi
✅ Network connection ke IP asing
✅ Container mencoba mount filesystem host
✅ Privilege escalation terdeteksi
✅ Crypto miner terdeteksi (high CPU + network)
```

### Instalasi Falco

```bash
# Install via Helm
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  --set driver.kind=ebpf

# Verifikasi Falco berjalan
kubectl get pods -n falco
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Falco initialized"
```

### Test Rule Falco

```bash
# Trigger test: buka shell di container (Falco akan alert!)
kubectl exec -it <pod-name> -- /bin/bash

# Cek di Falco log
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Notice"
```

---

## 📊 Audit Logging {#audit-logging}

### Kenapa Audit Log Penting?

Audit log merekam **semua request** ke K8s API Server. Penting untuk:
- Investigasi insiden keamanan
- Compliance (SOC2, ISO 27001, PCI-DSS)
- Deteksi aksi mencurigakan

### Konfigurasi Audit Policy

```bash
# Copy audit policy ke control plane
sudo cp policies/audit-policy.yaml /etc/kubernetes/audit-policy.yaml

# Edit kube-apiserver manifest
sudo nano /etc/kubernetes/manifests/kube-apiserver.yaml
# Tambahkan flags:
# --audit-log-path=/var/log/kubernetes/audit.log
# --audit-log-maxage=30
# --audit-log-maxbackup=10
# --audit-log-maxsize=100
# --audit-policy-file=/etc/kubernetes/audit-policy.yaml
```

### Query Audit Log yang Berguna

```bash
# Siapa yang menghapus resource?
cat /var/log/kubernetes/audit.log | jq \
  'select(.verb == "delete") | 
  {time: .requestReceivedTimestamp, user: .user.username, 
   resource: .objectRef.resource, name: .objectRef.name}'

# Akses ke secrets
cat /var/log/kubernetes/audit.log | jq \
  'select(.objectRef.resource == "secrets") | 
  {time: .requestReceivedTimestamp, user: .user.username, 
   verb: .verb, secret: .objectRef.name}'

# Login gagal / Unauthorized
cat /var/log/kubernetes/audit.log | jq \
  'select(.responseStatus.code == 403 or .responseStatus.code == 401)'
```

---

## 📈 Monitoring & Alerting {#monitoring}

### Metrics Keamanan yang Dipantau

```yaml
# Prometheus Alert Rules - lihat monitoring/security-alerts.yaml

# Key metrics:
# - Jumlah pod yang berjalan sebagai root
# - Jumlah pod dengan privileged: true
# - Falco events per severity
# - Failed authentication ke API Server
# - Exposed NodePort/LoadBalancer services
```

### Dashboard Grafana

Import dashboard ID berikut di Grafana:
- **15758** – Kubernetes Security Overview
- **13277** – Falco Security Events
- **14981** – OPA Gatekeeper Overview

---

## ✅ Checklist Hardening {#checklist}

### Control Plane

- [ ] API Server hanya mendengarkan di interface yang diperlukan
- [ ] Enkripsi etcd at rest diaktifkan
- [ ] Audit logging dikonfigurasi
- [ ] Anonymous auth dinonaktifkan (`--anonymous-auth=false`)
- [ ] RBAC diaktifkan (`--authorization-mode=RBAC`)
- [ ] Admission plugins diaktifkan (NodeRestriction, PodSecurity)
- [ ] TLS 1.2+ untuk semua komunikasi

### Worker Nodes

- [ ] kubelet tidak mengekspos API secara anonim
- [ ] `--protect-kernel-defaults=true`
- [ ] `--read-only-port=0` (nonaktifkan read-only port)
- [ ] Node di-hardening sesuai CIS Benchmark

### Workloads

- [ ] Semua namespace punya Pod Security label
- [ ] Default deny NetworkPolicy diterapkan
- [ ] Tidak ada pod yang jalankan sebagai UID 0 (root)
- [ ] `allowPrivilegeEscalation: false` di semua pod
- [ ] Resource requests dan limits disetel
- [ ] ServiceAccount token tidak di-automount jika tidak perlu
- [ ] Secrets di-inject via volume, bukan env var

### Supply Chain

- [ ] Image di-scan di CI/CD pipeline (tidak ada vuln HIGH/CRITICAL)
- [ ] Image di-sign dengan Cosign
- [ ] Hanya registry terpercaya yang diizinkan
- [ ] Base image menggunakan distroless atau Alpine

### RBAC

- [ ] Tidak ada user/SA yang bind ke `cluster-admin` tanpa alasan kuat
- [ ] Developer tidak punya akses `exec` ke production pods
- [ ] Service account setiap aplikasi punya Role minimal
- [ ] Akses `secrets` dibatasi hanya yang benar-benar butuh

### Monitoring

- [ ] Falco terinstal dan alert ke Slack/PagerDuty
- [ ] Audit log dikumpulkan ke SIEM
- [ ] Alert untuk aksi privileged mencurigakan
- [ ] Regular security scan (kube-bench, kubescape)

---

## 🔧 Troubleshooting {#troubleshooting}

### Pod Gagal Start Karena PSS

```bash
# Lihat event pod
kubectl describe pod <pod-name> -n <namespace>

# Error umum:
# "violates PodSecurity 'restricted:latest': 
#  allowPrivilegeEscalation != false"

# Solusi: Tambahkan securityContext yang sesuai
# Lihat pod-security/secure-pod-template.yaml
```

### NetworkPolicy Memblok Traffic yang Seharusnya Diizinkan

```bash
# Debug dengan temporary allow-all (JANGAN di prod!)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: debug-allow-all
  namespace: <namespace>
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress: [{}]
  egress: [{}]
EOF

# Test apakah traffic jalan dengan allow-all
# Jika jalan, berarti ada policy yang memblok
# Diagnosa lebih lanjut dengan Cilium/Calico network policy tool

# Hubungan antar pod dengan labels
kubectl get networkpolicies -n <namespace> -o yaml
kubectl get pods --show-labels -n <namespace>

# Hapus debug policy setelah selesai!
kubectl delete networkpolicy debug-allow-all -n <namespace>
```

### RBAC Forbidden Error

```bash
# Identifikasi error
# Error: "User cannot get resource pods in namespace default"

# Cek permission user/SA saat ini
kubectl auth can-i --list -n <namespace>
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa-name>

# Cari binding yang ada
kubectl get rolebindings,clusterrolebindings -A \
  -o custom-columns='KIND:kind,NAMESPACE:.metadata.namespace,
  NAME:.metadata.name,ROLE:.roleRef.name,
  SUBJECTS:.subjects[*].name' | grep <username-or-sa>
```

### Falco Menghasilkan Terlalu Banyak False Positive

```bash
# Lihat rules yang paling sering trigger
kubectl logs -n falco -l app.kubernetes.io/name=falco | \
  grep "Notice\|Warning\|Error" | \
  awk '{print $NF}' | sort | uniq -c | sort -rn | head 20

# Edit custom rules untuk exclude false positive
# Lihat: policies/falco-custom-rules.yaml
kubectl edit configmap falco-rules -n falco
```

### Periksa Kesehatan Security dengan kube-bench

```bash
# Jalankan CIS Kubernetes Benchmark
kubectl apply -f scripts/kube-bench-job.yaml
kubectl logs job/kube-bench

# Atau jalankan langsung di node
docker run --rm \
  --pid=host \
  --net=host \
  -v /etc:/etc:ro \
  -v /var:/var:ro \
  -v /usr/lib/systemd:/usr/lib/systemd:ro \
  -v /lib/systemd:/lib/systemd:ro \
  aquasec/kube-bench:latest
```

---

## 📚 Referensi {#referensi}

### Tool Utama

| Tool | URL | Fungsi |
|------|-----|--------|
| **Falco** | https://falco.org | Runtime security |
| **OPA Gatekeeper** | https://open-policy-agent.github.io/gatekeeper | Admission control |
| **Kyverno** | https://kyverno.io | Policy engine |
| **Trivy** | https://trivy.dev | Vulnerability scanning |
| **kube-bench** | https://github.com/aquasecurity/kube-bench | CIS benchmark |
| **Kubescape** | https://kubescape.io | Security posture |
| **Cosign** | https://github.com/sigstore/cosign | Image signing |

### Standar & Framework

- **CIS Kubernetes Benchmark** – https://www.cisecurity.org/benchmark/kubernetes
- **NSA/CISA K8s Hardening Guide** – https://media.defense.gov/2022/Aug/29/2003066362
- **NIST SP 800-190** (Container Security) – https://csrc.nist.gov/publications/detail/sp/800/190/final
- **CNCF Security Whitepaper** – https://github.com/cncf/tag-security

### Pembelajaran Lanjutan

- [Kubernetes Security Specialist (CKS)](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/)
- [KodeKloud CKS Course](https://kodekloud.com/courses/certified-kubernetes-security-specialist-cks/)
- [Kubernetes Goat](https://madhuakula.com/kubernetes-goat/) – Lab keamanan K8s yang disengaja vulnerable

---

*Playbook ini diperbarui secara berkala oleh agen DevOps Research otomatis.*  
*Laporan bug atau saran: buka issue di repository ini.*
