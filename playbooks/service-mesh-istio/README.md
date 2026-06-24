# 🕸️ Service Mesh dengan Istio — Panduan Lengkap Production

> **Tingkat:** Menengah–Lanjutan | **Estimasi Setup:** 2–4 jam | **Platform:** Kubernetes (1.24+)

---

## 📋 Daftar Isi

1. [Apa itu Service Mesh?](#apa-itu-service-mesh)
2. [Masalah yang Diselesaikan Istio](#masalah-yang-diselesaikan-istio)
3. [Arsitektur Istio](#arsitektur-istio)
4. [Prasyarat](#prasyarat)
5. [Instalasi Istio](#instalasi-istio)
6. [Traffic Management](#traffic-management)
7. [Security — mTLS & Authorization Policy](#security--mtls--authorization-policy)
8. [Observability — Metrics, Tracing, Logging](#observability--metrics-tracing-logging)
9. [Resiliensi — Circuit Breaker & Retry](#resiliensi--circuit-breaker--retry)
10. [Canary Deployment dengan Istio](#canary-deployment-dengan-istio)
11. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
12. [Best Practices](#best-practices)
13. [Pitfalls to Avoid](#pitfalls-to-avoid)
14. [Referensi & Tool Recommendations](#referensi--tool-recommendations)

---

## Apa itu Service Mesh?

**Service Mesh** adalah lapisan infrastruktur yang mengatur komunikasi *service-to-service* di dalam cluster Kubernetes. Alih-alih setiap aplikasi menangani sendiri logic jaringan (retry, timeout, TLS, tracing), service mesh memindahkan semua itu ke **sidecar proxy** yang berjalan di samping setiap pod.

```
┌─────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster                     │
│                                                         │
│  ┌──────────────┐          ┌──────────────┐             │
│  │  Service A   │          │  Service B   │             │
│  │  ┌────────┐  │          │  ┌────────┐  │             │
│  │  │  App   │  │          │  │  App   │  │             │
│  │  └───┬────┘  │          │  └───┬────┘  │             │
│  │  ┌───▼────┐  │  mTLS    │  ┌───▼────┐  │             │
│  │  │Envoy   │◄─┼──────────┼─►│Envoy   │  │             │
│  │  │Sidecar │  │          │  │Sidecar │  │             │
│  │  └────────┘  │          │  └────────┘  │             │
│  └──────────────┘          └──────────────┘             │
│                                                         │
│  ┌────────────────────────────────────┐                 │
│  │         Istio Control Plane        │                 │
│  │  Istiod (Pilot + Citadel + Galley) │                 │
│  └────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────┘
```

### Komponen Utama Istio

| Komponen | Fungsi |
|----------|--------|
| **Istiod** | Control plane tunggal: service discovery, certificate management, konfigurasi |
| **Envoy Proxy** | Sidecar di setiap pod — menangani semua traffic in/out |
| **Istio Ingress Gateway** | Entry point traffic dari luar cluster |
| **Istio Egress Gateway** | Kontrol traffic keluar cluster |

---

## Masalah yang Diselesaikan Istio

### ❌ Tanpa Service Mesh

```
Setiap developer harus coding sendiri:
- Retry logic di setiap service
- Circuit breaker implementation
- mTLS setup manual per-service
- Distributed tracing (inject header manual)
- Load balancing custom
- Canary deployment manual (perlu update config banyak tempat)
```

### ✅ Dengan Istio

```
Infrastructure menangani otomatis:
- Retry & timeout → deklaratif via VirtualService
- Circuit breaker  → DestinationRule
- mTLS otomatis   → PeerAuthentication (zero-trust by default)
- Tracing         → Envoy inject header otomatis
- Load balancing  → multiple algorithms tersedia
- Canary          → weight-based routing tanpa ubah kode
```

### Kasus Nyata yang Terpecahkan

1. **Cascading Failure** — Circuit breaker mencegah satu service failure menghancurkan semua
2. **Zero-Trust Security** — mTLS mutual authentication antar service tanpa ubah kode
3. **Canary Release Aman** — Routing 5% traffic ke v2, monitor, baru scale up
4. **Debug Microservices** — Distributed tracing otomatis tanpa code change
5. **Rate Limiting** — Lindungi downstream service dari overload

---

## Arsitektur

### Data Plane
- Setiap pod punya **Envoy sidecar** (`istio-proxy` container)
- Sidecar di-inject otomatis via **MutatingWebhookConfiguration**
- Semua traffic pod melewati Envoy (iptables redirect)

### Control Plane (Istiod)
```
Istiod
├── Pilot        → push config ke semua Envoy (xDS protocol)
├── Citadel      → issue & rotate certificates (SPIFFE/SPIRE)
└── Galley       → validasi dan distribusi konfigurasi
```

---

## Prasyarat

```bash
# Kubernetes cluster yang berjalan
kubectl version --short
# Minimal: Kubernetes 1.24+, 4 CPU, 8GB RAM di cluster

# Tools yang dibutuhkan
istioctl version   # Istio CLI
helm version       # Helm 3+
kubectl version    # kubectl
```

### Resource Requirements

| Environment | CPU | Memory | Storage |
|-------------|-----|--------|---------|
| Development | 2 core | 4 GB | 10 GB |
| Staging | 4 core | 8 GB | 50 GB |
| Production | 8+ core | 16+ GB | 100+ GB |

---

## Instalasi Istio

### Langkah 1 — Download dan Install istioctl

```bash
# Download Istio (versi terbaru stabil)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.23.0 sh -

# Tambahkan ke PATH
cd istio-1.23.0
export PATH=$PWD/bin:$PATH
echo 'export PATH=$HOME/istio-1.23.0/bin:$PATH' >> ~/.bashrc

# Verifikasi
istioctl version
```

### Langkah 2 — Pre-installation Check

```bash
# Cek kompatibilitas cluster
istioctl x precheck

# Output yang baik:
# ✔ No issues found when checking the cluster.
# Istio is safe to install or upgrade!
```

### Langkah 3 — Install dengan IstioOperator Profile

```bash
# Gunakan profile production (lihat configs/istio-operator.yaml)
istioctl install -f configs/istio-operator.yaml --verify

# Atau untuk development cepat:
istioctl install --set profile=demo -y
```

### Langkah 4 — Enable Sidecar Injection per Namespace

```bash
# Label namespace untuk auto-inject
kubectl label namespace default istio-injection=enabled
kubectl label namespace production istio-injection=enabled

# Verifikasi label
kubectl get namespace -L istio-injection
```

### Langkah 5 — Install Addons (Observability)

```bash
# Install Prometheus, Grafana, Jaeger, Kiali
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/jaeger.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/kiali.yaml

# Verifikasi semua komponen running
kubectl get pods -n istio-system
```

### Verifikasi Instalasi

```bash
# Cek status Istio
istioctl verify-install

# Cek sidecar di pod
kubectl get pod -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
# Setiap pod production → harusnya ada container "istio-proxy"
```

---

## Traffic Management

### Konsep Dasar

```
Istio Custom Resources untuk Traffic:

VirtualService  → "Kemana traffic dikirim & bagaimana caranya"
DestinationRule → "Bagaimana traffic diperlakukan di destination"
Gateway          → "Traffic masuk/keluar cluster"
ServiceEntry     → "Daftarkan external service ke mesh"
```

### Contoh: Basic VirtualService

Lihat file: [`configs/traffic/virtual-service-basic.yaml`](configs/traffic/virtual-service-basic.yaml)

### Contoh: Canary Deployment (90/10 split)

Lihat file: [`configs/traffic/canary-deployment.yaml`](configs/traffic/canary-deployment.yaml)

### Contoh: Timeout & Retry

Lihat file: [`configs/traffic/resilience-config.yaml`](configs/traffic/resilience-config.yaml)

---

## Security — mTLS & Authorization Policy

### Aktifkan mTLS Cluster-wide

```bash
# Strict mTLS — semua service HARUS pakai mTLS
kubectl apply -f configs/security/mtls-strict.yaml

# Verifikasi mTLS aktif
istioctl x check-inject -n production
istioctl authn tls-check <pod-name>.<namespace>
```

### Authorization Policy

```bash
# Terapkan zero-trust: deny all, lalu allow per-case
kubectl apply -f configs/security/authz-deny-all.yaml
kubectl apply -f configs/security/authz-allow-frontend.yaml
```

Lihat semua config: [`configs/security/`](configs/security/)

---

## Observability — Metrics, Tracing, Logging

### Akses Dashboard

```bash
# Kiali — Service Mesh Graph
istioctl dashboard kiali

# Grafana — Metrics Dashboard  
istioctl dashboard grafana

# Jaeger — Distributed Tracing
istioctl dashboard jaeger

# Prometheus — Raw Metrics
istioctl dashboard prometheus
```

### Distributed Tracing

Istio **otomatis** inject trace headers (B3/W3C) via Envoy. Aplikasi hanya perlu **meneruskan** header berikut:

```python
# Python FastAPI contoh — forward trace headers
TRACE_HEADERS = [
    "x-request-id",
    "x-b3-traceid",
    "x-b3-spanid", 
    "x-b3-parentspanid",
    "x-b3-sampled",
    "x-b3-flags",
    "x-ot-span-context",
    "traceparent",
    "tracestate",
]

@app.middleware("http")
async def forward_trace_headers(request: Request, call_next):
    headers = {h: request.headers[h] for h in TRACE_HEADERS if h in request.headers}
    # Sertakan headers ini saat panggil service lain
    response = await call_next(request)
    return response
```

```go
// Go — forward trace headers
func forwardHeaders(incoming *http.Request, outgoing *http.Request) {
    traceHeaders := []string{
        "x-request-id", "x-b3-traceid", "x-b3-spanid",
        "x-b3-parentspanid", "x-b3-sampled",
    }
    for _, h := range traceHeaders {
        if val := incoming.Header.Get(h); val != "" {
            outgoing.Header.Set(h, val)
        }
    }
}
```

---

## Resiliensi — Circuit Breaker & Retry

### Circuit Breaker Logic

```
STATE: CLOSED (normal)
    → jika error rate > threshold
STATE: OPEN (reject semua request)
    → setelah cooldown period
STATE: HALF-OPEN (coba 1 request)
    → jika sukses → CLOSED
    → jika gagal  → OPEN lagi
```

Konfigurasi: [`configs/traffic/circuit-breaker.yaml`](configs/traffic/circuit-breaker.yaml)

### Retry Policy

```yaml
# Retry hanya untuk kondisi yang aman (idempotent)
retries:
  attempts: 3
  perTryTimeout: 2s
  retryOn: "gateway-error,connect-failure,retriable-4xx"
  # JANGAN retry untuk: 5xx POST (non-idempotent), payment operations
```

---

## Canary Deployment dengan Istio

### Strategy: Progressive Rollout

```bash
# Fase 1: Deploy v2 tanpa traffic
kubectl apply -f examples/app-v2-deployment.yaml

# Fase 2: Kirim 5% traffic ke v2
kubectl apply -f configs/traffic/canary-5percent.yaml

# Monitor error rate v2
kubectl -n production exec -it deploy/prometheus -- \
  promtool query instant \
  'rate(istio_requests_total{destination_version="v2",response_code=~"5.."}[5m])'

# Fase 3: Jika OK, naik ke 20%
# Edit canary-deployment.yaml: weight v1=80, v2=20
kubectl apply -f configs/traffic/canary-deployment.yaml

# Fase 4: Full cutover
kubectl apply -f configs/traffic/canary-100percent.yaml

# Fase 5: Hapus v1
kubectl delete deployment app-v1
```

---

## Monitoring & Troubleshooting

### Perintah Diagnostik Penting

```bash
# 1. Cek status proxy semua pod
istioctl proxy-status

# 2. Dump konfigurasi Envoy di pod tertentu
istioctl proxy-config all <pod-name> -n <namespace>

# 3. Cek routing yang aktif di pod
istioctl proxy-config routes <pod-name> -n <namespace>

# 4. Cek clusters yang dikenal Envoy
istioctl proxy-config clusters <pod-name> -n <namespace>

# 5. Cek listeners Envoy
istioctl proxy-config listeners <pod-name> -n <namespace>

# 6. Analyze konfigurasi Istio — cari masalah
istioctl analyze -n production

# 7. Cek mTLS status antar service
istioctl authn tls-check <pod>.<namespace> <service>.<namespace>.svc.cluster.local

# 8. Tail log sidecar (Envoy)
kubectl logs <pod-name> -c istio-proxy -n <namespace> -f
```

### Troubleshooting Common Issues

#### Problem: Pod tidak mendapat sidecar

```bash
# Symptom: pod hanya 1/1, bukan 2/2
kubectl get pods -n production

# Diagnosa
kubectl get namespace production -L istio-injection
# Kalau tidak ada label atau label=disabled → itulah penyebabnya

# Fix
kubectl label namespace production istio-injection=enabled
kubectl rollout restart deployment <deployment-name> -n production
```

#### Problem: 503 Service Unavailable

```bash
# Symptom: curl antar service → 503

# Diagnosa step 1: cek apakah DestinationRule ada
kubectl get destinationrule -n production

# Diagnosa step 2: cek subset matches deployment labels
kubectl get deployment app-v1 -n production -o jsonpath='{.spec.template.metadata.labels}'

# Diagnosa step 3: cek VirtualService
istioctl proxy-config routes <pod> -n production --name <route>

# Fix umum: pastikan label di Deployment match dengan subset di DestinationRule
```

#### Problem: mTLS Connection Refused

```bash
# Symptom: RBAC: access denied / TLS handshake failure

# Cek PeerAuthentication
kubectl get peerauthentication -n production

# Cek apakah ada service yang tidak pakai sidecar (legacy)
# Jika ada service tanpa sidecar tapi di-target mTLS STRICT → akan gagal

# Solusi sementara: pakai PERMISSIVE untuk namespace tertentu
kubectl apply -f configs/security/mtls-permissive-legacy.yaml
```

#### Problem: Canary tidak bekerja (semua traffic ke v1)

```bash
# Symptom: header-based routing tidak jalan

# Cek apakah app meneruskan header
kubectl exec -it <pod> -n production -- curl -H "x-canary: true" http://app/health

# Cek VirtualService sudah diterapkan
kubectl get virtualservice app -n production -o yaml

# Debug dengan Envoy config
istioctl proxy-config routes <pod> -n production
```

### Grafana Dashboard Penting

| Dashboard | Metrik yang Dipantau |
|-----------|---------------------|
| Istio Service Dashboard | Request rate, error rate, p50/p99 latency |
| Istio Workload Dashboard | Inbound/outbound per workload |
| Istio Control Plane | Pilot push rate, xDS errors |
| Istio Performance | Memory & CPU sidecar overhead |

### Prometheus Queries Penting

```promql
# Request rate per service (RPS)
sum(rate(istio_requests_total[1m])) by (destination_service_name)

# Error rate % per service
sum(rate(istio_requests_total{response_code=~"5.."}[5m])) by (destination_service_name)
/ sum(rate(istio_requests_total[5m])) by (destination_service_name) * 100

# P99 latency per service (ms)
histogram_quantile(0.99, 
  sum(rate(istio_request_duration_milliseconds_bucket[5m])) 
  by (destination_service_name, le)
)

# Circuit breaker trips
sum(rate(envoy_cluster_circuit_breakers_default_rq_open[5m])) by (cluster_name)

# mTLS connection ratio (harusnya 100% di strict mode)
sum(istio_requests_total{connection_security_policy="mutual_tls"}) by (destination_service_name)
/ sum(istio_requests_total) by (destination_service_name) * 100
```

---

## Best Practices

### 🏗️ Arsitektur

1. **Mulai dengan PERMISSIVE mTLS**, lalu migrasikan ke STRICT secara bertahap per-namespace
2. **Satu Gateway per tim/environment**, jangan share Gateway antar environment
3. **Gunakan ServiceEntry** untuk semua external dependencies (database, API eksternal)
4. **Pisahkan DestinationRule per environment** — jangan campur staging dan production rules

### 🔒 Security

1. **Zero-Trust default**: apply `AuthorizationPolicy` deny-all dulu, lalu buka per use case
2. **Limit egress** dengan EgressGateway — catat dan kontrol semua traffic keluar
3. **RBAC Istio terpisah dari RBAC Kubernetes** — keduanya perlu dikonfigurasi
4. **Rotasi certificate otomatis** sudah built-in Citadel — jangan disable

### ⚡ Performance

1. **Sidecar resource limits**: set CPU request 100m, memory request 128Mi sebagai baseline
2. **Tune sampling rate**: production gunakan 1% tracing, bukan 100% (overhead besar)
3. **Sidecar scope**: batasi sidecar visibility hanya ke service yang relevan

```yaml
# Contoh: batasi scope sidecar — import hanya namespace yang diperlukan
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: restricted-scope
  namespace: production
spec:
  egress:
  - hosts:
    - "production/*"          # semua service di namespace production
    - "istio-system/*"        # control plane
    - "monitoring/*"          # monitoring stack
    # Tanpa ini, sidecar load config semua service (costly di cluster besar)
```

5. **Disable sidecar untuk namespace yang tidak perlu**: batch jobs, monitoring agents

### 📊 Observability

1. **Gunakan Kiali** untuk visual service graph — sangat membantu onboarding tim baru
2. **Set meaningful app labels**: `app`, `version` wajib ada di semua Deployment
3. **Sampling Jaeger**: 1% di production, 100% di staging

### 🔄 Deployment

1. **Test di staging dengan `istioctl analyze`** sebelum apply ke production
2. **Gunakan Argo Rollouts + Istio** untuk canary yang lebih sophisticated (metric-based rollback)
3. **Selalu test dengan `istio-injection=enabled`** di CI/CD pipeline

---

## Pitfalls to Avoid

### ❗ Kesalahan Umum

#### 1. Langsung STRICT mTLS tanpa persiapan
```
❌ Apply PeerAuthentication STRICT ke seluruh cluster sekaligus
✅ Migrasi bertahap: PERMISSIVE → STRICT per namespace, verifikasi tiap langkah
```

#### 2. Tidak set `version` label di Deployment
```yaml
# ❌ Sidecar tracking tidak akurat, Kiali bingung
metadata:
  labels:
    app: my-service

# ✅ Selalu sertakan version label
metadata:
  labels:
    app: my-service
    version: v1
```

#### 3. VirtualService tanpa DestinationRule yang matching
```
❌ VirtualService merujuk subset "v1" tapi DestinationRule tidak define subset v1
   → 503 error semua request
✅ Selalu buat DestinationRule terlebih dahulu, baru VirtualService yang merujuknya
```

#### 4. Retry tanpa idempotency check
```
❌ Retry POST /payment 3x → bayar 3x!
✅ Retry HANYA untuk: GET (read), atau endpoint yang explicit idempotent
   Gunakan retryOn: "gateway-error,connect-failure" — jangan "5xx" untuk write ops
```

#### 5. Istio di-upgrade tanpa drain
```
❌ kubectl set image istiod ... → existing connections drop
✅ Ikuti SOP upgrade: istioctl upgrade → rolling restart workloads → verifikasi
```

#### 6. Timeout Istio vs Timeout Aplikasi
```
❌ Istio timeout 5s, aplikasi timeout 30s → Istio cut dulu, app masih tunggu → resource leak
✅ Selalu: Istio timeout > App timeout. Pakai hierarki:
   Client (10s) → VirtualService (8s) → App code (6s) → DB (4s)
```

#### 7. Tidak monitor sidecar resource usage
```
❌ Sidecar makan 50% CPU pod karena tidak ada limits
✅ Set resource limits di IstioOperator, monitor dengan:
   kubectl top pods -n production -c istio-proxy
```

---

## Referensi & Tool Recommendations

### 📚 Dokumentasi Resmi
- [Istio Documentation](https://istio.io/latest/docs/) — sumber utama, sangat lengkap
- [Envoy Proxy Docs](https://www.envoyproxy.io/docs/envoy/latest/) — untuk debugging detail
- [SPIFFE/SPIRE](https://spiffe.io/) — standar certificate identity yang dipakai Istio

### 🛠️ Tools Ecosystem

| Tool | Kegunaan | Rekomendasi |
|------|----------|-------------|
| **Kiali** | Service mesh observability UI | ⭐⭐⭐⭐⭐ Wajib |
| **Jaeger** | Distributed tracing | ⭐⭐⭐⭐⭐ Wajib |
| **Prometheus + Grafana** | Metrics & dashboards | ⭐⭐⭐⭐⭐ Wajib |
| **Argo Rollouts** | Advanced canary + Istio | ⭐⭐⭐⭐ Sangat direkomendasikan |
| **Helm + Helmfile** | Manage Istio configs | ⭐⭐⭐⭐ Direkomendasikan |
| **OPA/Gatekeeper** | Additional policy enforcement | ⭐⭐⭐ Situasional |
| **Hubble (Cilium)** | Network flow observability | ⭐⭐⭐ Alternatif observability |

### 🔄 Alternatif Service Mesh

| Service Mesh | Kelebihan | Kekurangan |
|-------------|-----------|------------|
| **Istio** | Feature rich, ekosistem besar | Kompleks, resource-heavy |
| **Linkerd** | Lightweight, simple, Rust-based | Fitur lebih terbatas |
| **Consul Connect** | Terintegrasi HashiCorp ekosistem | Butuh Consul server |
| **Cilium** | eBPF-based, no sidecar | Kernel version requirement |

### 📖 Learning Resources
- [Istio in Action (Manning)](https://www.manning.com/books/istio-in-action) — buku paling komprehensif
- [Istio Ambient Mesh](https://istio.io/latest/blog/2022/introducing-ambient-mesh/) — next-gen tanpa sidecar
- [Solo.io Academy](https://academy.solo.io/) — kursus Istio gratis

---

## 📁 Struktur File Playbook Ini

```
service-mesh-istio/
├── README.md                          # Panduan ini
├── scripts/
│   ├── install-istio.sh              # Script instalasi otomatis
│   └── verify-mesh.sh                # Verifikasi health mesh
├── configs/
│   ├── istio-operator.yaml           # IstioOperator production config
│   ├── traffic/
│   │   ├── virtual-service-basic.yaml
│   │   ├── canary-deployment.yaml
│   │   ├── circuit-breaker.yaml
│   │   └── resilience-config.yaml
│   ├── security/
│   │   ├── mtls-strict.yaml
│   │   ├── authz-deny-all.yaml
│   │   └── authz-allow-frontend.yaml
│   └── observability/
│       ├── telemetry-config.yaml
│       └── grafana-dashboards.yaml
├── policies/
│   └── sidecar-scope.yaml
├── monitoring/
│   ├── prometheus-rules.yaml
│   └── alertmanager-config.yaml
└── examples/
    ├── bookinfo-demo.yaml            # Contoh aplikasi demo Istio
    └── app-with-mesh.yaml            # Template aplikasi production-ready
```
