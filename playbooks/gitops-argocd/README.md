# GitOps dengan ArgoCD untuk Kubernetes

## Pengantar

GitOps adalah paradigma modern untuk mengelola infrastruktur dan aplikasi dimana Git menjadi single source of truth. ArgoCD adalah tool deklaratif berbasis GitOps untuk continuous delivery di Kubernetes yang secara otomatis men-sync state cluster dengan konfigurasi di Git repository.

### Masalah yang Diselesaikan

1. **Deployment Inconsistency**: Manual deployment ke berbagai environment sering menghasilkan configuration drift
2. **Audit Trail**: Sulit melacak siapa yang deploy apa dan kapan
3. **Rollback Complexity**: Rollback manual memakan waktu dan error-prone
4. **Multi-Cluster Management**: Mengelola banyak cluster secara manual tidak scalable
5. **Security**: Credential management tersebar dan tidak terkelola dengan baik

### Keuntungan GitOps

- **Declarative**: Semua konfigurasi dideklarasikan di Git
- **Versioned & Immutable**: Full history dengan Git
- **Automated**: Sync otomatis dari Git ke cluster
- **Auditable**: Semua perubahan tercatat di Git history
- **Easy Rollback**: Git revert untuk rollback instant
- **Secure**: Cluster tidak perlu exposed, ArgoCD yang pull dari Git

## Arsitektur ArgoCD

```
┌─────────────────┐
│   Git Repo      │
│  (Source of     │
│   Truth)        │
└────────┬────────┘
         │
         │ monitors & syncs
         ▼
┌─────────────────┐
│   ArgoCD        │
│   - API Server  │
│   - Repo Server │
│   - Controller  │
└────────┬────────┘
         │
         │ applies manifests
         ▼
┌─────────────────┐
│  Kubernetes     │
│  Cluster(s)     │
└─────────────────┘
```

## Files dalam Repository Ini

- `argocd-install.sh` - Script instalasi ArgoCD
- `application-example.yaml` - Template ArgoCD Application
- `applicationset-example.yaml` - Multi-cluster deployment template
- `sample-app-manifests.yaml` - Contoh lengkap Kubernetes manifests
- `rollout-canary-example.yaml` - Canary deployment dengan Argo Rollouts
- `notifications-config.yaml` - Konfigurasi notifikasi Slack/Teams/Email
- `rbac-config.yaml` - Role-Based Access Control configuration
- `sealed-secrets-setup.sh` - Setup script untuk Sealed Secrets

## Quick Start

```bash
# 1. Install ArgoCD
./argocd-install.sh

# 2. Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 3. Port forward untuk akses UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 4. Login ke UI: https://localhost:8080
# Username: admin
# Password: (dari step 2)

# 5. Deploy sample application
kubectl apply -f application-example.yaml
```

## Step-by-Step Implementation

### 1. Instalasi ArgoCD

Gunakan script yang disediakan:

```bash
# Default: install dengan manifests
./argocd-install.sh

# Atau dengan Helm
./argocd-install.sh helm
```

### 2. Setup Git Repository

Struktur repository ideal untuk GitOps:

```
my-gitops-repo/
├── apps/
│   ├── production/
│   ├── staging/
│   └── development/
├── infrastructure/
│   ├── namespaces/
│   ├── ingress/
│   └── monitoring/
└── argocd-apps/
    ├── production-app.yaml
    ├── staging-app.yaml
    └── development-app.yaml
```

### 3. Deploy Aplikasi

Edit `application-example.yaml` dan sesuaikan dengan repository Anda:

```yaml
spec:
  source:
    repoURL: https://github.com/your-org/your-gitops-repo.git
    targetRevision: main
    path: apps/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
```

Deploy:

```bash
kubectl apply -f application-example.yaml
```

### 4. Setup RBAC

Konfigurasi role-based access control:

```bash
kubectl apply -f rbac-config.yaml
```

Roles yang tersedia:
- **readonly**: View only
- **developer**: Sync apps tapi tidak modify config
- **devops**: Full access kecuali RBAC
- **admin**: Full access

### 5. Setup Notifications

Edit `notifications-config.yaml` dengan credentials Anda:

```yaml
stringData:
  slack-token: xoxb-your-token
  teams-webhook-url: https://outlook.office.com/webhook/your-url
```

Apply:

```bash
kubectl apply -f notifications-config.yaml
```

### 6. Setup Secret Management

Install Sealed Secrets:

```bash
./sealed-secrets-setup.sh
```

Encrypt secrets:

```bash
kubectl create secret generic mysecret \
  --from-literal=password=mypassword \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > mysealedsecret.yaml

# Commit encrypted secret ke Git
git add mysealedsecret.yaml
git commit -m "Add encrypted secret"
```

## Best Practices

### 1. Git sebagai Single Source of Truth

- ✅ Semua infrastructure dan application config di Git
- ✅ Gunakan pull requests untuk review
- ✅ Enforce branch protection
- ❌ Jangan manual edit di cluster

### 2. Secret Management

- ✅ Gunakan Sealed Secrets atau External Secrets
- ✅ Rotate secrets secara berkala
- ❌ JANGAN commit plaintext secrets ke Git

### 3. Sync Policies

Untuk production:

```yaml
syncPolicy:
  automated:
    prune: true       # Auto-delete resources
    selfHeal: true    # Auto-sync pada drift
  syncOptions:
    - CreateNamespace=true
```

