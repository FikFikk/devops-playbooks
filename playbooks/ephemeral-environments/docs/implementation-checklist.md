# Ephemeral Environments - Implementation Checklist

## Prerequisites
- [ ] Kubernetes cluster 1.25+ dengan minimal 8 vCPU, 16GB RAM available
- [ ] kubectl configured dan cluster access
- [ ] Helm 3.x installed
- [ ] GitHub/GitLab repo dengan admin access
- [ ] Domain untuk preview environments (e.g., preview.yourapp.com)
- [ ] DNS provider credentials (Cloudflare, Route53, dll)

## Phase 1: Infrastructure Setup (2-4 jam)

### 1.1 Install Core Components
- [ ] Install Argo CD
  ```bash
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  ```
- [ ] Install External-DNS untuk auto DNS management
- [ ] Install Cert-Manager untuk auto SSL certificates
- [ ] Install Nginx Ingress Controller

### 1.2 Configure DNS
- [ ] Create wildcard DNS record: `*.preview.yourapp.com` → Ingress LoadBalancer IP
- [ ] Verify DNS propagation: `dig pr-test.preview.yourapp.com`

### 1.3 Configure SSL
- [ ] Create ClusterIssuer untuk Let's Encrypt
- [ ] Test cert generation dengan dummy Ingress
- [ ] Verify cert valid dan trusted

## Phase 2: Argo CD Configuration (1-2 jam)

### 2.1 Setup ApplicationSet
- [ ] Deploy `manifests/applicationset.yaml`
- [ ] Create GitHub token dengan `repo` scope
- [ ] Store token di Kubernetes Secret: `github-token`
- [ ] Configure ApplicationSet generator untuk repo Anda

### 2.2 Test ApplicationSet
- [ ] Create test PR dengan label `preview`
- [ ] Verify Argo Application auto-created
- [ ] Check sync status: `argocd app get pr-{number}`
- [ ] Verify namespace created: `kubectl get ns | grep pr-`

## Phase 3: CI/CD Integration (2-3 jam)

### 3.1 GitHub Actions Workflow
- [ ] Copy `.github-workflow-example.yaml` ke `.github/workflows/preview-env.yaml`
- [ ] Update registry, domain, credentials
- [ ] Add `GITHUB_TOKEN` dengan packages:write permission
- [ ] Test workflow dengan test PR

### 3.2 Container Registry
- [ ] Setup GHCR atau private registry
- [ ] Configure image pull secrets di Kubernetes
- [ ] Test image push dan pull

### 3.3 Build Pipeline
- [ ] Ensure Dockerfile optimized (multi-stage, caching)
- [ ] Add health check endpoint
- [ ] Configure readiness/liveness probes

## Phase 4: Resource Management (1-2 jam)

### 4.1 Resource Limits
- [ ] Deploy `manifests/resourcequota.yaml` per preview namespace
- [ ] Set default LimitRange
- [ ] Test enforcement: create pod exceeding limits

### 4.2 Cost Monitoring
- [ ] Deploy cost-report script sebagai CronJob
- [ ] Setup Prometheus metrics (optional)
- [ ] Create Grafana dashboard (optional)

### 4.3 Cleanup Automation
- [ ] Deploy `scripts/cleanup-reaper.sh` sebagai CronJob
- [ ] Configure TTL (default 24h)
- [ ] Test cleanup: create old namespace, wait for reaper

## Phase 5: Security Hardening (1-2 jam)

### 5.1 Network Policies
- [ ] Create NetworkPolicy untuk isolasi antar PR namespaces
- [ ] Whitelist egress ke required external services
- [ ] Test isolation: try cross-namespace access

### 5.2 Authentication
- [ ] Setup basic auth untuk preview URLs (nginx auth)
- [ ] Or integrate OAuth proxy (oauth2-proxy)
- [ ] Distribute credentials securely

### 5.3 Secrets Management
- [ ] Install External Secrets Operator (optional)
- [ ] Sync secrets dari Vault/AWS Secrets Manager
- [ ] Never commit secrets ke Git

## Phase 6: Database Strategy (2-3 jam)

Choose ONE strategy:

