#!/bin/bash
# EC2 Instance Scheduler
# Auto start/stop EC2 instances berdasarkan schedule untuk save costs

set -e

# Configuration
REGION=${AWS_REGION:-ap-southeast-1}
SCHEDULER_TAG_KEY="AutoSchedule"
TIMEZONE="Asia/Jakarta"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function: Get current day and hour
get_current_time() {
    export TZ=$TIMEZONE
    CURRENT_DAY=$(date +%u)  # 1=Monday, 7=Sunday
    CURRENT_HOUR=$(date +%H)
    
    echo "Current time: $(date)"
    echo "Day of week: $CURRENT_DAY (1=Mon, 7=Sun)"
    echo "Hour: $CURRENT_HOUR"
}

# Function: Check if instance should be running
should_be_running() {
    local schedule=$1
    local current_day=$2
    local current_hour=$3
    
    case $schedule in
        "working-hours")
            # Mon-Fri, 08:00-18:00
            if [ $current_day -ge 1 ] && [ $current_day -le 5 ]; then
                if [ $current_hour -ge 8 ] && [ $current_hour -lt 18 ]; then
                    return 0
                fi
            fi
            return 1
            ;;
        "business-hours")
            # Mon-Sat, 07:00-21:00
            if [ $current_day -ge 1 ] && [ $current_day -le 6 ]; then
                if [ $current_hour -ge 7 ] && [ $current_hour -lt 21 ]; then
                    return 0
                fi
            fi
            return 1
            ;;
        "weekday-only")
            # Mon-Fri, 24/7
            if [ $current_day -ge 1 ] && [ $current_day -le 5 ]; then
                return 0
            fi
            return 1
            ;;
        "always")
            # 24/7
            return 0
            ;;
        "never")
            # Always stopped (for cost testing)
            return 1
            ;;
        *)
            log_warn "Unknown schedule: $schedule"
            return 0  # Default: keep running
            ;;
    esac
}

# Function: Process instances
process_instances() {
    log_info "Fetching instances with $SCHEDULER_TAG_KEY tag..."
    
    # Get all instances with AutoSchedule tag
    INSTANCES=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag-key,Values=$SCHEDULER_TAG_KEY" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`'$SCHEDULER_TAG_KEY'`].Value|[0],Tags[?Key==`Name`].Value|[0]]' \
        --output text)
    
    if [ -z "$INSTANCES" ]; then
        log_warn "No instances found with $SCHEDULER_TAG_KEY tag"
        return
    fi
    
    get_current_time
    echo ""
    
    STARTED=0
    STOPPED=0
    SKIPPED=0
    
    while IFS=$'\t' read -r instance_id state schedule name; do
        log_info "Processing: $name ($instance_id) - Schedule: $schedule, State: $state"
        
        if should_be_running "$schedule" "$CURRENT_DAY" "$CURRENT_HOUR"; then
            # Should be running
            if [ "$state" = "stopped" ]; then
                log_info "  → Starting instance..."
                aws ec2 start-instances --region $REGION --instance-ids $instance_id > /dev/null
                ((STARTED++))
            else
                log_info "  → Already running, skipping"
                ((SKIPPED++))
            fi
        else
            # Should be stopped
            if [ "$state" = "running" ]; then
                log_info "  → Stopping instance..."
                aws ec2 stop-instances --region $REGION --instance-ids $instance_id > /dev/null
                ((STOPPED++))
            else
                log_info "  → Already stopped, skipping"
                ((SKIPPED++))
            fi
        fi
    done <<< "$INSTANCES"
    
    echo ""
    log_info "Summary:"
    echo "  Started: $STARTED"
    echo "  Stopped: $STOPPED"
    echo "  Skipped: $SKIPPED"
}

# Function: List scheduled instances
list_scheduled_instances() {
    log_info "Instances with scheduling enabled:"
    echo ""
    
    aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag-key,Values=$SCHEDULER_TAG_KEY" \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],InstanceId,InstanceType,State.Name,Tags[?Key==`'$SCHEDULER_TAG_KEY'`].Value|[0]]' \
        --output table
}

# Function: Add schedule to instance
add_schedule() {
    local instance_id=$1
    local schedule=$2
    
    if [ -z "$instance_id" ] || [ -z "$schedule" ]; then
        log_error "Usage: $0 add <instance-id> <schedule>"
        echo "Available schedules:"
        echo "  - working-hours  : Mon-Fri 08:00-18:00"
        echo "  - business-hours : Mon-Sat 07:00-21:00"
        echo "  - weekday-only   : Mon-Fri 24/7"
        echo "  - always         : 24/7"
        echo "  - never          : Always stopped"
        exit 1
    fi
    
    log_info "Adding schedule '$schedule' to instance $instance_id..."
    aws ec2 create-tags \
        --region $REGION \
        --resources $instance_id \
        --tags Key=$SCHEDULER_TAG_KEY,Value=$schedule
    
    log_info "✓ Schedule added successfully"
}

# Function: Remove schedule
remove_schedule() {
    local instance_id=$1
    
    if [ -z "$instance_id" ]; then
        log_error "Usage: $0 remove <instance-id>"
        exit 1
    fi
    
    log_info "Removing schedule from instance $instance_id..."
    aws ec2 delete-tags \
        --region $REGION \
        --resources $instance_id \
        --tags Key=$SCHEDULER_TAG_KEY
    
    log_info "✓ Schedule removed successfully"
}

# Main
case "${1:-run}" in
    run)
        process_instances
        ;;
    list)
        list_scheduled_instances
        ;;
    add)
        add_schedule "$2" "$3"
        ;;
    remove)
        remove_schedule "$2"
        ;;
    *)
        echo "Usage: $0 {run|list|add|remove}"
        echo ""
        echo "Commands:"
        echo "  run                          - Execute scheduling (start/stop instances)"
        echo "  list                         - List instances with schedules"
        echo "  add <instance-id> <schedule> - Add schedule to instance"
        echo "  remove <instance-id>         - Remove schedule from instance"
        echo ""
        echo "Example:"
        echo "  $0 add i-1234567890abcdef0 working-hours"
        echo "  $0 run"
        exit 1
        ;;
esac