Untuk development:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: false   # Manual intervention untuk dev
```

### 4. Environment Management

Gunakan Kustomize overlays atau Helm values per environment:

```
apps/
├── base/                    # Base configuration
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── production/          # Production patches
    │   └── kustomization.yaml
    ├── staging/             # Staging patches
    │   └── kustomization.yaml
    └── development/         # Dev patches
        └── kustomization.yaml
```

### 5. Progressive Delivery

Gunakan Argo Rollouts untuk canary deployment:

```bash
# Deploy rollout
kubectl apply -f rollout-canary-example.yaml

# Watch progress
kubectl argo rollouts get rollout demo-app-canary --watch

# Promote jika sukses
kubectl argo rollouts promote demo-app-canary

# Abort jika ada masalah
kubectl argo rollouts abort demo-app-canary
```

### 6. Multi-Cluster Management

Gunakan ApplicationSet untuk deploy ke multiple clusters:

```bash
kubectl apply -f applicationset-example.yaml
```

Benefits:
- Single manifest untuk multiple deployments
- Centralized configuration management
- Easy scale ke environments baru

## Monitoring dan Troubleshooting

### Check Application Status

```bash
# List all applications
argocd app list

# Get application detail
argocd app get demo-app

# Watch sync status
argocd app wait demo-app --health

# View history
argocd app history demo-app
```

### Common Issues

#### Application Stuck in "Progressing"

```bash
# Force refresh
argocd app refresh demo-app

# Force sync
argocd app sync demo-app --force
```

#### Out of Sync

```bash
# Diff between Git and cluster
argocd app diff demo-app

# Manual sync
argocd app sync demo-app
```

#### Performance Issues

```bash
# Check ArgoCD components
kubectl top pods -n argocd

# Scale repo server
kubectl scale deployment argocd-repo-server -n argocd --replicas=3
```

### Metrics

ArgoCD expose Prometheus metrics:

- `argocd_app_sync_total` - Total sync operations
- `argocd_app_health_status` - Application health
- `argocd_app_sync_status` - Sync status
- `argocd_app_reconcile_duration_seconds` - Reconciliation time

## Pitfalls to Avoid

### 1. ❌ Menyimpan Secrets di Git (Plaintext)
**Solusi**: Gunakan Sealed Secrets, External Secrets, atau Vault

### 2. ❌ Manual Changes di Cluster
**Solusi**: Enforce "Git is the source of truth", train team

### 3. ❌ Tidak Set Resource Limits
**Solusi**: Selalu set resource requests/limits

### 4. ❌ Auto-Sync Tanpa Testing
**Solusi**: Gunakan manual sync untuk production, atau progressive delivery

### 5. ❌ Ignoring Drift
**Solusi**: Enable selfHeal atau setup monitoring

### 6. ❌ Tidak Ada Backup Strategy
**Solusi**: Backup ArgoCD configuration berkala

```bash
# Backup applications
argocd app list -o json > argocd-apps-backup.json

# Backup settings
kubectl get configmap argocd-cm -n argocd -o yaml > argocd-cm-backup.yaml
```

## Cost Optimization

1. **Resource Limits**: Set appropriate CPU/memory untuk ArgoCD components
2. **Prune Old ReplicaSets**: Enable `revisionHistoryLimit`
3. **Optimize Sync Frequency**: Adjust `timeout.reconciliation`
4. **Cache**: Tune cache TTL di repo server
5. **Multi-tenancy**: Share ArgoCD instance untuk multiple teams

## Tool Recommendations

### Essential Tools

- **ArgoCD CLI** - Command line interface
- **Kustomize** - Template-free configuration
- **Helm** - Package manager
- **Sealed Secrets** - Secret encryption
- **ArgoCD Notifications** - Alert engine
- **ArgoCD Image Updater** - Automated image updates

### Monitoring

- **Prometheus** - Metrics collection
- **Grafana** - Visualization
- **Loki** - Log aggregation
- **Alertmanager** - Alert routing

## Referensi

### Official Documentation
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [GitOps Principles](https://opengitops.dev/)
- [Argo Rollouts](https://argoproj.github.io/argo-rollouts/)

### Tools
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
- [Kustomize](https://kustomize.io/)
- [Helm](https://helm.sh/)

### Community
- [ArgoCD GitHub](https://github.com/argoproj/argo-cd)
- [ArgoCD Slack](https://argoproj.github.io/community/join-slack/)
- [CNCF GitOps Working Group](https://github.com/cncf/tag-app-delivery)

## Kesimpulan

GitOps dengan ArgoCD memberikan workflow deployment yang predictable, auditable, dan automated. Dengan Git sebagai single source of truth, development team mendapatkan benefits seperti version control, peer review via pull requests, dan rollback yang mudah.

**Key Takeaways:**

1. ✅ Semua infrastructure dan application config di Git
2. ✅ ArgoCD continuously reconcile state
3. ✅ Automated sync dengan safeguards
4. ✅ Secret management dengan tools eksternal
5. ✅ Progressive delivery dengan Argo Rollouts
6. ✅ Multi-cluster management dengan ApplicationSets
7. ✅ Monitoring dan alerting untuk observability

Implementasi GitOps adalah journey, bukan sprint. Mulai dari satu aplikasi, pelajari best practices, iterate, dan scale seiring team menjadi lebih comfortable dengan workflow ini.

---

**Created**: 2026-06-18  
**Author**: Hermes Agent - DevOps Research  
**License**: MIT
