# Secrets Management dengan HashiCorp Vault

## Pengantar

### Masalah yang Diselesaikan

Dalam praktik DevOps modern, pengelolaan secrets (password, API keys, tokens, sertifikat) adalah tantangan kritis:

- **Hardcoded secrets** di code repository (security nightmare)
- **Environment variables** yang tersebar dan tidak teraudit
- **Rotasi manual** credentials yang rawan error
- **Tidak ada audit trail** siapa akses apa dan kapan
- **Secrets sprawl** across multiple cloud providers dan tools

HashiCorp Vault menyelesaikan masalah ini dengan menyediakan:
- **Centralized secrets storage** dengan enkripsi at-rest dan in-transit
- **Dynamic secrets** yang generate on-demand dan auto-expire
- **Automatic rotation** untuk database credentials, cloud IAM, dll
- **Fine-grained access control** dengan policies
- **Complete audit logging** untuk compliance
- **Multi-cloud support** (AWS, GCP, Azure, Kubernetes)

### Kapan Menggunakan Vault?

✅ **Gunakan Vault jika:**
- Aplikasi butuh akses ke database, APIs, atau cloud resources
- Team size >5 orang yang butuh akses berbeda-beda
- Compliance requirements (SOC2, HIPAA, PCI-DSS)
- Multi-environment (dev, staging, prod) dengan secrets berbeda
- Kubernetes workloads yang butuh secrets injection

❌ **Alternatif lebih sederhana:**
- Tim kecil (<5 orang), single environment → pakai cloud-native (AWS Secrets Manager, GCP Secret Manager)
- Hanya butuh encrypt config files → `sops` + age/KMS
- Local development only → `.env` files dengan `.gitignore`

---

## Arsitektur dan Konsep

### Komponen Utama

```
┌─────────────────────────────────────────────────────────────┐
│                        Applications                          │
│    (API calls, SDK, CLI, External Secrets Operator)         │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│                      Vault Server                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │Auth Methods  │  │Secret Engines│  │Audit Devices │     │
│  │- Kubernetes  │  │- KV v2       │  │- File        │     │
│  │- AppRole     │  │- Database    │  │- Syslog      │     │
│  │- JWT/OIDC    │  │- AWS/GCP     │  │- Socket      │     │
│  │- LDAP        │  │- PKI         │  └──────────────┘     │
│  └──────────────┘  └──────────────┘                        │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐                        │
│  │Policies      │  │Storage Backend│                       │
│  │- ACL rules   │  │- Raft (HA)   │                       │
│  │- Path-based  │  │- Consul      │                       │
│  └──────────────┘  │- etcd        │                       │
│                    └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### Workflow Dasar

1. **Authentication**: Aplikasi authenticate ke Vault (via AppRole, K8s SA, JWT)
2. **Authorization**: Vault check policy apakah boleh akses path tertentu
3. **Secret Retrieval**: Vault return secret (static atau generate dynamic)
4. **Audit Log**: Semua akses tercatat
5. **Rotation** (optional): Dynamic secrets auto-expire, credentials dirotasi

---

## Implementation Guide

### Prerequisites

- Docker & Docker Compose (untuk local dev)
- Kubernetes cluster (untuk production setup)
- Helm 3.x
- `kubectl` configured
- `vault` CLI: https://developer.hashicorp.com/vault/downloads

```bash
# Install Vault CLI
wget https://releases.hashicorp.com/vault/1.17.0/vault_1.17.0_linux_amd64.zip
unzip vault_1.17.0_linux_amd64.zip
sudo mv vault /usr/local/bin/
vault version
```

---

## Setup 1: Development Environment (Docker)

### Step 1: Jalankan Vault Dev Server

```bash
# Dev mode: in-memory, auto-unsealed, root token = "root"
docker run -d \
  --name vault-dev \
  --cap-add=IPC_LOCK \
  -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  hashicorp/vault:1.17

# Set environment
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='dev-root-token'

# Verify
vault status
```

### Step 2: Enable KV Secrets Engine

```bash
# Enable KV v2 (versioned secrets)
vault secrets enable -path=secret kv-v2

# Write a secret
vault kv put secret/myapp/config \
  db_password="super-secret-password" \
  api_key="sk-1234567890abcdef"

# Read secret
vault kv get secret/myapp/config

