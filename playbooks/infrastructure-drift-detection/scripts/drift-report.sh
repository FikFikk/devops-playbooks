#!/bin/bash
# drift-report.sh - Generate comprehensive drift report with metrics

set -euo pipefail

WORKSPACE="${1:-production}"
TERRAFORM_DIR="${2:-.}"
OUTPUT_FILE="${3:-drift-metrics.json}"

cd "$TERRAFORM_DIR"

# Run drift check
terraform init -input=false > /dev/null 2>&1
terraform plan -refresh-only -detailed-exitcode -out=drift.tfplan > /dev/null 2>&1 || true

# Generate detailed metrics
terraform show -json drift.tfplan | jq '{
  timestamp: now | todateiso8601,
  workspace: "'$WORKSPACE'",
  summary: {
    total_resources: [.resource_changes[]? | select(.change.actions != ["no-op"])] | length,
    resources_updated: [.resource_changes[]? | select(.change.actions | contains(["update"]))] | length,
    resources_deleted: [.resource_changes[]? | select(.change.actions | contains(["delete"]))] | length,
    resources_created: [.resource_changes[]? | select(.change.actions | contains(["create"]))] | length
  },
  drift_by_type: (
    [.resource_changes[]? | select(.change.actions != ["no-op"])] 
    | group_by(.type) 
    | map({
        type: .[0].type,
        count: length,
        resources: [.[] | .address]
      })
  ),
  critical_drift: [
    .resource_changes[]? 
    | select(.change.actions != ["no-op"]) 
    | select(
        (.type | contains("security_group")) or 
        (.type | startswith("aws_iam")) or
        (.type | IN("aws_db_instance", "aws_rds_cluster", "aws_eks_cluster"))
      )
    | {
        address: .address,
        type: .type,
        actions: .change.actions
      }
  ],
  changes: [
    .resource_changes[]? 
    | select(.change.actions != ["no-op"]) 
    | {
        address: .address,
        type: .type,
        actions: .change.actions,
        before_sensitive: (.change.before_sensitive // false),
        after_sensitive: (.change.after_sensitive // false)
      }
  ]
}' > "$OUTPUT_FILE"

echo "Drift report generated: $OUTPUT_FILE"

# Display summary
jq -r '
"
=== Drift Detection Report ===
Workspace: \(.workspace)
Timestamp: \(.timestamp)

Summary:
  Total drifted resources: \(.summary.total_resources)
  - Updated: \(.summary.resources_updated)
  - Deleted: \(.summary.resources_deleted)
  - Created (unmanaged): \(.summary.resources_created)

Critical Drift: \(.critical_drift | length) resource(s)
\(if .critical_drift | length > 0 then 
  (.critical_drift | map("  - \(.address) (\(.type))") | join("\n"))
else
  "  None"
end)
"
' "$OUTPUT_FILE"

rm -f drift.tfplan
