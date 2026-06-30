# Ephemeral Environments: PR-Based Preview Environments untuk Fast Feedback

## 📊 Overview

Ephemeral Environments (juga disebut Preview Environments atau Dynamic Environments) adalah environment sementara yang otomatis dibuat untuk setiap Pull Request, digunakan untuk testing dan review, lalu dihapus otomatis setelah PR merged/closed. Playbook ini implementasi full-stack ephemeral env menggunakan Kubernetes, Argo CD, dan automation tools modern.

## 🎯 Masalah yang Diselesaikan

### Problem Statement
- **Shared Staging Conflicts**: Multiple developers share 1 staging env → race condition, flaky tests
- **Slow Feedback Loop**: Merge ke staging → wait deploy → test → rollback if broken (30-60 menit)
- **High Infrastructure Cost**: Permanent staging/QA environments idle 60-70% waktu tapi tetap running
- **Production-like Testing**: Dev env tidak realistic, staging conflicts, production surprise
- **Manual Environment Management**: DevOps bottleneck buat/hapus test environments

### Impact
- 40-60 menit wasted per PR karena environment conflicts
- $5k-15k/month wasted untuk idle staging environments
- 25-40% bugs escaped ke production karena inadequate testing
- DevOps team spend 15-20% time managing ephemeral test requests

## 🏗️ Arsitektur Solusi

```
┌─────────────────────────────────────────────────────────────┐
│                  Ephemeral Environments                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Pull Request Event (GitHub/GitLab)                          │
│           │                                                   │
│           ▼                                                   │
│  ┌─────────────────┐                                         │
│  │  CI Pipeline    │  (GitHub Actions / GitLab CI)           │
│  │  - Build image  │                                         │
│  │  - Run tests    │                                         │
│  │  - Trigger env  │                                         │
│  └────────┬────────┘                                         │
│           │                                                   │
│           ▼                                                   │
│  ┌─────────────────────────────────┐                         │
│  │  Argo CD ApplicationSet          │                        │
│  │  - Auto-generate Application     │                        │
│  │  - Deploy to namespace pr-{num}  │                        │
│  │  - Inject PR-specific config     │                        │
│  └────────┬────────────────────────┘                         │
│           │                                                   │
│           ▼                                                   │
│  ┌──────────────────────────────────────┐                    │
│  │  Kubernetes Cluster                  │                    │
│  │                                       │                    │
│  │  ┌─────────────┐  ┌─────────────┐   │                    │
│  │  │ Namespace   │  │ Namespace   │   │                    │
│  │  │ pr-1234     │  │ pr-5678     │   │                    │
│  │  │             │  │             │   │                    │
│  │  │ • Frontend  │  │ • Frontend  │   │                    │
│  │  │ • Backend   │  │ • Backend   │   │                    │
│  │  │ • Database  │  │ • Database  │   │                    │
│  │  └─────────────┘  └─────────────┘   │                    │
│  │                                       │                    │
│  │  External DNS: pr-1234.preview.app   │                    │
│  │                pr-5678.preview.app   │                    │
│  └──────────────────────────────────────┘                    │
│           │                                                   │
│           ▼                                                   │
│  ┌─────────────────┐                                         │
│  │  Cleanup Job    │  (CronJob / Reaper)                     │
│  │  - TTL expired  │                                         │
│  │  - PR closed    │                                         │
│  │  - Delete ns    │                                         │
│  └─────────────────┘                                         │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

## 🚀 Implementation Guide

### Prerequisites
- Kubernetes cluster (1.25+) dengan RBAC enabled
- Argo CD installed
- Cert-Manager untuk SSL otomatis
- External-DNS (optional tapi recommended)
- GitHub/GitLab dengan webhook access

### Step 1: Setup Argo CD ApplicationSet

ApplicationSet adalah core pattern untuk auto-generate Argo Applications dari PR list.

```yaml
# manifests/applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ephemeral-pr-envs
  namespace: argocd
spec:
  generators:
  # Git Generator: scan pull requests
  - pullRequest:
      github:
        owner: your-org
        repo: your-app
        tokenSecretRef:
          secretName: github-token
          key: token
        labels:
        - preview  # Only PRs with 'preview' label
      requeueAfterSeconds: 30
  
  template:
    metadata:
      name: 'pr-{{number}}'
      annotations:
        pr-url: '{{url}}'
        pr-author: '{{author}}'
        created-at: '{{createdAt}}'
    spec:
      project: ephemeral
      source:
        repoURL: https://github.com/your-org/your-app
        targetRevision: '{{head_sha}}'
        path: kubernetes/overlays/preview
        helm:
          parameters:
          - name: image.tag
            value: 'pr-{{number}}'
          - name: ingress.host
            value: 'pr-{{number}}.preview.yourapp.com'
          - name: pr.number
            value: '{{number}}'
          - name: pr.branch
            value: '{{branch}}'
      
      destination:
        server: https://kubernetes.default.svc
        namespace: 'pr-{{number}}'
      
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
        
      # Auto-cleanup ketika PR closed
      info:
        - name: PR
          value: '{{number}}'