# Get specific field
vault kv get -field=db_password secret/myapp/config
```

### Step 3: Create Policy & AppRole

```bash
# Create policy file
cat > myapp-policy.hcl <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read"]
}

path "secret/metadata/myapp/*" {
  capabilities = ["list"]
}
EOF

# Apply policy
vault policy write myapp-policy myapp-policy.hcl

# Enable AppRole auth
vault auth enable approle

# Create AppRole
vault write auth/approle/role/myapp \
  token_policies="myapp-policy" \
  token_ttl=1h \
  token_max_ttl=4h

# Get RoleID dan SecretID
vault read auth/approle/role/myapp/role-id
vault write -f auth/approle/role/myapp/secret-id
```

### Step 4: Aplikasi Login & Akses Secret

Lihat contoh kode di folder `examples/`.

---

## Setup 2: Production Environment (Kubernetes)

### Step 1: Install Vault dengan Helm

```bash
# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Vault dengan HA mode
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-values.yaml

# Wait for pods ready
kubectl -n vault get pods -w
```

Konfigurasi production ada di `vault-values.yaml`.

### Step 2: Initialize & Unseal Vault

```bash
# Exec ke pod
kubectl -n vault exec -it vault-0 -- sh

# Initialize (lakukan SEKALI saja!)
vault operator init -key-shares=5 -key-threshold=3

# Output akan memberi 5 unseal keys dan 1 root token
# SIMPAN INI DI TEMPAT AMAN (password manager, KMS-encrypted storage)

# Unseal (butuh 3 dari 5 keys)
vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>

# Login dengan root token
vault login <initial-root-token>

# Unseal vault-1 dan vault-2 juga (untuk HA)
kubectl -n vault exec -it vault-1 -- vault operator unseal <key-1>
# ... repeat untuk key-2, key-3
```

### Step 3: Enable Kubernetes Auth

```bash
# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

# Create policy for app
vault policy write myapp-policy - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
EOF

# Create Kubernetes role
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=default \
  policies=myapp-policy \
  ttl=1h
```

### Step 4: Deploy External Secrets Operator

External Secrets Operator (ESO) sync secrets dari Vault ke Kubernetes Secrets.

```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets-system \
  --create-namespace

# Apply SecretStore dan ExternalSecret
kubectl apply -f external-secrets-config.yaml
```

Lihat `external-secrets-config.yaml` untuk konfigurasi lengkap.

---

## Dynamic Secrets: Database Credentials

### Setup PostgreSQL Dynamic Secrets

```bash
# Enable database secrets engine
vault secrets enable database

# Configure PostgreSQL connection
vault write database/config/my-postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="myapp-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/mydb?sslmode=disable" \
  username="vault-admin" \
  password="vault-admin-password"

# Create role (template SQL untuk create user)
vault write database/roles/myapp-role \
  db_name=my-postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Generate credentials (on-demand!)
vault read database/creds/myapp-role

# Output:
# Key                Value
# ---                -----
# lease_id           database/creds/myapp-role/abc123
# lease_duration     1h
# username           v-approle-myapp-role-xyz789
# password           A1b2C3d4E5f6G7h8

# Credentials ini AUTO-EXPIRE setelah 1 jam!
# Vault akan auto-revoke user dari database
```

### Rotate Root Credentials

```bash
# Vault bisa auto-rotate root password yang dipakai untuk manage DB
vault write -f database/rotate-root/my-postgres
```

---

## Best Practices

### 1. **Never Use Root Token di Production**

Root token = unlimited power. Setelah initialize:

```bash
# Revoke root token
vault token revoke <root-token>

# Buat admin user dengan policy terbatas
vault policy write admin-policy admin-policy.hcl
vault token create -policy=admin-policy -period=8h
```

### 2. **Enable Audit Logging**

```bash
# File audit (untuk Kubernetes, mount persistent volume)
vault audit enable file file_path=/vault/audit/audit.log

# Atau kirim ke syslog/socket untuk centralized logging
vault audit enable syslog tag="vault" facility="AUTH"
```

### 3. **Least Privilege Policies**

```hcl
# ❌ JANGAN: terlalu permisif
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# ✅ LAKUKAN: spesifik per-app
path "secret/data/myapp/{{identity.entity.name}}/*" {
  capabilities = ["read"]
}

