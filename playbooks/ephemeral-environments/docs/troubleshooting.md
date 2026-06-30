# Troubleshooting Guide - Ephemeral Environments

## Common Issues & Solutions

### 1. Preview URL Returns 404

**Symptoms**: PR deployed, namespace exists, tapi URL 404

**Diagnosis**:
```bash
PR_NUM=1234

# Check ingress created
kubectl get ingress -n pr-$PR_NUM

# Check ingress details
kubectl describe ingress -n pr-$PR_NUM

# Check external-dns logs
kubectl logs -n external-dns -l app=external-dns --tail=100

# Check DNS resolution
dig pr-$PR_NUM.preview.yourapp.com
```

**Common Causes**:
- DNS belum propagate (wait 1-5 menit)
- External-DNS misconfigured atau tidak running
- Ingress annotations salah
- Domain tidak match filter di External-DNS

**Solutions**:
```bash
# Force External-DNS sync
kubectl annotate ingress -n pr-$PR_NUM preview-ingress \
  external-dns.alpha.kubernetes.io/ttl=60 --overwrite

# Check External-DNS config
kubectl get deployment -n external-dns external-dns -o yaml | grep -A5 domainFilters
```

---

### 2. SSL Certificate Pending

**Symptoms**: URL accessible via HTTP, HTTPS shows cert error

**Diagnosis**:
```bash
# Check certificate status
kubectl get certificate -n pr-$PR_NUM

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=100

# Check certificate details
kubectl describe certificate -n pr-$PR_NUM pr-$PR_NUM-tls
```

**Common Causes**:
- Cert-Manager ClusterIssuer misconfigured
- Let's Encrypt rate limit hit (5 certs/week per domain)
- DNS01/HTTP01 challenge failing
- Firewall blocking Let's Encrypt validation

**Solutions**:
```bash
# Delete and recreate certificate
kubectl delete certificate -n pr-$PR_NUM pr-$PR_NUM-tls

# Use staging Let's Encrypt untuk testing
kubectl edit clusterissuer letsencrypt-prod
# Change server to: https://acme-staging-v02.api.letsencrypt.org/directory

# Check ACME challenge
kubectl get challenge -n pr-$PR_NUM
kubectl describe challenge -n pr-$PR_NUM <challenge-name>
```

---

### 3. Pod CrashLoopBackOff

**Symptoms**: Deployment created, pod keeps restarting

**Diagnosis**:
```bash
# Check pod status
kubectl get pods -n pr-$PR_NUM

# Check recent logs
kubectl logs -n pr-$PR_NUM <pod-name> --previous --tail=100

# Check events
kubectl get events -n pr-$PR_NUM --sort-by='.lastTimestamp' | tail -20

# Check resource limits
kubectl describe pod -n pr-$PR_NUM <pod-name> | grep -A10 "Limits\\|Requests"
```

**Common Causes**:
- Aplikasi crash on startup (config error, missing env vars)
- Resource limits terlalu kecil (OOMKilled)
- Health check terlalu aggressive (killed before ready)
- Missing dependencies (database, Redis, etc)

**Solutions**:
```bash
# Increase resource limits
kubectl patch deployment -n pr-$PR_NUM app -p '
spec:
  template:
    spec:
      containers:
      - name: app
        resources:
          limits:
            memory: 1Gi
            cpu: 1000m
'

# Adjust readiness probe
kubectl patch deployment -n pr-$PR_NUM app -p '
spec:
  template:
    spec:
      containers:
      - name: app
        readinessProbe:
          initialDelaySeconds: 30
          periodSeconds: 10
'

# Check application logs untuk root cause
kubectl logs -n pr-$PR_NUM <pod-name> -f
```

---

### 4. Database Connection Timeout

**Symptoms**: App logs show "connection refused" atau "timeout"

**Diagnosis**:
```bash
# Check database pod running
kubectl get pods -n pr-$PR_NUM -l app=postgres

# Test connectivity dari app pod
kubectl exec -n pr-$PR_NUM deploy/app -- nc -zv postgres 5432

# Check database logs
kubectl logs -n pr-$PR_NUM <postgres-pod> --tail=100

# Verify credentials
kubectl get secret -n pr-$PR_NUM db-credentials -o jsonpath='{.data.password}' | base64 -d
```

**Common Causes**:
- Database pod belum ready (masih initializing)
- Wrong service name (postgres vs postgres-svc)
- NetworkPolicy blocking traffic
- Database initialization failed

**Solutions**:
```bash
# Wait untuk database ready
kubectl wait --for=condition=ready pod -n pr-$PR_NUM -l app=postgres --timeout=300s

# Test manual connection
kubectl exec -n pr-$PR_NUM <postgres-pod> -- psql -U postgres -c "SELECT 1"

# Check NetworkPolicy
kubectl get networkpolicy -n pr-$PR_NUM
```

---

### 5. Argo CD Application OutOfSync

**Symptoms**: Argo shows "OutOfSync", changes tidak reflected

**Diagnosis**:
```bash
# Check application status
argocd app get pr-$PR_NUM

# Check sync status
argocd app sync pr-$PR_NUM --dry-run

# Check logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
```

