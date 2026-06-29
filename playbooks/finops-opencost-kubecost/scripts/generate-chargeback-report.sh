#!/bin/bash
#
# Generate Chargeback Report
# Script untuk generate monthly cost report per team/namespace
#

set -euo pipefail

# Configuration
OPENCOST_URL="${OPENCOST_URL:-http://opencost.opencost-system.svc.cluster.local:9003}"
OUTPUT_DIR="${OUTPUT_DIR:-./reports}"
CURRENCY="${CURRENCY:-USD}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Generate chargeback report dari OpenCost data.

OPTIONS:
    --month YYYY-MM          Month untuk report (default: current month)
    --team TEAM_NAME         Filter by team (optional)
    --namespace NS           Filter by namespace (optional)
    --format FORMAT          Output format: csv|json|pdf|html (default: csv)
    --cost-center CC         Filter by cost center (optional)
    --output-file FILE       Output filename (default: auto-generated)
    --email RECIPIENTS       Email report (comma-separated)
    --help                   Show this help

EXAMPLES:
    # Generate report untuk bulan ini
    $0 --month 2026-06 --format csv

    # Report untuk specific team
    $0 --month 2026-06 --team platform --format pdf

    # Send via email
    $0 --month 2026-06 --team platform --email finance@company.com,team-lead@company.com

EOF
    exit 0
}

# Parse arguments
MONTH=$(date +%Y-%m)
TEAM=""
NAMESPACE=""
FORMAT="csv"
COST_CENTER=""
OUTPUT_FILE=""
EMAIL_RECIPIENTS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --month)
            MONTH="$2"
            shift 2
            ;;
        --team)
            TEAM="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --cost-center)
            COST_CENTER="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --email)
            EMAIL_RECIPIENTS="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate month format
