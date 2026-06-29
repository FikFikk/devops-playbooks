#!/bin/bash
#
# Right-Sizing Analysis Script
# Analyze pod resource allocation vs actual usage, generate recommendations
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-}"
THRESHOLD_CPU="${THRESHOLD_CPU:-50}"  # % idle untuk flag over-provisioning
THRESHOLD_MEM="${THRESHOLD_MEM:-50}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
MIN_COST_THRESHOLD="${MIN_COST_THRESHOLD:-10}"  # Skip pods <$10/month

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Analyze Kubernetes workload right-sizing opportunities.

OPTIONS:
    --namespace NS           Analyze specific namespace (default: all)
    --cpu-threshold PCT      CPU idle threshold % (default: 50)
    --mem-threshold PCT      Memory idle threshold % (default: 50)
    --lookback-days DAYS     Analysis window (default: 7)
    --min-cost COST          Min monthly cost untuk include (default: 10)
    --output-format FORMAT   csv|json|table (default: table)
    --apply-vpa              Generate VPA manifests untuk auto right-sizing
    --help                   Show this help

EXAMPLES:
    # Analyze semua namespaces
    $0

    # Specific namespace dengan custom thresholds
    $0 --namespace production --cpu-threshold 60 --mem-threshold 70

    # Generate VPA manifests
    $0 --namespace production --apply-vpa

EOF
    exit 0
}

# Parse arguments
OUTPUT_FORMAT="table"
APPLY_VPA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --cpu-threshold) THRESHOLD_CPU="$2"; shift 2 ;;
        --mem-threshold) THRESHOLD_MEM="$2"; shift 2 ;;
        --lookback-days) LOOKBACK_DAYS="$2"; shift 2 ;;
        --min-cost) MIN_COST_THRESHOLD="$2"; shift 2 ;;
        --output-format) OUTPUT_FORMAT="$2"; shift 2 ;;
        --apply-vpa) APPLY_VPA=true; shift ;;
        --help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Check dependencies
for cmd in kubectl jq bc; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd not found. Please install."
        exit 1
    fi
done

log_info "Starting right-sizing analysis..."
log_info "Lookback period: ${LOOKBACK_DAYS} days"
log_info "CPU threshold: ${THRESHOLD_CPU}% idle"
log_info "Memory threshold: ${THRESHOLD_MEM}% idle"

# Query Prometheus untuk usage data
PROM_URL=$(kubectl get svc -n monitoring prometheus-server -o jsonpath='{.spec.clusterIP}'):80
if [[ -z "$PROM_URL" ]]; then
    log_error "Cannot find Prometheus service"
    exit 1
fi

# Build namespace filter
NS_FILTER=""
if [[ -n "$NAMESPACE" ]]; then
    NS_FILTER="namespace=\"${NAMESPACE}\","
fi

log_info "Fetching metrics dari Prometheus..."

# Get CPU allocation vs usage
CPU_QUERY="avg_over_time(
    (
        sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"cpu\",${NS_FILTER}unit=\"core\"})
        -
        sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{${NS_FILTER}image!=\"\"}[5m]))
    )[${LOOKBACK_DAYS}d:5m]
) / 
avg_over_time(
    sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"cpu\",${NS_FILTER}unit=\"core\"})[${LOOKBACK_DAYS}d:5m]
) * 100"

