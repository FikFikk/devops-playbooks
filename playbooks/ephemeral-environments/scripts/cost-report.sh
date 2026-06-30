#!/bin/bash
set -euo pipefail

echo "📊 Ephemeral Environments Cost Report"
echo "======================================"
echo ""

COST_PER_VCPU_HOUR=0.04
COST_PER_GB_HOUR=0.005

total_cost=0

for ns in $(kubectl get ns -o name | grep "^namespace/pr-"); do
    ns_name=$(echo $ns | cut -d/ -f2)
    pr_number=$(echo $ns_name | sed 's/pr-//')
    
    cpu_requests=$(kubectl get pods -n $ns_name -o json | \
        jq -r '.items[].spec.containers[].resources.requests.cpu // "0"' | \
        sed 's/m$//' | awk '{s+=$1} END {print s/1000}')
    
    mem_requests=$(kubectl get pods -n $ns_name -o json | \
        jq -r '.items[].spec.containers[].resources.requests.memory // "0"' | \
        sed 's/Mi$//' | awk '{s+=$1} END {print s/1024}')
    
    created_at=$(kubectl get $ns -o jsonpath='{.metadata.creationTimestamp}')
    age_hours=$(( ($(date +%s) - $(date -d "$created_at" +%s)) / 3600 ))
    
    env_cost=$(echo "$cpu_requests * $COST_PER_VCPU_HOUR * $age_hours + $mem_requests * $COST_PER_GB_HOUR * $age_hours" | bc -l)
    total_cost=$(echo "$total_cost + $env_cost" | bc -l)
    
    printf "PR #%-5s | Age: %3dh | CPU: %.2f | RAM: %.2fGB | Cost: \$%.2f\n" \
        "$pr_number" "$age_hours" "$cpu_requests" "$mem_requests" "$env_cost"
done

echo ""
echo "======================================"
printf "Total Cost: \$%.2f\n" "$total_cost"
printf "Estimated Monthly: \$%.2f\n" "$(echo "$total_cost * 30" | bc -l)"
