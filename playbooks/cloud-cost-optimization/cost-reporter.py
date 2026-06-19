#!/usr/bin/env python3
"""
AWS Cost Report Generator
Generates weekly cost report dan kirim via email
"""

import boto3
import json
from datetime import datetime, timedelta
from typing import Dict, List

class AWSCostReporter:
    def __init__(self, region='ap-southeast-1'):
        self.ce_client = boto3.client('ce', region_name='us-east-1')  # CE only in us-east-1
        self.ec2_client = boto3.client('ec2', region_name=region)
        
    def get_cost_by_service(self, days=7) -> List[Dict]:
        """Get cost breakdown by service"""
        end_date = datetime.now().date()
        start_date = end_date - timedelta(days=days)
        
        response = self.ce_client.get_cost_and_usage(
            TimePeriod={
                'Start': start_date.isoformat(),
                'End': end_date.isoformat()
            },
            Granularity='DAILY',
            Metrics=['BlendedCost'],
            GroupBy=[
                {
                    'Type': 'DIMENSION',
                    'Key': 'SERVICE'
                }
            ]
        )
        
        # Aggregate costs
        service_costs = {}
        for result in response['ResultsByTime']:
            for group in result['Groups']:
                service = group['Keys'][0]
                cost = float(group['Metrics']['BlendedCost']['Amount'])
                service_costs[service] = service_costs.get(service, 0) + cost
        
        # Sort by cost descending
        sorted_costs = sorted(
            [{'service': k, 'cost': v} for k, v in service_costs.items()],
            key=lambda x: x['cost'],
            reverse=True
        )
        
        return sorted_costs
    
    def get_cost_by_tag(self, tag_key='Owner', days=7) -> List[Dict]:
        """Get cost breakdown by tag"""
        end_date = datetime.now().date()
        start_date = end_date - timedelta(days=days)
        
        response = self.ce_client.get_cost_and_usage(
            TimePeriod={
                'Start': start_date.isoformat(),
                'End': end_date.isoformat()
            },
            Granularity='DAILY',
            Metrics=['BlendedCost'],
            GroupBy=[
                {
                    'Type': 'TAG',
                    'Key': tag_key
                }
            ]
        )
        
        # Aggregate costs
        tag_costs = {}
        for result in response['ResultsByTime']:
            for group in result['Groups']:
                tag_value = group['Keys'][0].split('$')[-1] if '$' in group['Keys'][0] else 'Untagged'
                cost = float(group['Metrics']['BlendedCost']['Amount'])
                tag_costs[tag_value] = tag_costs.get(tag_value, 0) + cost
        
        sorted_costs = sorted(
            [{'tag': k, 'cost': v} for k, v in tag_costs.items()],
            key=lambda x: x['cost'],
            reverse=True
        )
        
        return sorted_costs
    
    def get_waste_metrics(self) -> Dict:
        """Calculate waste metrics"""
        metrics = {
            'stopped_instances': 0,
            'unattached_volumes': 0,
            'unused_eips': 0,
            'old_snapshots': 0
        }
        
        # Stopped instances
        response = self.ec2_client.describe_instances(
            Filters=[{'Name': 'instance-state-name', 'Values': ['stopped']}]
        )
        metrics['stopped_instances'] = sum(
            len(r['Instances']) for r in response['Reservations']
        )
        
        # Unattached volumes
        response = self.ec2_client.describe_volumes(
            Filters=[{'Name': 'status', 'Values': ['available']}]
        )
        metrics['unattached_volumes'] = len(response['Volumes'])
        
        # Unused EIPs
        response = self.ec2_client.describe_addresses()
        metrics['unused_eips'] = sum(
            1 for addr in response['Addresses'] if 'AssociationId' not in addr
        )
        
        # Old snapshots (>90 days)
        cutoff_date = datetime.now() - timedelta(days=90)
        response = self.ec2_client.describe_snapshots(OwnerIds=['self'])
        metrics['old_snapshots'] = sum(
            1 for snap in response['Snapshots']
            if snap['StartTime'].replace(tzinfo=None) < cutoff_date
        )
        
        return metrics
    
    def estimate_waste_cost(self, metrics: Dict) -> float:
        """Estimate monthly waste cost"""
        # Rough estimates
        stopped_cost = metrics['stopped_instances'] * 30  # ~$30/instance storage
        volume_cost = metrics['unattached_volumes'] * 10  # ~$10/volume average
        eip_cost = metrics['unused_eips'] * 3.6  # $0.005/hour
        snapshot_cost = metrics['old_snapshots'] * 2  # ~$2/snapshot average
        
        return stopped_cost + volume_cost + eip_cost + snapshot_cost
    
    def generate_report(self) -> str:
        """Generate cost report"""
        print("🔍 Generating AWS Cost Report...")
        
        # Get data
        service_costs = self.get_cost_by_service(days=7)
        team_costs = self.get_cost_by_tag('Owner', days=7)
        waste_metrics = self.get_waste_metrics()
        estimated_waste = self.estimate_waste_cost(waste_metrics)
        
        # Calculate totals
        total_cost = sum(s['cost'] for s in service_costs)
        
        # Build report
        report = []
        report.append("=" * 60)
        report.append("AWS COST OPTIMIZATION REPORT")
        report.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report.append("=" * 60)
        report.append("")
        
        report.append(f"📊 TOTAL COST (Last 7 Days): ${total_cost:.2f}")
        report.append(f"📉 Estimated Monthly Waste: ${estimated_waste:.2f}")
        report.append(f"💡 Potential Savings: {(estimated_waste/total_cost*100):.1f}%")
        report.append("")
        
        report.append("💰 TOP 10 SERVICES BY COST")
        report.append("-" * 60)
        for i, item in enumerate(service_costs[:10], 1):
            percentage = (item['cost'] / total_cost * 100) if total_cost > 0 else 0
            report.append(f"{i:2d}. {item['service']:30s} ${item['cost']:8.2f} ({percentage:5.1f}%)")
        report.append("")
        
        report.append("👥 COST BY TEAM/OWNER")
        report.append("-" * 60)
        for i, item in enumerate(team_costs[:10], 1):
            percentage = (item['cost'] / total_cost * 100) if total_cost > 0 else 0
            report.append(f"{i:2d}. {item['tag']:30s} ${item['cost']:8.2f} ({percentage:5.1f}%)")
        report.append("")
        
        report.append("🧟 WASTE METRICS")
        report.append("-" * 60)
        report.append(f"Stopped Instances:    {waste_metrics['stopped_instances']:4d}")
        report.append(f"Unattached Volumes:   {waste_metrics['unattached_volumes']:4d}")
        report.append(f"Unused Elastic IPs:   {waste_metrics['unused_eips']:4d}")
        report.append(f"Old Snapshots (>90d): {waste_metrics['old_snapshots']:4d}")
        report.append("")
        
        report.append("📋 RECOMMENDED ACTIONS")
        report.append("-" * 60)
        if waste_metrics['stopped_instances'] > 0:
            report.append(f"• Terminate {waste_metrics['stopped_instances']} stopped instances")
        if waste_metrics['unattached_volumes'] > 0:
            report.append(f"• Delete {waste_metrics['unattached_volumes']} unattached volumes")
        if waste_metrics['unused_eips'] > 0:
            report.append(f"• Release {waste_metrics['unused_eips']} unused Elastic IPs")
        if waste_metrics['old_snapshots'] > 0:
            report.append(f"• Clean up {waste_metrics['old_snapshots']} old snapshots")
        report.append("")
        
        report.append("=" * 60)
        report.append("Next Report: " + (datetime.now() + timedelta(days=7)).strftime('%Y-%m-%d'))
        report.append("=" * 60)
        
        return "\n".join(report)
    
    def save_report(self, report: str, filename='cost-report.txt'):
        """Save report to file"""
        with open(filename, 'w') as f:
            f.write(report)
        print(f"✅ Report saved to {filename}")
    
    def send_email(self, report: str, recipients: List[str]):
        """Send report via SES (requires SES configuration)"""
        ses_client = boto3.client('ses', region_name='ap-southeast-1')
        
        try:
            response = ses_client.send_email(
                Source='devops@example.com',
                Destination={'ToAddresses': recipients},
                Message={
                    'Subject': {
                        'Data': f'AWS Cost Report - {datetime.now().strftime("%Y-%m-%d")}',
                        'Charset': 'UTF-8'
                    },
                    'Body': {
                        'Text': {
                            'Data': report,
                            'Charset': 'UTF-8'
                        }
                    }
                }
            )
            print(f"✅ Email sent to {', '.join(recipients)}")
            return response
        except Exception as e:
            print(f"❌ Failed to send email: {e}")
            return None

def main():
    """Main function"""
    import argparse
    
    parser = argparse.ArgumentParser(description='AWS Cost Report Generator')
    parser.add_argument('--region', default='ap-southeast-1', help='AWS Region')
    parser.add_argument('--output', default='cost-report.txt', help='Output filename')
    parser.add_argument('--email', nargs='+', help='Email recipients')
    args = parser.parse_args()
    
    try:
        reporter = AWSCostReporter(region=args.region)
        report = reporter.generate_report()
        
        # Print to console
        print(report)
        
        # Save to file
        reporter.save_report(report, args.output)
        
        # Send email if specified
        if args.email:
            reporter.send_email(report, args.email)
            
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