### Option A: Shared Database dengan Schema Isolation
- [ ] Deploy shared PostgreSQL instance
- [ ] Create init script untuk auto-create schema per PR
- [ ] Configure app connection string: `?schema=pr_{number}`
- [ ] Test: verify data isolation antar PRs

### Option B: Ephemeral Database per PR
- [ ] Install CloudNativePG operator
- [ ] Create Cluster template di manifests
- [ ] Setup automated seeding dari prod snapshot
- [ ] Test: create PR, verify DB provisioned

## Phase 7: Developer Experience (1 jam)

### 7.1 Documentation
- [ ] Write internal docs: cara trigger preview env
- [ ] Document credentials dan access
- [ ] Create troubleshooting guide

### 7.2 Notifications
- [ ] Configure bot comment di PR dengan URL
- [ ] Add Slack notification (optional)
- [ ] Display deployment status badge

### 7.3 Ease of Use
- [ ] Create label `preview` di GitHub repo
- [ ] Train team: demo cara pakai
- [ ] Collect feedback dan iterate

## Phase 8: Testing & Validation (2-3 jam)

### 8.1 Happy Path
- [ ] Create PR, add `preview` label
- [ ] Wait for deployment (~3-5 min)
- [ ] Access preview URL, verify app works
- [ ] Check SSL cert valid
- [ ] Test app functionality

### 8.2 Edge Cases
- [ ] Test concurrent PRs (5-10 PRs sekaligus)
- [ ] Test resource limits: trigger OOM, CPU throttle
- [ ] Test cleanup: close PR, verify namespace deleted
- [ ] Test TTL expiry: wait 24h, verify auto-cleanup
- [ ] Test failed deployments: broken image, crashloop

### 8.3 Load Testing
- [ ] Simulate 20-30 active PRs
- [ ] Monitor cluster resource usage
- [ ] Verify cluster stable, no noisy neighbor issues

## Phase 9: Monitoring & Observability (1-2 jam)

### 9.1 Metrics
- [ ] Track: active environments count
- [ ] Track: total resource usage (CPU/RAM)
- [ ] Track: cost per PR, total cost
- [ ] Track: deployment duration

### 9.2 Alerts
- [ ] Alert: preview resource usage >30% total cluster
- [ ] Alert: single PR cost >$10/day
- [ ] Alert: deployment failed
- [ ] Alert: TTL enforcement failing

### 9.3 Dashboards
- [ ] Grafana dashboard: overview semua preview envs
- [ ] Cost breakdown per team/repo
- [ ] Deployment success rate

## Phase 10: Production Rollout (1 hari)

### 10.1 Pilot Program
- [ ] Enable untuk 1-2 repos dulu
- [ ] Collect feedback dari early adopters
- [ ] Fix bugs dan improve DX

### 10.2 Gradual Rollout
- [ ] Enable untuk semua repos
- [ ] Communicate via engineering all-hands
- [ ] Provide support channel (Slack)

### 10.3 Optimization
- [ ] Analyze cost reports, optimize resource requests
- [ ] Tune TTL based on usage patterns
- [ ] Consider spot instances untuk cost saving

## Success Criteria
- [ ] ✅ <5 menit dari PR open sampai preview URL ready
- [ ] ✅ 95%+ deployment success rate
- [ ] ✅ Cost <$500/month untuk 20 active PRs average
- [ ] ✅ Zero manual DevOps intervention
- [ ] ✅ Developer satisfaction score >4/5

## Maintenance Tasks (Ongoing)

### Weekly
- [ ] Review cost reports
- [ ] Check untuk orphaned namespaces
- [ ] Update Argo CD, External-DNS, Cert-Manager

### Monthly
- [ ] Review resource quotas, adjust jika perlu
- [ ] Analyze usage patterns, optimize
- [ ] Update documentation

### Quarterly
- [ ] Survey developer satisfaction
- [ ] Review cost vs benefit
- [ ] Plan improvements

---

**Estimated Total Time**: 15-20 jam untuk full implementation  
**Team Size**: 1-2 DevOps engineers  
**Prerequisites Skills**: Kubernetes, Argo CD, CI/CD, basic scripting