if ! [[ $MONTH =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    log_error "Invalid month format. Use YYYY-MM"
    exit 1
fi

# Calculate date range
START_DATE="${MONTH}-01T00:00:00Z"
END_DATE=$(date -d "${MONTH}-01 +1 month" +%Y-%m-01T00:00:00Z)

log_info "Generating chargeback report untuk ${MONTH}"
log_info "Date range: ${START_DATE} to ${END_DATE}"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Build query parameters
PARAMS="window=${START_DATE},${END_DATE}&aggregate=namespace"

if [[ -n "${NAMESPACE}" ]]; then
    PARAMS="${PARAMS}&filterNamespaces=${NAMESPACE}"
fi

# Query OpenCost API
log_info "Fetching data dari OpenCost..."
RESPONSE=$(curl -s "${OPENCOST_URL}/allocation/compute?${PARAMS}")

if [[ $? -ne 0 ]]; then
    log_error "Failed to fetch data dari OpenCost"
    exit 1
fi

# Parse and process data
log_info "Processing cost data..."

# Generate output filename jika tidak specified
if [[ -z "${OUTPUT_FILE}" ]]; then
    FILENAME="chargeback-${MONTH}"
    [[ -n "${TEAM}" ]] && FILENAME="${FILENAME}-${TEAM}"
    [[ -n "${NAMESPACE}" ]] && FILENAME="${FILENAME}-${NAMESPACE}"
    OUTPUT_FILE="${OUTPUT_DIR}/${FILENAME}.${FORMAT}"
fi

# Generate report berdasarkan format
case "${FORMAT}" in
    csv)
        log_info "Generating CSV report..."
        echo "${RESPONSE}" | jq -r '
            ["Namespace", "Team", "Cost Center", "CPU Cost", "Memory Cost", "Storage Cost", "Network Cost", "Total Cost"],
            (.data[] | 
                [
                    .name,
                    .properties.labels.team // "unknown",
                    .properties.labels["cost-center"] // "unknown",
                    .cpuCost,
                    .ramCost,
                    .pvCost,
                    .networkCost,
                    (.cpuCost + .ramCost + .pvCost + .networkCost)
                ]
            ) | @csv
        ' > "${OUTPUT_FILE}"
        ;;
    
    json)
        log_info "Generating JSON report..."
        echo "${RESPONSE}" | jq '{
            report_period: "'"${MONTH}"'",
            currency: "'"${CURRENCY}"'",
            generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            summary: {
                total_cost: ([.data[].cpuCost, .data[].ramCost, .data[].pvCost, .data[].networkCost] | add),
                namespace_count: (.data | length)
            },
            breakdown: [
                .data[] | {
                    namespace: .name,
                    team: .properties.labels.team // "unknown",
                    cost_center: .properties.labels["cost-center"] // "unknown",
                    costs: {
                        cpu: .cpuCost,
                        memory: .ramCost,
                        storage: .pvCost,
                        network: .networkCost,
                        total: (.cpuCost + .ramCost + .pvCost + .networkCost)
                    },
                    efficiency: {
                        cpu_usage_pct: (.cpuCostUsage / .cpuCost * 100),
                        memory_usage_pct: (.ramCostUsage / .ramCost * 100)
                    }
                }
            ]
        }' > "${OUTPUT_FILE}"
        ;;
    
    html)
        log_info "Generating HTML report..."
        cat > "${OUTPUT_FILE}" <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Chargeback Report - MONTH_PLACEHOLDER</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        .summary { background-color: #e8f5e9; padding: 15px; margin: 20px 0; border-radius: 5px; }
        .total { font-weight: bold; background-color: #c8e6c9; }
    </style>
</head>
<body>
    <h1>Chargeback Report - MONTH_PLACEHOLDER</h1>
    <div class="summary">
        <h2>Summary</h2>
        <p><strong>Total Cost:</strong> $TOTAL_COST_PLACEHOLDER</p>
        <p><strong>Report Period:</strong> MONTH_PLACEHOLDER</p>
        <p><strong>Generated:</strong> GENERATED_AT_PLACEHOLDER</p>
    </div>
    
    <h2>Cost Breakdown by Namespace</h2>
    <table>
        <thead>
            <tr>
                <th>Namespace</th>
                <th>Team</th>
                <th>Cost Center</th>
                <th>CPU Cost</th>
                <th>Memory Cost</th>
                <th>Storage Cost</th>
                <th>Network Cost</th>
                <th>Total Cost</th>
            </tr>
        </thead>
        <tbody>
            TABLE_ROWS_PLACEHOLDER
        </tbody>
    </table>
</body>
</html>
HTML
        
        # Replace placeholders
        TOTAL_COST=$(echo "${RESPONSE}" | jq '[.data[] | (.cpuCost + .ramCost + .pvCost + .networkCost)] | add')
        TABLE_ROWS=$(echo "${RESPONSE}" | jq -r '.data[] | 
            "<tr><td>\(.name)</td><td>\(.properties.labels.team // "unknown")</td><td>\(.properties.labels["cost-center"] // "unknown")</td><td>$\(.cpuCost | tonumber | . * 100 | round / 100)</td><td>$\(.ramCost | tonumber | . * 100 | round / 100)</td><td>$\(.pvCost | tonumber | . * 100 | round / 100)</td><td>$\(.networkCost | tonumber | . * 100 | round / 100)</td><td>$\((.cpuCost + .ramCost + .pvCost + .networkCost) | tonumber | . * 100 | round / 100)</td></tr>"
        ')
        
        sed -i "s/MONTH_PLACEHOLDER/${MONTH}/g" "${OUTPUT_FILE}"
        sed -i "s/TOTAL_COST_PLACEHOLDER/${TOTAL_COST}/g" "${OUTPUT_FILE}"
        sed -i "s/GENERATED_AT_PLACEHOLDER/$(date -u +%Y-%m-%dT%H:%M:%SZ)/g" "${OUTPUT_FILE}"
        sed -i "s|TABLE_ROWS_PLACEHOLDER|${TABLE_ROWS}|g" "${OUTPUT_FILE}"
        ;;
    
    pdf)
        log_info "Generating PDF report..."
        # Generate HTML first, then convert to PDF
        HTML_FILE="${OUTPUT_FILE%.pdf}.html"
        bash "$0" --month "${MONTH}" --team "${TEAM}" --namespace "${NAMESPACE}" --format html --output-file "${HTML_FILE}"
        
        # Convert using wkhtmltopdf (must be installed)
        if command -v wkhtmltopdf &> /dev/null; then
            wkhtmltopdf "${HTML_FILE}" "${OUTPUT_FILE}"
            rm "${HTML_FILE}"
        else
            log_error "wkhtmltopdf not installed. Cannot generate PDF."
            log_info "HTML report available at: ${HTML_FILE}"
            exit 1
        fi
        ;;
    
    *)
        log_error "Unsupported format: ${FORMAT}"
        exit 1
        ;;
esac

log_info "Report generated: ${OUTPUT_FILE}"

# Email report jika requested
if [[ -n "${EMAIL_RECIPIENTS}" ]]; then
    log_info "Sending report via email to: ${EMAIL_RECIPIENTS}"
    
    SUBJECT="Chargeback Report - ${MONTH}"
    [[ -n "${TEAM}" ]] && SUBJECT="${SUBJECT} - Team ${TEAM}"
    
    if command -v mail &> /dev/null; then
        echo "Attached is the chargeback report untuk ${MONTH}." | \
            mail -s "${SUBJECT}" -A "${OUTPUT_FILE}" "${EMAIL_RECIPIENTS}"
        log_info "Email sent successfully"
    else
        log_warn "mail command not available. Skipping email."
        log_info "Manual send: attach ${OUTPUT_FILE}"
    fi
fi

# Print summary
log_info "Report Summary:"
TOTAL=$(echo "${RESPONSE}" | jq '[.data[] | (.cpuCost + .ramCost + .pvCost + .networkCost)] | add')
NAMESPACE_COUNT=$(echo "${RESPONSE}" | jq '.data | length')

echo ""
echo "  Period:     ${MONTH}"
echo "  Total Cost: \$${TOTAL}"
echo "  Namespaces: ${NAMESPACE_COUNT}"
echo "  Output:     ${OUTPUT_FILE}"
echo ""

log_info "Done!"
