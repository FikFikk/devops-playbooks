#!/bin/bash
# cron-drift-check.sh - Wrapper untuk cron job drift detection
# Add to crontab: 0 2 * * * /path/to/cron-drift-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/drift-detection}"
ENVIRONMENTS=("production" "staging")

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/drift-check-$(date +%Y%m%d).log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Starting scheduled drift detection ==="

for env in "${ENVIRONMENTS[@]}"; do
  log "Checking environment: $env"
  
  if "$SCRIPT_DIR/detect-drift.sh" "$env" "/opt/terraform/$env" >> "$LOG_FILE" 2>&1; then
    log "✅ $env: No drift detected"
  else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
      log "⚠️  $env: DRIFT DETECTED - Alert sent"
    else
      log "❌ $env: Check failed with exit code $EXIT_CODE"
    fi
  fi
done

log "=== Drift detection completed ==="

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "drift-check-*.log" -mtime +30 -delete

# Rotate large logs
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE") -gt 10485760 ]; then
  gzip "$LOG_FILE"
fi
