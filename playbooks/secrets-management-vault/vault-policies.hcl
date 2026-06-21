# Vault Policy Examples
# Dokumentasi: https://developer.hashicorp.com/vault/docs/concepts/policies

# ============================================================
# Admin Policy - Full access kecuali root-protected paths
# ============================================================
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/health" {
  capabilities = ["read"]
}

path "sys/capabilities-self" {
  capabilities = ["read"]
}

# ============================================================
# Developer Policy - Read-only access to dev secrets
# ============================================================
path "secret/data/dev/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/dev/*" {
  capabilities = ["list", "read"]
}

# Bisa create/update di personal namespace
path "secret/data/dev/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/dev/{{identity.entity.name}}/*" {
  capabilities = ["list", "read", "delete"]
}

# ============================================================
# Application Policy - Least privilege untuk service
# ============================================================
# Read-only access ke app-specific secrets
path "secret/data/apps/myapp/*" {
  capabilities = ["read"]
}

path "secret/metadata/apps/myapp/*" {
  capabilities = ["list"]
}

# Generate dynamic database credentials
path "database/creds/myapp-readonly" {
  capabilities = ["read"]
}

# ============================================================
# CI/CD Policy - Deploy pipeline access
# ============================================================
# Read secrets untuk deployment
path "secret/data/prod/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/prod/*" {
  capabilities = ["list"]
}

# Update deployment tracking
path "secret/data/deployments/*" {
  capabilities = ["create", "update", "read"]
}

# Generate short-lived tokens untuk deployed apps
path "auth/token/create" {
  capabilities = ["create", "update"]
  allowed_parameters = {
    "policies" = ["app-*"]
    "ttl" = ["1h"]
  }
}

# ============================================================
# External Secrets Operator Policy
# ============================================================
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# ============================================================
# Database Admin Policy - Manage DB connections & roles
# ============================================================
path "database/config/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "database/roles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "database/creds/*" {
  capabilities = ["read"]
}

path "database/rotate-root/*" {
  capabilities = ["update"]
}

# ============================================================
# PKI Admin Policy - Manage certificates
# ============================================================
path "pki/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/issue/*" {
  capabilities = ["create", "update"]
}

path "pki/sign/*" {
  capabilities = ["create", "update"]
}

# ============================================================
# Audit Policy - Read-only access to audit logs
# ============================================================
path "sys/audit" {
  capabilities = ["read", "list"]
}

path "sys/audit-hash/*" {
  capabilities = ["create", "update"]
}

# ============================================================
# Response Wrapping - Untuk secure secret delivery
# ============================================================
path "sys/wrapping/wrap" {
  capabilities = ["create", "update"]
}

path "sys/wrapping/unwrap" {
  capabilities = ["create", "update"]
}

path "sys/wrapping/lookup" {
  capabilities = ["create", "update"]
}

# ============================================================
# Policy dengan IP restrictions
# ============================================================
path "secret/data/critical/*" {
  capabilities = ["read"]
  
  # Hanya allow dari internal network
  allowed_parameters = {
    "cidr_list" = ["10.0.0.0/8", "172.16.0.0/12"]
  }
}

# ============================================================
# Policy dengan time-based access
# ============================================================
path "secret/data/business-hours/*" {
  capabilities = ["read"]
  
  # Format: "day_of_week:HH:MM-day_of_week:HH:MM"
  # allowed_parameters = {
  #   "time" = ["monday:09:00-friday:17:00"]
  # }
}

# ============================================================
# Sentinel Policy (Enterprise) - Advanced logic
# ============================================================
# Requires Vault Enterprise
# import "time"
# import "strings"
#
# main = rule {
#   time.now.weekday >= 1 and time.now.weekday <= 5 and
#   time.now.hour >= 9 and time.now.hour < 17
# }
