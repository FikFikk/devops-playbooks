#!/bin/bash
set -euo pipefail

NAMESPACE_PREFIX="pr-"
TTL_HOURS=${TTL_HOURS:-24}
GITHUB_TOKEN=${GITHUB_TOKEN}
GITHUB_REPO=${GITHUB_REPO}

echo "🧹 Starting ephemeral environment cleanup (TTL: ${TTL_HOURS}h)..."

for ns in $(kubectl get ns -o name | grep "^namespace/${NAMESPACE_PREFIX}"); do
    ns_name=$(echo $ns | cut -d/ -f2)
    pr_number=$(echo $ns_name | sed "s/${NAMESPACE_PREFIX}//")
    
    echo "Checking namespace: $ns_name (PR #$pr_number)"
    
    created_at=$(kubectl get $ns -o jsonpath='{.metadata.creationTimestamp}')
    created_epoch=$(date -d "$created_at" +%s)
    now_epoch=$(date +%s)
    age_hours=$(( ($now_epoch - $created_epoch) / 3600 ))
    
    pr_state=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/pulls/$pr_number" \
        | jq -r '.state // "closed"')
    
    should_delete=false
    reason=""
    
    if [ "$pr_state" = "closed" ]; then
        should_delete=true
        reason="PR #$pr_number is closed"
    elif [ $age_hours -gt $TTL_HOURS ]; then
        should_delete=true
        reason="Namespace older than ${TTL_HOURS}h (age: ${age_hours}h)"
    fi
    
    if [ "$should_delete" = true ]; then
        echo "  ❌ Deleting: $reason"
        
        kubectl delete namespace "$ns_name" --timeout=5m || true
        
        if [ "$pr_state" = "open" ]; then
            curl -X POST -H "Authorization: token $GITHUB_TOKEN" \
                -d "{\"body\":\"🧹 Preview environment expired (TTL: ${TTL_HOURS}h) dan telah dihapus otomatis.\"}" \
                "https://api.github.com/repos/$GITHUB_REPO/issues/$pr_number/comments" || true
        fi
        
        echo "  ✅ Deleted successfully"
    else
        echo "  ✓ Keeping (age: ${age_hours}h, PR state: $pr_state)"
    fi
done

echo "✅ Cleanup complete"
