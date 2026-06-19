#!/bin/bash
# AWS Cost Analyzer Script
# Menganalisis AWS costs dan memberikan recommendations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 AWS Cost Analyzer"
echo "===================="
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI tidak terinstall${NC}"
    exit 1
fi

# Check credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials tidak valid${NC}"
    exit 1
fi

REGION=${AWS_REGION:-ap-southeast-1}
echo -e "${GREEN}✓ AWS CLI configured${NC}"
echo -e "Region: $REGION"
echo -e "Account: $(aws sts get-caller-identity --query Account --output text)"
echo ""

# Function: Find zombie resources
find_zombies() {
    echo "🧟 Mencari Zombie Resources..."
    echo ""
    
    # Stopped instances > 7 days
    echo "▶ Stopped EC2 Instances (>7 days):"
    aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=instance-state-name,Values=stopped" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
        --output table
    
    # Unattached volumes
    echo ""
    echo "▶ Unattached EBS Volumes:"
    aws ec2 describe-volumes \
        --region $REGION \
        --filters "Name=status,Values=available" \
        --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' \
        --output table
    
    # Unused Elastic IPs
    echo ""
    echo "▶ Unused Elastic IPs:"
    aws ec2 describe-addresses \
        --region $REGION \
        --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
        --output table
    
    # Old snapshots
    echo ""
    echo "▶ Old Snapshots (>90 days):"
    CUTOFF_DATE=$(date -d '90 days ago' +%Y-%m-%d)
    aws ec2 describe-snapshots \
        --region $REGION \
        --owner-ids self \
        --query "Snapshots[?StartTime<'$CUTOFF_DATE'].[SnapshotId,VolumeSize,StartTime,Description]" \
        --output table | head -20
}

# Function: Cost breakdown
cost_breakdown() {
    echo ""
    echo "💰 Cost Breakdown (Last 7 Days)"
    echo "================================"
    
    START_DATE=$(date -d '7 days ago' +%Y-%m-%d)
    END_DATE=$(date +%Y-%m-%d)
    
    aws ce get-cost-and-usage \
        --time-period Start=$START_DATE,End=$END_DATE \
        --granularity DAILY \
        --metrics BlendedCost \
        --group-by Type=SERVICE \
        --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.BlendedCost.Amount]' \
        --output table | sort -k2 -rn | head -15
}

# Function: Tagging compliance
check_tagging() {
    echo ""
    echo "🏷️  Tagging Compliance Check"
    echo "============================"
    
    REQUIRED_TAGS=("Environment" "Owner" "Project")
    
    echo "▶ EC2 Instances without required tags:"
    TOTAL_INSTANCES=$(aws ec2 describe-instances --region $REGION --query 'Reservations[].Instances[?State.Name==`running`]' --output json | jq length)
    echo "Total running instances: $TOTAL_INSTANCES"
    
    for tag in "${REQUIRED_TAGS[@]}"; do
        MISSING=$(aws ec2 describe-instances \
            --region $REGION \
            --filters "Name=instance-state-name,Values=running" \
            --query "Reservations[].Instances[?!Tags || !Tags[?Key=='$tag']].[InstanceId,Tags[?Key=='Name'].Value|[0]]" \
            --output text | wc -l)
        
        if [ $MISSING -gt 0 ]; then
            echo -e "${YELLOW}⚠ Missing tag '$tag': $MISSING instances${NC}"
        else
            echo -e "${GREEN}✓ All instances have '$tag' tag${NC}"
        fi
    done
}

# Function: Right-sizing recommendations
rightsizing_recommendations() {
    echo ""
    echo "📊 Right-Sizing Recommendations"
    echo "==============================="
    
    echo "Fetching EC2 utilization data..."
    echo "(Note: Requires CloudWatch metrics, mungkin perlu waktu)"
    
    # Get running instances
    aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
        --output table
    
    echo ""
    echo "💡 Recommendations:"
    echo "1. Review instances dengan CPU < 20% average"
    echo "2. Consider t3/t4g burst instances untuk low utilization"
    echo "3. Use AWS Compute Optimizer untuk detailed recommendations"
    echo "   aws compute-optimizer get-ec2-instance-recommendations"
}

# Function: Quick wins calculation
calculate_savings() {
    echo ""
    echo "💵 Estimated Monthly Savings (Quick Wins)"
    echo "=========================================="
    
    # Count zombies
    STOPPED_INSTANCES=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=stopped" --query 'Reservations[].Instances' --output json | jq length)
    UNATTACHED_VOLUMES=$(aws ec2 describe-volumes --region $REGION --filters "Name=status,Values=available" --query 'Volumes' --output json | jq length)
    UNUSED_EIPS=$(aws ec2 describe-addresses --region $REGION --query 'Addresses[?AssociationId==null]' --output json | jq length)
    
    VOLUME_SIZE=$(aws ec2 describe-volumes --region $REGION --filters "Name=status,Values=available" --query 'sum(Volumes[].Size)' --output text)
    
    # Estimasi savings (rough)
    STOPPED_SAVINGS=$(echo "$STOPPED_INSTANCES * 30" | bc) # ~$30/instance/month for t3.medium
    VOLUME_SAVINGS=$(echo "$VOLUME_SIZE * 0.10" | bc) # $0.10/GB/month for gp3
    EIP_SAVINGS=$(echo "$UNUSED_EIPS * 3.6" | bc) # $0.005/hour
    
    TOTAL_SAVINGS=$(echo "$STOPPED_SAVINGS + $VOLUME_SAVINGS + $EIP_SAVINGS" | bc)
    
    echo "Stopped Instances: $STOPPED_INSTANCES → ~\$$STOPPED_SAVINGS/month"
    echo "Unattached Volumes: ${VOLUME_SIZE}GB → ~\$$VOLUME_SAVINGS/month"
    echo "Unused EIPs: $UNUSED_EIPS → ~\$$EIP_SAVINGS/month"
    echo ""
    echo -e "${GREEN}Total Estimated Savings: ~\$$TOTAL_SAVINGS/month${NC}"
    echo ""
    echo "⚠️  Catatan: Ini estimasi kasar. Actual savings tergantung instance types dan region."
}

# Function: Cleanup recommendations
cleanup_recommendations() {
    echo ""
    echo "🧹 Cleanup Recommendations"
    echo "=========================="
    echo ""
    echo "1. Terminate stopped instances (after verification):"
    echo "   aws ec2 terminate-instances --instance-ids <instance-id>"
    echo ""
    echo "2. Delete unattached volumes:"
    echo "   aws ec2 delete-volume --volume-id <volume-id>"
    echo ""
    echo "3. Release unused Elastic IPs:"
    echo "   aws ec2 release-address --allocation-id <alloc-id>"
    echo ""
    echo "4. Delete old snapshots:"
    echo "   aws ec2 delete-snapshot --snapshot-id <snapshot-id>"
    echo ""
    echo "⚠️  CAUTION: Always verify before deleting!"
}

# Main execution
main() {
    find_zombies
    cost_breakdown
    check_tagging
    rightsizing_recommendations
    calculate_savings
    cleanup_recommendations
    
    echo ""
    echo "✅ Analysis complete!"
    echo ""
    echo "Next Steps:"
    echo "1. Review findings dengan team"
    echo "2. Backup/snapshot resources sebelum delete"
    echo "3. Execute cleanup gradually (jangan sekaligus)"
    echo "4. Monitor costs setelah optimization"
}

# Run
main