path "secret/data/shared/database" {
  capabilities = ["read"]
}
```

### 4. **Use Dynamic Secrets Dimana Possible**

Static secrets = manual rotation, stale credentials.
Dynamic secrets = auto-generated, auto-revoked, zero standing privileges.

**Prioritas:**
1. Dynamic secrets (database, cloud IAM) — **best**
2. Static secrets dengan automatic rotation
3. Static secrets manual (last resort)

### 5. **Secret Versioning & Rollback**

KV v2 menyimpan versi history:

```bash
# Get specific version
vault kv get -version=2 secret/myapp/config

# Rollback to previous version
vault kv rollback -version=2 secret/myapp/config

# Delete version (soft delete)
vault kv delete secret/myapp/config

# Undelete
vault kv undelete -versions=2 secret/myapp/config

# Permanent destroy
vault kv destroy -versions=1,2 secret/myapp/config
```

### 6. **Secure Unseal Keys**

Production setup:

- **Auto-unseal dengan KMS** (AWS KMS, GCP KMS, Azure Key Vault):
  ```hcl
  seal "awskms" {
    region     = "us-east-1"
    kms_key_id = "arn:aws:kms:us-east-1:123456789:key/abc-def"
  }
  ```
- **Shamir's Secret Sharing**: 5 keys, threshold 3, distribute ke 5 orang berbeda
- **NEVER** commit unseal keys ke Git atau Slack

### 7. **High Availability & Backup**

- Deploy minimal 3 replicas dengan Raft storage
- Backup raft snapshots secara berkala:
  ```bash
  vault operator raft snapshot save backup.snap
  ```
- Test disaster recovery procedure

### 8. **Network Security**

- TLS everywhere (`tls_disable = false`)
- Network policies untuk restrict akses pod ke Vault
- Firewall rules: hanya allow traffic dari known sources

---

## Pitfalls to Avoid

### ❌ 1. **Dev Mode di Production**

Dev mode tidak persist data, tidak encrypted, tidak HA. Pakai `server` mode dengan proper storage backend.

### ❌ 2. **Lupa Unseal Setelah Restart**

Vault sealed setelah pod restart. Auto-unseal dengan KMS atau setup monitoring/alert untuk sealed state.

### ❌ 3. **Long-lived Tokens**

Token dengan `period` atau `ttl` terlalu lama = security risk. Gunakan renewable tokens dengan reasonable TTL.

### ❌ 4. **Hardcode RoleID & SecretID**

AppRole's `role_id` boleh di public, tapi `secret_id` harus digenerate on-demand dan rotated. Jangan commit ke Git.

### ❌ 5. **Tidak Monitor Audit Logs**

Audit logs = goldmine untuk detect anomali. Integrate dengan SIEM atau log analytics.

### ❌ 6. **Single Storage Backend Failure**

Raft storage butuh quorum. Kalau majority nodes mati, cluster tidak available. Deploy 5 nodes untuk toleransi 2 failures.

### ❌ 7. **Inject Secrets Sebagai Env Vars**

Environment variables bisa di-dump atau leak via logs. Prefer:
- Volume mount (Vault Agent sidecar)
- Fetch on-demand dari aplikasi
- External Secrets Operator (sync ke K8s Secret, mount as volume)

---

## Monitoring & Troubleshooting

### Health Check Endpoints

```bash
# System health
curl http://vault:8200/v1/sys/health

# Initialized & unsealed: 200
# Sealed: 503
# Not initialized: 501

# Metrics (Prometheus format)
curl http://vault:8200/v1/sys/metrics?format=prometheus
```

### Key Metrics to Monitor

1. **Seal status**: `vault_core_unsealed` (harus = 1)
2. **Leadership**: `vault_core_active` (1 leader, others standby)
3. **Token operations**: `vault_token_create`, `vault_token_lookup`
4. **Secret reads**: `vault_secret_kv_count`
5. **Audit log write failures**: `vault_audit_log_request_failure`
6. **Request latency**: `vault_core_handle_request_duration`

### Common Issues

#### Vault Sealed

```bash
# Check status
vault status

# Unseal (butuh threshold keys)
vault operator unseal

# Atau enable auto-unseal dengan KMS
```

#### Permission Denied

```bash
# Debug: check token capabilities
vault token capabilities secret/myapp/config

# Check policy
vault policy read myapp-policy

# Pastikan token punya policy yang benar
vault token lookup
```

#### Connection Refused

```bash
# Check pod status
kubectl -n vault get pods