**Common Causes**:
- Git repo tidak accessible (wrong credentials)
- Target revision (commit SHA) tidak exist
- Helm values invalid
- ApplicationSet generator misconfigured

**Solutions**:
```bash
# Force sync
argocd app sync pr-$PR_NUM --force

# Refresh app
argocd app get pr-$PR_NUM --refresh

# Check ApplicationSet
kubectl get applicationset -n argocd ephemeral-pr-envs -o yaml
```

---

### 6. Cleanup Reaper Tidak Jalan

**Symptoms**: Old namespaces tidak dihapus after TTL

**Diagnosis**:
```bash
# Check CronJob exists
kubectl get cronjob -n kube-system ephemeral-cleanup

# Check last run
kubectl get jobs -n kube-system -l cronjob=ephemeral-cleanup --sort-by=.metadata.creationTimestamp

# Check logs dari last job
kubectl logs -n kube-system job/<latest-job-name>
```

**Common Causes**:
- CronJob suspended atau schedule salah
- GitHub token expired atau invalid
- Script error (bash syntax, kubectl not found)
- Permission denied (ServiceAccount tidak punya cluster-admin)

**Solutions**:
```bash
# Manual trigger job
kubectl create job -n kube-system --from=cronjob/ephemeral-cleanup manual-cleanup-$(date +%s)

# Check ServiceAccount permissions
kubectl auth can-i delete namespace --as=system:serviceaccount:kube-system:cleanup-reaper

# Update GitHub token
kubectl create secret generic github-token -n kube-system \
  --from-literal=token=<your-new-token> \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### 7. High Resource Usage / Cluster Overload

**Symptoms**: Cluster slow, pods pending, OOM kills frequent

**Diagnosis**:
```bash
# Check total preview resource usage
kubectl top nodes

# Count active preview envs
kubectl get ns | grep "^pr-" | wc -l

# Check pending pods
kubectl get pods -A | grep Pending

# Resource usage per namespace
for ns in $(kubectl get ns -o name | grep pr-); do
  echo "=== $ns ==="
  kubectl top pods -n $(echo $ns | cut -d/ -f2) 2>/dev/null || echo "No pods"
done
```

**Common Causes**:
- Terlalu banyak PRs active sekaligus
- Resource quotas tidak enforced
- No cleanup enforcement (old envs menumpuk)
- Resource requests terlalu besar

**Solutions**:
```bash
# Emergency: delete oldest environments
kubectl get ns -l app=ephemeral -o json | \
  jq -r '.items | sort_by(.metadata.creationTimestamp) | .[0:10] | .[].metadata.name' | \
  xargs -I {} kubectl delete ns {} --timeout=2m

# Enforce stricter resource quotas
kubectl apply -f manifests/resourcequota.yaml -A

# Reduce TTL
# Edit cleanup-reaper.sh: TTL_HOURS=12

# Scale down nodes (if using cluster autoscaler)
kubectl scale deployment -n pr-<old-pr> app --replicas=0
```

---

### 8. Cost Overrun

**Symptoms**: Preview environments cost >$1000/month, finance complaining

**Diagnosis**:
```bash
# Run cost report
./scripts/cost-report.sh

# Check most expensive PRs
kubectl get ns -o json | jq -r '
.items[] | select(.metadata.name | startswith("pr-")) |
{
  name: .metadata.name,
  age: ((now - (.metadata.creationTimestamp | fromdateiso8601)) / 3600 | floor)
} | "\(.name) - \(.age)h"
' | sort -t- -k3 -n -r | head -10
```

**Common Causes**:
- No TTL enforcement (envs running weeks)
- Too many concurrent PRs
- Resource requests too high
- Not using spot instances

**Solutions**:
```bash
# Aggressive cleanup: TTL=12h
# Edit CronJob env: TTL_HOURS=12

# Reduce resource requests by 50%
# Edit manifests/kustomization.yaml patches

# Use spot instances
# Add node selector/tolerations untuk spot nodes

# Require approval untuk >24h extension
# Add manual approval workflow
```

---

## Emergency Procedures

### Kill Switch: Delete All Preview Environments
```bash
# WARNING: This deletes ALL preview environments
kubectl get ns -o name | grep "^namespace/pr-" | xargs kubectl delete --timeout=2m
```

### Pause New Deployments
```bash
# Suspend ApplicationSet
kubectl patch applicationset -n argocd ephemeral-pr-envs -p '{"spec":{"generators":[{"list":{"elements":[]}}]}}'
```

### Resume Normal Operations
```bash
# Resume ApplicationSet
kubectl patch applicationset -n argocd ephemeral-pr-envs --type=json \
  -p '[{"op":"remove","path":"/spec/generators/0/list"}]'
```

---

## Performance Optimization Tips

1. **Faster Deployments**:
   - Pre-pull common images ke all nodes
   - Use image pull secrets dengan registry mirror
   - Optimize Dockerfile (multi-stage, smaller base image)

2. **Lower Costs**:
   - Use spot instances untuk preview workloads
   - Aggressive resource right-sizing
   - Consider cluster-autoscaler scale-from-zero

3. **Better Reliability**:
   - Add retry logic di init containers
   - Increase readiness probe delays
   - Use PodDisruptionBudgets

---

**Last Updated**: 2026-06-30  
**Maintainer**: DevOps Team
