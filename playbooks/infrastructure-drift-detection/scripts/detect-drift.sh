#!/bin/bash
# detect-drift.sh - Automated infrastructure drift detection
# Usage: ./detect-drift.sh <workspace> [terraform-dir]

set -euo pipefail

WORKSPACE="${1:-production}"
TERRAFORM_DIR="${2:-.}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./drift-reports}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

REPORT_FILE="$OUTPUT_DIR/drift-report-${WORKSPACE}-$(date +%Y%m%d-%H%M%S).txt"
JSON_FILE="$OUTPUT_DIR/drift-report-${WORKSPACE}-$(date +%Y%m%d-%H%M%S).json"

log_info "🔍 Checking drift for workspace: $WORKSPACE"
log_info "Terraform directory: $TERRAFORM_DIR"

cd "$TERRAFORM_DIR"

# Initialize Terraform
log_info "Initializing Terraform..."
if ! terraform init -input=false -backend-config="key=$WORKSPACE/terraform.tfstate" > /dev/null 2>&1; then
  log_error "Terraform init failed"
  exit 1
fi

# Select workspace if using workspace feature
if terraform workspace list 2>/dev/null | grep -q "$WORKSPACE"; then
  log_info "Selecting workspace: $WORKSPACE"
  terraform workspace select "$WORKSPACE"
fi

# Run plan in refresh-only mode
log_info "Running drift detection..."
EXIT_CODE=0
terraform plan -refresh-only -detailed-exitcode -out=drift.tfplan > "$REPORT_FILE" 2>&1 || EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  log_info "✅ No drift detected"
  echo "No drift detected at $(date)" > "$REPORT_FILE"
  exit 0
elif [ $EXIT_CODE -eq 2 ]; then
  log_warn "⚠️  DRIFT DETECTED"
  
  # Generate JSON report
  terraform show -json drift.tfplan > "$JSON_FILE"
  
  # Extract changed resources
  CHANGES=$(jq -r '
    .resource_changes[]? | 
    select(.change.actions != ["no-op"]) | 
    {
      address: .address,
      actions: .change.actions,
      before: .change.before,
      after: .change.after
    }
  ' "$JSON_FILE" 2>/dev/null || echo "Failed to parse changes")
  
  # Count changes
  CHANGE_COUNT=$(echo "$CHANGES" | jq -s 'length' 2>/dev/null || echo "unknown")
  
  # Create summary
  SUMMARY=$(jq -r '
    .resource_changes[]? | 
    select(.change.actions != ["no-op"]) | 
    "\(.address): \(.change.actions | join(", "))"
  ' "$JSON_FILE" 2>/dev/null | head -20)
  
  log_warn "Changes detected:"
  echo "$SUMMARY"
  
  # Save summary to file
  {
    echo "=== Infrastructure Drift Report ==="
    echo "Workspace: $WORKSPACE"
    echo "Detected: $(date -Iseconds)"
    echo "Changes: $CHANGE_COUNT resources"
    echo ""
    echo "=== Changed Resources ==="
    echo "$SUMMARY"
    echo ""
    echo "=== Full Report ==="
    cat "$REPORT_FILE"
  } > "${REPORT_FILE}.summary"
  
  # Send to Slack if webhook configured
  if [ -n "$SLACK_WEBHOOK" ]; then
    log_info "Sending notification to Slack..."
    
    # Truncate for Slack (max 3000 chars in block)
    SLACK_SUMMARY=$(echo "$SUMMARY" | head -c 2800)
    
    curl -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{
        \"text\": \"🚨 Infrastructure Drift Detected in \`$WORKSPACE\`\",
        \"blocks\": [
          {
            \"type\": \"header\",
            \"text\": {
              \"type\": \"plain_text\",
              \"text\": \"🚨 Infrastructure Drift Alert\"
            }
          },
          {
            \"type\": \"section\",
            \"fields\": [
              {\"type\": \"mrkdwn\", \"text\": \"*Environment:*\n\`$WORKSPACE\`\"},
              {\"type\": \"mrkdwn\", \"text\": \"*Changes:*\n$CHANGE_COUNT resources\"},
              {\"type\": \"mrkdwn\", \"text\": \"*Detected:*\n$(date '+%Y-%m-%d %H:%M:%S')\"}
            ]
          },
          {
            \"type\": \"section\",
            \"text\": {
              \"type\": \"mrkdwn\",
              \"text\": \"*Changed Resources:*\n\`\`\`$SLACK_SUMMARY\`\`\`\"
            }
          },
          {
            \"type\": \"context\",
            \"elements\": [
              {
                \"type\": \"mrkdwn\",
                \"text\": \"Review the full report and take action: update IaC or remediate drift\"
              }
            ]
          }
        ]
      }" 2>/dev/null || log_warn "Failed to send Slack notification"
  fi
  
  # Output report location
  log_info "Drift report saved to: $REPORT_FILE"
  log_info "JSON report saved to: $JSON_FILE"
  
  # Clean up plan file
  rm -f drift.tfplan
  
  exit 2
else
  log_error "❌ Terraform plan failed with exit code: $EXIT_CODE"
  cat "$REPORT_FILE"
  exit 1
fi