# Check service
kubectl -n vault get svc

# Check logs
kubectl -n vault logs vault-0

# Verify network policy tidak block traffic
kubectl get networkpolicies -A
```

#### Raft Storage Issues

```bash
# Check raft peers
vault operator raft list-peers

# Remove dead peer
vault operator raft remove-peer <node-id>

# Restore from snapshot
vault operator raft snapshot restore backup.snap
```

---

## Integration Examples

Lihat folder `examples/` untuk contoh kode aplikasi:

- **Python** (`examples/python-app/`)
- **Node.js** (`examples/nodejs-app/`)
- **Go** (`examples/go-app/`)
- **Java** (`examples/java-app/`)

Masing-masing contoh menunjukkan:
1. Authentication dengan AppRole
2. Read static secrets
3. Generate dynamic database credentials
4. Handle token renewal

---

## Migration Path

### Dari Environment Variables

1. Inventory semua env vars yang berisi secrets
2. Store ke Vault KV:
   ```bash
   vault kv put secret/myapp/config \
     DATABASE_URL="$DATABASE_URL" \
     API_KEY="$API_KEY"
   ```
3. Update aplikasi untuk fetch dari Vault (atau pakai Vault Agent)
4. Remove env vars dari deployment manifests
5. Rotate credentials

### Dari Kubernetes Secrets

1. Enable External Secrets Operator
2. Migrate secrets ke Vault:
   ```bash
   kubectl get secret mysecret -o json | \
     jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"' | \
     xargs -I {} vault kv put secret/myapp/{}
   ```
3. Deploy ExternalSecret CRD
4. Verify sync berhasil
5. Delete old Kubernetes Secret

### Dari AWS Secrets Manager / GCP Secret Manager

Gunakan `vault write` dengan script atau Terraform untuk bulk import.

---

## Terraform Module

Lihat `terraform/` untuk module yang setup:
- Vault installation di Kubernetes
- Auto-unseal dengan cloud KMS
- Auth methods configuration
- Policies & roles

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

---

## Referensi

### Official Documentation

- **HashiCorp Vault**: https://developer.hashicorp.com/vault/docs
- **Vault on Kubernetes**: https://developer.hashicorp.com/vault/docs/platform/k8s
- **Best Practices**: https://developer.hashicorp.com/vault/tutorials/operations/production-hardening

### Tools & Integrations

- **Vault Helm Chart**: https://github.com/hashicorp/vault-helm
- **External Secrets Operator**: https://external-secrets.io/
- **Vault CSI Provider**: https://github.com/hashicorp/vault-csi-provider
- **Vault Agent**: https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent

### Alternatives & Complementary Tools

- **Cloud-native**: AWS Secrets Manager, GCP Secret Manager, Azure Key Vault
- **Git-based**: `sops` + age/KMS untuk secrets di Git
- **Kubernetes-native**: Sealed Secrets, Kubernetes External Secrets
- **Zero-knowledge**: Doppler, Infisical

### Security Standards

- **CIS HashiCorp Vault Benchmark**: https://www.cisecurity.org/benchmark/hashicorp_vault
- **OWASP Secrets Management Cheat Sheet**: https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html

---

## Cheat Sheet

```bash
# Status & health
vault status
vault operator members

# Auth
vault login
vault token lookup

# Secrets (KV v2)
vault kv put secret/path key=value
vault kv get secret/path
vault kv get -field=key secret/path
vault kv list secret/
vault kv delete secret/path
vault kv rollback -version=1 secret/path

# Policies
vault policy list
vault policy read policy-name
vault policy write policy-name policy.hcl

# Tokens
vault token create -policy=mypolicy
vault token renew
vault token revoke

# AppRole
vault write auth/approle/role/myapp ...
vault read auth/approle/role/myapp/role-id
vault write -f auth/approle/role/myapp/secret-id
vault write auth/approle/login role_id=... secret_id=...

# Database dynamic secrets
vault read database/creds/role-name
vault lease revoke database/creds/role-name/lease-id

# Seal/unseal
vault operator seal
vault operator unseal

# Audit
vault audit enable file file_path=/path
vault audit list

# Backup/restore (Raft)
vault operator raft snapshot save backup.snap
vault operator raft snapshot restore backup.snap
```

---

**Dibuat oleh Hermes Agent** • Riset-backed DevOps playbooks • Updated 2026-06-21
