# Platform Engineering dengan Backstage: Internal Developer Platform (IDP)

## Daftar Isi
- [Pendahuluan](#pendahuluan)
- [Masalah yang Diselesaikan](#masalah-yang-diselesaikan)
- [Arsitektur Platform](#arsitektur-platform)
- [Prasyarat](#prasyarat)
- [Instalasi Backstage](#instalasi-backstage)
- [Service Catalog](#service-catalog)
- [Software Templates](#software-templates)
- [Plugin Integrasi](#plugin-integrasi)
- [Deployment ke Kubernetes](#deployment-ke-kubernetes)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [Referensi](#referensi)

---

## Pendahuluan

**Platform Engineering** adalah disiplin yang berfokus pada pembuatan *Internal Developer Platform* (IDP) — sebuah ekosistem alat dan layanan mandiri yang memungkinkan developer untuk *self-serve* kebutuhan infrastruktur mereka tanpa harus bergantung pada tim ops di setiap langkah.

**Backstage** (dibuat oleh Spotify, kini CNCF project) adalah framework open-source terkemuka untuk membangun IDP. Backstage menyediakan:

- 🗂️ **Service Catalog** — satu tempat untuk semua service, library, API, dan resource
- 🏗️ **Software Templates (Scaffolder)** — otomatisasi pembuatan proyek baru dengan standar perusahaan
- 📚 **TechDocs** — dokumentasi teknis terintegrasi (docs-as-code)
- 🔌 **Plugin Ecosystem** — >200 plugin untuk integrasi CI/CD, monitoring, cloud, dll

### Mengapa Platform Engineering Penting?

Menurut **Gartner**, pada tahun 2026 lebih dari 80% organisasi rekayasa perangkat lunak akan membentuk tim Platform Engineering. Laporan DORA 2024 menunjukkan organisasi dengan IDP matang memiliki:

- ✅ **50% lebih cepat** dalam onboarding developer baru
- ✅ **70% pengurangan** cognitive load developer
- ✅ **40% peningkatan** deployment frequency
- ✅ **30% pengurangan** waktu untuk production (time-to-prod)

---

## Masalah yang Diselesaikan

### Sebelum Platform Engineering (Pain Points Umum)

```
❌ "Gimana cara bikin service baru?"         → Tanya senior dev / googling manual
❌ "Service ini dikelola siapa?"              → Gak ada yg tahu, dokumentasi usang
❌ "Environment mana yang sudah di-deploy?"  → Cek Slack 5 channel berbeda
❌ "Perlu akses database staging"            → Buka ticket, tunggu 3 hari
❌ "Cara rollback deployment kemarin?"       → Panik, tanya DevOps on-call tengah malam
```

### Setelah Platform Engineering (IDP dengan Backstage)

```
✅ "Bikin service baru"    → Klik template, isi form, service siap dalam 10 menit
✅ "Siapa owner service X" → Lihat catalog, ada owner, Slack contact, runbook
✅ "Status semua service"  → Dashboard terpusat, real-time
✅ "Butuh akses staging"   → Self-service portal, approved otomatis, audit trail
✅ "Rollback deployment"   → Klik tombol di portal, done
```

---

## Arsitektur Platform

```
┌─────────────────────────────────────────────────────────────────┐
│                     INTERNAL DEVELOPER PORTAL                    │
│                         (Backstage UI)                           │
└────────┬──────────────────┬──────────────────┬──────────────────┘
         │                  │                  │
    ┌────▼────┐        ┌────▼────┐        ┌────▼────┐
    │ Service │        │Software │        │ TechDocs │
    │ Catalog │        │Templates│        │   (MkDocs)│
    └────┬────┘        └────┬────┘        └──────────┘
         │                  │
    ┌────▼────────────────────────────────────────────┐
    │              BACKSTAGE BACKEND                   │
    │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
    │  │ Catalog  │ │Scaffolder│ │    Auth Provider  │ │
    │  │ Provider │ │ Service  │ │  (GitHub/OIDC)    │ │
    │  └──────────┘ └──────────┘ └──────────────────┘ │
    └────────────────────┬────────────────────────────┘
                         │ Integrasi
    ┌────────────────────▼────────────────────────────┐
    │              EXTERNAL SERVICES                   │
    │  GitHub  │  ArgoCD  │  Grafana  │  PagerDuty    │
    │  Jenkins │  SonarQ  │  Vault    │  Kubernetes   │
    └──────────────────────────────────────────────────┘
```

---

## Prasyarat

| Tool | Versi Minimum | Kegunaan |
|------|--------------|---------|
| Node.js | 18.x LTS | Runtime Backstage |
| Yarn | 4.x | Package manager |
| Docker | 24.x | Containerization |
| kubectl | 1.28+ | K8s management |
| PostgreSQL | 14+ | Database Backstage |
| GitHub App | - | Auth & SCM integration |

---

## Instalasi Backstage

### Step 1: Buat Aplikasi Backstage Baru

```bash
# Install Backstage CLI secara global
npm install -g @backstage/create-app@latest

# Buat aplikasi baru (ikuti wizard)
npx @backstage/create-app@latest

# Jawab prompt:
# ? Enter a name for the app [required] → my-company-portal
# ? Select database for the backend [required] → PostgreSQL
```

### Step 2: Struktur Direktori

```
my-company-portal/
├── app-config.yaml          # Konfigurasi utama
├── app-config.local.yaml    # Konfigurasi lokal (git-ignored)
├── app-config.production.yaml
├── catalog-info.yaml        # Self-descriptor portal
├── packages/
│   ├── app/                 # Frontend React
│   │   ├── src/
│   │   │   ├── App.tsx
│   │   │   └── components/
│   │   └── package.json
│   └── backend/             # Backend Node.js
│       ├── src/
│       │   └── index.ts
│       └── package.json
└── plugins/                 # Custom plugins
```

### Step 3: Konfigurasi Dasar (`app-config.yaml`)

```yaml
app:
  title: "MyCompany Developer Portal"
  baseUrl: http://localhost:3000

organization:
  name: "MyCompany"

backend:
  baseUrl: http://localhost:7007
  listen:
    port: 7007
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: http://localhost:3000
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}

integrations:
  github:
    - host: github.com
      apps:
        - $include: github-app-credentials.yaml

proxy:
  endpoints:
    '/grafana/api':
      target: ${GRAFANA_URL}
      headers:
        Authorization: Bearer ${GRAFANA_TOKEN}
    '/argocd/api':
      target: ${ARGOCD_URL}
      changeOrigin: true
      secure: true
      headers:
        Cookie: ${ARGOCD_AUTH_TOKEN}

auth:
  environment: development
  providers:
    github:
      development:
        clientId: ${GITHUB_CLIENT_ID}
        clientSecret: ${GITHUB_CLIENT_SECRET}
        signIn:
          resolvers:
            - resolver: usernameMatchingUserEntityName

catalog:
  import:
    entityFilename: catalog-info.yaml
    pullRequestBranchName: backstage-integration
  rules:
    - allow: [Component, System, API, Resource, Location, Domain, Group, User]
  locations:
    # File lokal untuk development
    - type: file
      target: ../../catalog/all-components.yaml
    # Scan GitHub org
    - type: github-org
      target: https://github.com/mycompany
      rules:
        - allow: [Group, User]
    # Scan semua repo di org
    - type: github-discovery
      target: https://github.com/mycompany

techdocs:
  builder: 'local'
  generator:
    runIn: 'local'
  publisher:
    type: 'local'

scaffolder:
  defaultAuthor:
    name: Backstage Bot
    email: backstage@mycompany.com

kubernetes:
  serviceLocatorMethod:
    type: 'multiTenant'
  clusterLocatorMethods:
    - type: 'config'
      clusters:
        - url: ${K8S_CLUSTER_URL}
          name: production
          authProvider: 'serviceAccount'
          skipTLSVerify: false
          serviceAccountToken: ${K8S_SERVICE_ACCOUNT_TOKEN}
          caData: ${K8S_CLUSTER_CA_DATA}
        - url: ${K8S_STAGING_URL}
          name: staging
          authProvider: 'serviceAccount'
          serviceAccountToken: ${K8S_STAGING_TOKEN}

permission:
  enabled: true
```

### Step 4: Jalankan Lokal

```bash
cd my-company-portal

# Install dependencies
yarn install

# Jalankan database (jika menggunakan Docker)
docker run -d \
  --name backstage-postgres \
  -e POSTGRES_USER=backstage \
  -e POSTGRES_PASSWORD=backstage \
  -e POSTGRES_DB=backstage \
  -p 5432:5432 \
  postgres:15

# Set environment variables
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_USER=backstage
export POSTGRES_PASSWORD=backstage
export GITHUB_CLIENT_ID=your_client_id
export GITHUB_CLIENT_SECRET=your_client_secret

# Jalankan dalam mode development
yarn dev
```

---

## Service Catalog

Service Catalog adalah inti dari Backstage — single source of truth untuk semua software asset.

### Konsep Entity dalam Catalog

```
Domain (Engineering)
└── System (E-Commerce Platform)
    ├── Component (checkout-api)       ← Service/library/website
    ├── Component (payment-service)
    └── API (checkout-api-v1)         ← OpenAPI/gRPC contract
        └── Resource (postgres-db)    ← Database/S3/Queue
```

### Contoh: catalog-info.yaml untuk Microservice

```yaml
# catalog-info.yaml di root repo service
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-api
  title: "Checkout API"
  description: "API untuk proses checkout dan pembayaran e-commerce"
  annotations:
    # GitHub
    github.com/project-slug: mycompany/checkout-api
    # Kubernetes — untuk link ke K8s resource
    backstage.io/kubernetes-id: checkout-api
    backstage.io/kubernetes-namespace: production
    # CI/CD
    jenkins.io/job-full-name: checkout-api/main
    github.com/action-workflow: ci.yml
    # Monitoring
    grafana/dashboard-selector: "title=Checkout API"
    grafana/alert-label-selector: "service=checkout-api"
    # On-call
    pagerduty.com/service-id: P1234XYZ
    # SonarQube
    sonarqube.org/project-key: mycompany_checkout-api
    # TechDocs — generate dari folder docs/
    backstage.io/techdocs-ref: dir:.
  tags:
    - java
    - spring-boot
    - payment
    - critical
  links:
    - url: https://grafana.mycompany.com/d/checkout
      title: Grafana Dashboard
      icon: dashboard
    - url: https://argocd.mycompany.com/applications/checkout-api
      title: ArgoCD
      icon: web
    - url: https://mycompany.atlassian.net/wiki/checkout-api
      title: Confluence Runbook
      icon: document
spec:
  type: service          # service | library | website | documentation
  lifecycle: production  # experimental | development | production | deprecated
  owner: group:checkout-team
  system: ecommerce-platform
  dependsOn:
    - component:payment-service
    - resource:checkout-postgres
    - resource:order-kafka-topic
  providesApis:
    - checkout-api-v1
  consumesApis:
    - payment-api-v2
    - inventory-api-v1
```

### Contoh: Mendefinisikan API (OpenAPI)

```yaml
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: checkout-api-v1
  description: "REST API untuk checkout service"
  tags:
    - rest
    - openapi
spec:
  type: openapi
  lifecycle: production
  owner: group:checkout-team
  system: ecommerce-platform
  definition:
    $text: ./openapi.yaml  # Referensi file OpenAPI spec
```

### Contoh: Group dan User

```yaml
# groups.yaml
apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: checkout-team
  description: "Tim yang bertanggung jawab untuk checkout dan payment"
spec:
  type: team
  profile:
    displayName: Checkout Team
    email: checkout-team@mycompany.com
    picture: https://mycompany.com/teams/checkout.png
  parent: engineering
  children: []
  members:
    - budi-santoso
    - siti-rahayu
    - agus-wijaya
---
apiVersion: backstage.io/v1alpha1
kind: User
metadata:
  name: budi-santoso
spec:
  profile:
    displayName: Budi Santoso
    email: budi@mycompany.com
    picture: https://avatars.githubusercontent.com/budi-santoso
  memberOf:
    - checkout-team
    - backend-guild
```

---

## Software Templates

Software Templates (Scaffolder) memungkinkan developer membuat proyek baru yang sudah *pre-configured* dengan standar perusahaan dalam hitungan menit.

### Cara Kerja Scaffolder

```
Developer           Backstage UI          Scaffolder Engine        GitHub
    │                    │                      │                      │
    │──pilih template──►│                      │                      │
    │                    │──render form────────►│                      │
    │◄──isi parameter────│                      │                      │
    │──submit form──────►│                      │                      │
    │                    │──jalankan steps─────►│                      │
    │                    │                      │──clone skeleton──────►│
    │                    │                      │──render Nunjucks──────│
    │                    │                      │──push new repo────────►│
    │                    │                      │──register catalog──────►│
    │◄──link repo baru───│◄─────────────────────│                      │
```

Lihat file template lengkap: [`templates/microservice-spring-boot.yaml`](./templates/microservice-spring-boot.yaml)

---

## Plugin Integrasi

### Plugin yang Direkomendasikan untuk 2025

| Plugin | Package | Fungsi |
|--------|---------|--------|
| **Kubernetes** | `@backstage/plugin-kubernetes` | Status pod/deployment live |
| **GitHub Actions** | `@backstage/plugin-github-actions` | Lihat & trigger CI/CD |
| **ArgoCD** | `@roadiehq/backstage-plugin-argo-cd` | GitOps deployment status |
| **Grafana** | `@k-phoen/backstage-plugin-grafana` | Embed dashboard + alerts |
| **PagerDuty** | `@pagerduty/backstage-plugin` | On-call schedule & incidents |
| **SonarQube** | `@backstage/plugin-sonarqube` | Code quality metrics |
| **Vault** | `@backstage/plugin-vault` | Hashicorp Vault secrets |
| **Cost Insights** | `@backstage/plugin-cost-insights` | Cloud cost per tim |
| **Lighthouse** | `@backstage/plugin-lighthouse` | Web performance audit |
| **Dynatrace** | `@backstage/plugin-dynatrace` | APM metrics |

### Instalasi Plugin (Contoh: Kubernetes Plugin)

```bash
# Di packages/app
yarn --cwd packages/app add @backstage/plugin-kubernetes

# Di packages/backend
yarn --cwd packages/backend add @backstage/plugin-kubernetes-backend
```

Lihat file konfigurasi plugin: [`plugins/kubernetes-config.ts`](./plugins/kubernetes-config.ts)

---

## Deployment ke Kubernetes

Lihat folder [`kubernetes/`](./kubernetes/) untuk manifest lengkap.

### Overview Deployment

```
cluster/
└── backstage namespace
    ├── Deployment (backstage)
    │   ├── app container (port 7007)
    │   └── env dari ConfigMap + Secret
    ├── Service (ClusterIP)
    ├── Ingress (dengan TLS/cert-manager)
    ├── ConfigMap (app-config.production.yaml)
    ├── Secret (env credentials)
    ├── ServiceAccount (dengan RBAC untuk K8s plugin)
    └── CronJob (catalog refresh setiap 30m)
```

### Build Docker Image

```bash
# Build image dari root direktori Backstage
docker image build \
  --tag backstage:1.0.0 \
  --file packages/backend/Dockerfile \
  .

# Tag dan push ke registry
docker tag backstage:1.0.0 registry.mycompany.com/platform/backstage:1.0.0
docker push registry.mycompany.com/platform/backstage:1.0.0
```

---

## Best Practices

### 1. Governance: Siapa yang Owns Apa?

```
✅ DO:   Setiap entity WAJIB punya owner yang valid (team/group)
✅ DO:   Pakai lifecycle label (production/deprecated) dengan konsisten
✅ DO:   Review catalog health score secara rutin (Backstage ada built-in)
❌ DON'T: Biarkan orphaned components (no owner)
❌ DON'T: Entity dengan nama "test" atau "temp" di production catalog
```

### 2. Template Standards

```
✅ DO:   Template sudah include: CI/CD pipeline, Dockerfile, linting config
✅ DO:   Template generate catalog-info.yaml dan docs/ folder otomatis
✅ DO:   Version template — tag dengan semver, changelog per versi
❌ DON'T: Template terlalu strict sehingga developer tidak bisa customize
❌ DON'T: Satu template super-generic untuk semua use case
```

### 3. Catalog Hygiene

```bash
# Script untuk scan orphaned entities (no valid owner)
# Jalankan sebagai cron job mingguan

# Cek entities dengan owner tidak valid
curl -s "${BACKSTAGE_URL}/api/catalog/entities" \
  -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
  | jq '[.[] | select(.spec.owner == null or .spec.owner == "")]'

# Cek deprecated components yang masih aktif (lifecycle mismatch)
curl -s "${BACKSTAGE_URL}/api/catalog/entities?filter=kind=Component" \
  | jq '[.[] | select(.spec.lifecycle == "deprecated") | .metadata.name]'
```

### 4. Security

```
✅ DO:   Aktifkan RBAC — jangan semua user bisa lihat semua
✅ DO:   Rotate service account token K8s setiap 90 hari
✅ DO:   Simpan credentials di Vault/Secret Manager, bukan ConfigMap
✅ DO:   Audit log semua scaffold actions (siapa bikin apa kapan)
❌ DON'T: Expose Backstage URL tanpa auth di internet
❌ DON'T: Gunakan admin token yang sama untuk semua integrasi
```

### 5. Performance & Scalability

```yaml
# app-config.production.yaml — tuning untuk load tinggi
catalog:
  processingInterval:
    seconds: 30         # Default 30s, naikkan ke 60-120s jika catalog besar
  
backend:
  cache:
    store: redis        # Gunakan Redis untuk caching, bukan in-memory
    connection:
      host: ${REDIS_HOST}
      port: 6379
  reading:
    allow:
      - host: github.com
      - host: bitbucket.org
```

---

## Monitoring dan Troubleshooting

### Metrics Backstage yang Perlu Dipantau

```yaml
# Backstage expose Prometheus metrics di /metrics endpoint
# Metrics penting:

# 1. Catalog processing
catalog_processing_duration_seconds   # Berapa lama proses entity
catalog_entities_count                # Total entitas di catalog

# 2. Scaffolder
scaffolder_task_count                 # Jumlah scaffold task
scaffolder_task_duration_seconds      # Durasi rata-rata scaffold

# 3. Backend performance
http_request_duration_seconds         # Latency API
http_requests_total                   # Request count

# 4. Database
pg_stat_activity_count                # Koneksi DB aktif
```

### Grafana Dashboard Query Contoh

```promql
# Request rate ke Backstage API
rate(http_requests_total{app="backstage"}[5m])

# Error rate
rate(http_requests_total{app="backstage", status=~"5.."}[5m])
  / rate(http_requests_total{app="backstage"}[5m]) * 100

# Catalog processing lag
histogram_quantile(0.95, 
  rate(catalog_processing_duration_seconds_bucket[10m])
)
```

### Troubleshooting Guide

#### Problem 1: Entity tidak muncul di catalog

```bash
# Cek apakah location sudah terdaftar
curl "${BACKSTAGE_URL}/api/catalog/locations" \
  -H "Authorization: Bearer ${TOKEN}"

# Force refresh entity spesifik
curl -X POST \
  "${BACKSTAGE_URL}/api/catalog/refresh" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"entityRef": "component:default/my-service"}'

# Cek error di processing log
kubectl logs -n backstage deployment/backstage \
  | grep "ERROR" | grep "catalog" | tail -50

# Validasi catalog-info.yaml
npx @backstage/catalog-model validate ./catalog-info.yaml
```

#### Problem 2: Scaffolder task gagal

```bash
# Lihat task status via API
curl "${BACKSTAGE_URL}/api/scaffolder/v2/tasks?status=failed" \
  -H "Authorization: Bearer ${TOKEN}" \
  | jq '.[].steps'

# Cek log task spesifik
curl "${BACKSTAGE_URL}/api/scaffolder/v2/tasks/{TASK_ID}/events" \
  -H "Authorization: Bearer ${TOKEN}"

# Cek GitHub App permissions (penyebab paling umum)
# - Perlu: Contents: Write, Pull requests: Write, Metadata: Read
```

#### Problem 3: Kubernetes plugin tidak menampilkan data

```bash
# Verifikasi ServiceAccount Backstage punya akses
kubectl auth can-i list pods \
  --as=system:serviceaccount:backstage:backstage \
  -n production

# Buat ClusterRole binding jika kurang akses
kubectl create clusterrolebinding backstage-k8s-viewer \
  --clusterrole=view \
  --serviceaccount=backstage:backstage

# Cek label pada Deployment/Pod target
# Harus ada: backstage.io/kubernetes-id: <component-name>
kubectl get deployment my-service -n production \
  -o jsonpath='{.metadata.labels}'
```

#### Problem 4: Auth loop / tidak bisa login

```bash
# Cek GitHub OAuth App settings
# - Callback URL harus: https://<backstage-url>/api/auth/github/handler/frame

# Cek environment variables
kubectl exec -n backstage deployment/backstage -- env \
  | grep -E "GITHUB|AUTH"

# Debug auth di browser console
# Network tab → filter "/api/auth" → cek response error
```

### Health Check Script

```bash
#!/bin/bash
# healthcheck.sh — Cek kesehatan Backstage secara komprehensif

BACKSTAGE_URL="${BACKSTAGE_URL:-https://backstage.mycompany.com}"

echo "=== Backstage Health Check ==="

# 1. API Health
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BACKSTAGE_URL}/healthcheck")
echo "API Health: ${HTTP_STATUS} (200 = OK)"

# 2. Catalog entity count
ENTITY_COUNT=$(curl -s "${BACKSTAGE_URL}/api/catalog/entities" \
  -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
  | jq 'length')
echo "Total Entities: ${ENTITY_COUNT}"

# 3. Orphaned entities (no owner)
ORPHANED=$(curl -s "${BACKSTAGE_URL}/api/catalog/entities?filter=kind=Component" \
  -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
  | jq '[.[] | select(.spec.owner == null)] | length')
echo "Orphaned Components: ${ORPHANED}"

# 4. Failed scaffold tasks (last 24h)
FAILED_TASKS=$(curl -s "${BACKSTAGE_URL}/api/scaffolder/v2/tasks?status=failed" \
  -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
  | jq 'length')
echo "Failed Scaffold Tasks (24h): ${FAILED_TASKS}"

# 5. DB connection check
kubectl exec -n backstage deployment/backstage -- \
  node -e "const {Pool} = require('pg'); const p = new Pool(); p.query('SELECT 1').then(() => { console.log('DB: OK'); p.end(); }).catch(e => { console.log('DB: FAIL', e.message); })"

echo "=== Health Check Complete ==="
```

---

## Referensi dan Tool Recommendations

### Dokumentasi Resmi
- 📖 [Backstage.io Docs](https://backstage.io/docs) — Dokumentasi lengkap
- 📖 [CNCF Platform Engineering Whitepaper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) — Framework dan konsep
- 📖 [Team Topologies](https://teamtopologies.com/) — Buku referensi organizational design untuk platform teams
- 📖 [DORA Report 2024](https://dora.dev/research/2024/dora-report/) — Metrics dan benchmark

### Plugin Tambahan yang Direkomendasikan
- 🔌 [Roadie Plugins](https://roadie.io/backstage/plugins/) — Koleksi plugin enterprise
- 🔌 [Backstage Community Plugins](https://github.com/backstage/community-plugins) — Official community repo
- 🔌 [Janus IDP](https://janus-idp.io/) — Red Hat's Backstage distribution dengan plugin ekstra

### Tools Komplementer
| Tool | Fungsi |
|------|--------|
| **Port** | Alternative/complement IDP platform (no-code) |
| **Cortex** | Service catalog dengan scorecards |
| **OpsLevel** | Maturity scoring untuk services |
| **Humanitec** | Platform orchestration layer |
| **Score** | Workload spec (platform-agnostic) |

### Estimasi Effort Implementasi

| Fase | Durasi | Deliverable |
|------|--------|-------------|
| **Fase 1: Foundation** | 2-3 minggu | Backstage running + GitHub auth + basic catalog |
| **Fase 2: Catalog Populasi** | 3-4 minggu | Semua service terdaftar, owner assigned |
| **Fase 3: Templates** | 2-3 minggu | 3-5 template untuk use case umum |
| **Fase 4: Integrasi** | 3-4 minggu | K8s, ArgoCD, Grafana, PagerDuty |
| **Fase 5: Adoption** | Ongoing | Training, feedback loop, governance |

### ROI Quick Wins
1. **Catalog First** — Bahkan catalog saja (tanpa fitur lain) sudah mengurangi "siapa yang pegang service ini?" meetings
2. **1 Template Dulu** — Satu template microservice yang bagus = 10x lipat developer time saving
3. **TechDocs** — Dokumentasi yang hidup di repo, render otomatis = akhir dari "wiki yang tidak pernah di-update"

---

*Playbook ini dibuat untuk keperluan internal. Kontribusi dan feedback silakan buat Pull Request.*

*Last updated: Juni 2026*