# Get Memory allocation vs usage
MEM_QUERY="avg_over_time(
    (
        sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"memory\",${NS_FILTER}unit=\"byte\"})
        -
        sum by (namespace, pod) (container_memory_working_set_bytes{${NS_FILTER}image!=\"\"})
    )[${LOOKBACK_DAYS}d:5m]
) /
avg_over_time(
    sum by (namespace, pod) (kube_pod_container_resource_requests{resource=\"memory\",${NS_FILTER}unit=\"byte\"})[${LOOKBACK_DAYS}d:5m]
) * 100"

# Get cost per pod
COST_QUERY="sum by (namespace, pod) (
    rate(container_cpu_allocation{${NS_FILTER}}[1h]) * on (node) group_left node_cpu_hourly_cost * 730
    +
    container_memory_allocation_bytes{${NS_FILTER}} / 1e9 * on (node) group_left node_ram_hourly_cost * 730
)"

# Fetch data
CPU_DATA=$(kubectl exec -n monitoring svc/prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=$(echo "$CPU_QUERY" | tr -d '\n' | sed 's/ /%20/g')" | jq -r '.data.result[]')

MEM_DATA=$(kubectl exec -n monitoring svc/prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=$(echo "$MEM_QUERY" | tr -d '\n' | sed 's/ /%20/g')" | jq -r '.data.result[]')

COST_DATA=$(kubectl exec -n monitoring svc/prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=$(echo "$COST_QUERY" | tr -d '\n' | sed 's/ /%20/g')" | jq -r '.data.result[]')

log_info "Processing results..."

# Combine data dan calculate recommendations
RECOMMENDATIONS=$(jq -n \
    --argjson cpu_data "$CPU_DATA" \
    --argjson mem_data "$MEM_DATA" \
    --argjson cost_data "$COST_DATA" \
    --arg cpu_threshold "$THRESHOLD_CPU" \
    --arg mem_threshold "$THRESHOLD_MEM" \
    --arg min_cost "$MIN_COST_THRESHOLD" \
'
{
    recommendations: [
        $cost_data | 
        select(.value[1] | tonumber > ($min_cost | tonumber)) |
        . as $cost |
        {
            namespace: .metric.namespace,
            pod: .metric.pod,
            monthly_cost: (.value[1] | tonumber),
            cpu_idle_pct: (
                ($cpu_data[] | select(.metric.namespace == $cost.metric.namespace and .metric.pod == $cost.metric.pod).value[1]) // "0" | tonumber
            ),
            mem_idle_pct: (
                ($mem_data[] | select(.metric.namespace == $cost.metric.namespace and .metric.pod == $cost.metric.pod).value[1]) // "0" | tonumber
            )
        } |
        select(.cpu_idle_pct > ($cpu_threshold | tonumber) or .mem_idle_pct > ($mem_threshold | tonumber)) |
        . + {
            potential_savings: (.monthly_cost * ((.cpu_idle_pct + .mem_idle_pct) / 200)),
            severity: (
                if (.cpu_idle_pct > 70 or .mem_idle_pct > 70) then "high"
                elif (.cpu_idle_pct > 50 or .mem_idle_pct > 50) then "medium"
                else "low"
                end
            )
        }
    ] | sort_by(-.potential_savings)
}
')

# Output results
case "$OUTPUT_FORMAT" in
    json)
        echo "$RECOMMENDATIONS" | jq '.'
        ;;
    
    csv)
        echo "Namespace,Pod,Monthly Cost,CPU Idle %,Memory Idle %,Potential Savings,Severity"
        echo "$RECOMMENDATIONS" | jq -r '.recommendations[] | 
            [.namespace, .pod, .monthly_cost, .cpu_idle_pct, .mem_idle_pct, .potential_savings, .severity] | @csv'
        ;;
    
    table)
        echo ""
        echo -e "${BLUE}=== Right-Sizing Recommendations ===${NC}"
        echo ""
        
        TOTAL_SAVINGS=$(echo "$RECOMMENDATIONS" | jq '[.recommendations[].potential_savings] | add // 0')
        echo -e "Total Potential Monthly Savings: ${GREEN}\$$(printf "%.2f" $TOTAL_SAVINGS)${NC}"
        echo ""
        
        printf "%-20s %-40s %-12s %-10s %-10s %-12s %-8s\n" \
            "NAMESPACE" "POD" "COST/MO" "CPU IDLE" "MEM IDLE" "SAVINGS/MO" "SEVERITY"
        echo "----------------------------------------------------------------------------------------------------------------------------"
        
        echo "$RECOMMENDATIONS" | jq -r '.recommendations[] | 
            "\(.namespace)|\(.pod)|\(.monthly_cost)|\(.cpu_idle_pct)|\(.mem_idle_pct)|\(.potential_savings)|\(.severity)"' | \
        while IFS='|' read -r ns pod cost cpu_idle mem_idle savings severity; do
            # Color code severity
            case "$severity" in
                high) color=$RED ;;
                medium) color=$YELLOW ;;
                *) color=$NC ;;
            esac
            
            printf "%-20s %-40s ${color}$%-11.2f${NC} %-9.1f%% %-9.1f%% ${GREEN}$%-11.2f${NC} %-8s\n" \
                "$ns" "$pod" "$cost" "$cpu_idle" "$mem_idle" "$savings" "$severity"
        done
        echo ""
        ;;
esac

# Generate VPA manifests jika requested
if [[ "$APPLY_VPA" == true ]]; then
    log_info "Generating VPA manifests..."
    
    VPA_DIR="./vpa-manifests"
    mkdir -p "$VPA_DIR"
    
    echo "$RECOMMENDATIONS" | jq -r '.recommendations[] | "\(.namespace) \(.pod)"' | \
    while read -r ns pod; do
        # Get deployment/statefulset name (strip pod hash suffix)
        WORKLOAD=$(echo "$pod" | sed -E 's/-[a-z0-9]{5,10}-[a-z0-9]{5}$//' | sed -E 's/-[0-9]+$//')
        
        # Detect workload type
        if kubectl get deployment -n "$ns" "$WORKLOAD" &>/dev/null; then
            KIND="Deployment"
        elif kubectl get statefulset -n "$ns" "$WORKLOAD" &>/dev/null; then
            KIND="StatefulSet"
        else
            log_warn "Cannot determine workload type untuk $pod in $ns, skipping VPA"
            continue
        fi
        
        VPA_FILE="${VPA_DIR}/vpa-${ns}-${WORKLOAD}.yaml"
        
        cat > "$VPA_FILE" <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: ${WORKLOAD}-vpa
  namespace: ${ns}
spec:
  targetRef:
    apiVersion: apps/v1
    kind: ${KIND}
    name: ${WORKLOAD}
  updatePolicy:
    updateMode: "Auto"  # Auto apply recommendations (atau "Off" untuk recommendation only)
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 10m
        memory: 50Mi
      maxAllowed:
        cpu: 4
        memory: 8Gi
      controlledResources:
      - cpu
      - memory
EOF
        
        log_info "Generated VPA manifest: $VPA_FILE"
    done
    
    log_info "VPA manifests ready di ${VPA_DIR}/"
    log_info "Apply dengan: kubectl apply -f ${VPA_DIR}/"
    log_warn "NOTE: VPA akan restart pods. Review manifests sebelum apply!"
fi

log_info "Analysis complete!"
