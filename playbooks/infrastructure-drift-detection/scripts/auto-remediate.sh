#!/bin/bash
# auto-remediate.sh - Automated drift remediation for approved resource types
# ⚠️  USE WITH CAUTION: Only for non-critical, approved resource types

set -euo pipefail

WORKSPACE="${1:-production}"
TERRAFORM_DIR="${2:-.}"
DRY_RUN="${DRY_RUN:-true}"

# Lista resource types yang boleh auto-remediate
# Tambahkan dengan hati-hati setelah testing
ALLOWED_RESOURCES=(
  "aws_s3_bucket_versioning"
  "aws_s3_bucket_lifecycle_configuration"
  "aws_s3_bucket_server_side_encryption_configuration"
  "aws_cloudwatch_log_group"
  "aws_cloudwatch_log_retention_policy"
  "aws_sns_topic_subscription"
)

# Resources yang TIDAK BOLEH auto-remediate (safety list)
FORBIDDEN_RESOURCES=(
  "aws_security_group"
  "aws_security_group_rule"
  "aws_iam_.*"
  "aws_db_instance"
  "aws_rds_cluster"
  "aws_eks_cluster"
  "aws_lambda_function"
  "aws_ec2_instance"
)

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

is_allowed_resource() {
  local resource=$1
  local resource_type=$(echo "$resource" | cut -d. -f1)
  
  # Check forbidden list first
  for forbidden in "${FORBIDDEN_RESOURCES[@]}"; do
    if [[ "$resource_type" =~ ^${forbidden}$ ]]; then
      return 1
    fi
  done
  
  # Check allowed list
  for allowed in "${ALLOWED_RESOURCES[@]}"; do
    if [[ "$resource_type" == "$allowed" ]]; then
      return 0
    fi
  done
  
  return 1
}

cd "$TERRAFORM_DIR"

log_info "Running drift detection for workspace: $WORKSPACE"
terraform init -input=false -backend-config="key=$WORKSPACE/terraform.tfstate" > /dev/null

if terraform workspace list 2>/dev/null | grep -q "$WORKSPACE"; then
  terraform workspace select "$WORKSPACE" > /dev/null
fi

# Generate plan
log_info "Generating drift plan..."
if ! terraform plan -refresh-only -detailed-exitcode -out=drift.tfplan > /dev/null 2>&1; then
  EXIT_CODE=$?
  
  if [ $EXIT_CODE -ne 2 ]; then
    log_error "Terraform plan failed"
    exit 1
  fi
  
  log_info "Drift detected, analyzing changes..."
  
  # Parse drifted resources
  DRIFTED=$(terraform show -json drift.tfplan | jq -r '
    .resource_changes[]? | 
    select(.change.actions != ["no-op"]) | 
    .address
  ' 2>/dev/null)
  
  if [ -z "$DRIFTED" ]; then
    log_info "No resources to remediate"
    exit 0
  fi
  
  AUTO_REMEDIATE=()
  MANUAL_REVIEW=()
  
  while IFS= read -r resource; do
    if is_allowed_resource "$resource"; then
      AUTO_REMEDIATE+=("$resource")
    else
      MANUAL_REVIEW+=("$resource")
    fi
  done <<< "$DRIFTED"
  
  # Report
  if [ ${#AUTO_REMEDIATE[@]} -gt 0 ]; then
    log_info "Resources eligible for auto-remediation:"
    printf '  - %s\n' "${AUTO_REMEDIATE[@]}"
  fi
  
  if [ ${#MANUAL_REVIEW[@]} -gt 0 ]; then
    log_warn "Resources requiring manual review:"
    printf '  - %s\n' "${MANUAL_REVIEW[@]}"
  fi
  
  # Remediate
  if [ ${#AUTO_REMEDIATE[@]} -gt 0 ]; then
    if [ "$DRY_RUN" = "true" ]; then
      log_info "DRY RUN mode - would remediate:"
      for resource in "${AUTO_REMEDIATE[@]}"; do
        log_info "  terraform apply -target=\"$resource\" -auto-approve"
      done
    else
      log_warn "Applying auto-remediation..."
      for resource in "${AUTO_REMEDIATE[@]}"; do
        log_info "Remediating: $resource"
        if terraform apply -target="$resource" -auto-approve; then
          log_info "✅ Successfully remediated: $resource"
        else
          log_error "❌ Failed to remediate: $resource"
        fi
      done
    fi
  fi
  
  # Exit with code indicating manual review needed
  if [ ${#MANUAL_REVIEW[@]} -gt 0 ]; then
    exit 3
  fi
  
else
  log_info "✅ No drift detected"
fi

rm -f drift.tfplan
exit 0
