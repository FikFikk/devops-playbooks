# Terraform Configuration untuk Cost Optimization
# AWS Provider dengan default tags

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  
  # Default tags untuk semua resources
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Environment = var.environment
      Project     = var.project_name
      Owner       = var.team_name
      CostCenter  = var.cost_center
    }
  }
}

# Variables
variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  validation {
    condition     = contains(["production", "staging", "development", "testing"], var.environment)
    error_message = "Environment must be production, staging, development, or testing."
  }
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "team_name" {
  description = "Team or owner name"
  type        = string
}

variable "cost_center" {
  description = "Cost center or budget code"
  type        = string
}

variable "enable_auto_shutdown" {
  description = "Enable auto-shutdown for non-production resources"
  type        = bool
  default     = true
}

# Budget Alert
resource "aws_budgets_budget" "monthly_cost" {
  name              = "${var.project_name}-${var.environment}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_limit
  limit_unit        = "USD"
  time_period_start = "2026-01-01_00:00"
  time_unit         = "MONTHLY"

  # Alert at 50%, 80%, 100%
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Forecasted alert
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${var.environment}"]
  }
}

variable "monthly_budget_limit" {
  description = "Monthly budget limit in USD"
  type        = number
}

variable "budget_alert_emails" {
  description = "Email addresses for budget alerts"
  type        = list(string)
}

# Cost Anomaly Detection
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name              = "${var.project_name}-${var.environment}-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "anomaly_alerts" {
  name      = "${var.project_name}-${var.environment}-anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service_monitor.arn,
  ]

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_emails[0]
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["100"]  # Alert if anomaly impact > $100
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}

# Lambda Function untuk Auto-Tagging (Optional)
resource "aws_iam_role" "auto_tagger" {
  count = var.enable_auto_tagging ? 1 : 0
  name  = "${var.project_name}-auto-tagger-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "auto_tagger_policy" {
  count = var.enable_auto_tagging ? 1 : 0
  role  = aws_iam_role.auto_tagger[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

variable "enable_auto_tagging" {
  description = "Enable auto-tagging Lambda function"
  type        = bool
  default     = false
}

# S3 Lifecycle Policy Example
resource "aws_s3_bucket_lifecycle_configuration" "cost_optimization" {
  count  = var.create_s3_example ? 1 : 0
  bucket = aws_s3_bucket.example[0].id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "delete-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket" "example" {
  count  = var.create_s3_example ? 1 : 0
  bucket = "${var.project_name}-${var.environment}-data"
}

variable "create_s3_example" {
  description = "Create S3 bucket with lifecycle policy example"
  type        = bool
  default     = false
}

# Outputs
output "budget_name" {
  description = "Name of the budget"
  value       = aws_budgets_budget.monthly_cost.name
}

output "anomaly_monitor_arn" {
  description = "ARN of cost anomaly monitor"
  value       = aws_ce_anomaly_monitor.service_monitor.arn
}
