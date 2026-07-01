# drift-detector-iam.tf
# IAM role untuk drift detection dengan read-only permissions

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "github_org" {
  description = "GitHub organization untuk OIDC"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository untuk OIDC"
  type        = string
}

variable "allowed_branches" {
  description = "Branch yang boleh assume role ini"
  type        = list(string)
  default     = ["main", "master"]
}

# OIDC provider untuk GitHub Actions
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# IAM policy untuk drift detection (read-only)
data "aws_iam_policy_document" "drift_detector_policy" {
  # EC2 read permissions
  statement {
    sid = "EC2ReadOnly"
    actions = [
      "ec2:Describe*",
      "ec2:GetConsole*",
      "ec2:ListSnapshotsInRecycleBin",
      "elasticloadbalancing:Describe*",
      "autoscaling:Describe*",
    ]
    resources = ["*"]
  }

  # VPC & Networking read
  statement {
    sid = "NetworkReadOnly"
    actions = [
      "vpc:Describe*",
      "vpc:Get*",
      "vpc:List*",
    ]
    resources = ["*"]
  }

  # S3 read permissions
  statement {
    sid = "S3ReadOnly"
    actions = [
      "s3:GetBucket*",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:ListBucket*",
      "s3:ListAllMyBuckets",
    ]
    resources = ["*"]
  }

  # RDS read permissions
  statement {
    sid = "RDSReadOnly"
    actions = [
      "rds:Describe*",
      "rds:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # IAM read permissions
  statement {
    sid = "IAMReadOnly"
    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:GenerateCredentialReport",
      "iam:GenerateServiceLastAccessedDetails",
    ]
    resources = ["*"]
  }

  # Lambda read permissions
  statement {
    sid = "LambdaReadOnly"
    actions = [
      "lambda:Get*",
      "lambda:List*",
    ]
    resources = ["*"]
  }

  # CloudWatch & Logging read
  statement {
    sid = "CloudWatchReadOnly"
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "logs:Describe*",
      "logs:Get*",
      "logs:FilterLogEvents",
      "logs:ListTagsLogGroup",
    ]
    resources = ["*"]
  }

  # EKS read permissions
  statement {
    sid = "EKSReadOnly"
    actions = [
      "eks:Describe*",
      "eks:List*",
    ]
    resources = ["*"]
  }

  # Route53 read
  statement {
    sid = "Route53ReadOnly"
    actions = [
      "route53:Get*",
      "route53:List*",
    ]
    resources = ["*"]
  }

  # ACM read
  statement {
    sid = "ACMReadOnly"
    actions = [
      "acm:Describe*",
      "acm:Get*",
      "acm:List*",
    ]
    resources = ["*"]
  }

  # KMS read
  statement {
    sid = "KMSReadOnly"
    actions = [
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
    ]
    resources = ["*"]
  }

  # Secrets Manager read
  statement {
    sid = "SecretsManagerReadOnly"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecrets",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = ["*"]
  }

  # Systems Manager read
  statement {
    sid = "SSMReadOnly"
    actions = [
      "ssm:Describe*",
      "ssm:Get*",
      "ssm:List*",
    ]
    resources = ["*"]
  }

  # DynamoDB read
  statement {
    sid = "DynamoDBReadOnly"
    actions = [
      "dynamodb:Describe*",
      "dynamodb:List*",
    ]
    resources = ["*"]
  }

  # SNS & SQS read
  statement {
    sid = "MessagingReadOnly"
    actions = [
      "sns:Get*",
      "sns:List*",
      "sqs:Get*",
      "sqs:List*",
    ]
    resources = ["*"]
  }

  # Terraform state access (baca S3 backend)
  statement {
    sid = "TerraformStateRead"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.terraform_state_bucket}",
      "arn:aws:s3:::${var.terraform_state_bucket}/*",
    ]
  }

  statement {
    sid = "TerraformStateLock"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [
      "arn:aws:dynamodb:*:*:table/${var.terraform_lock_table}",
    ]
  }
}

variable "terraform_state_bucket" {
  description = "S3 bucket untuk Terraform state"
  type        = string
}

variable "terraform_lock_table" {
  description = "DynamoDB table untuk state locking"
  type        = string
  default     = "terraform-state-lock"
}

# Create IAM policy
resource "aws_iam_policy" "drift_detector" {
  name        = "TerraformDriftDetectorPolicy"
  description = "Read-only access untuk Terraform drift detection"
  policy      = data.aws_iam_policy_document.drift_detector_policy.json

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "DriftDetection"
  }
}

# Trust policy untuk GitHub OIDC
data "aws_iam_policy_document" "github_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for branch in var.allowed_branches :
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${branch}"
      ]
    }
  }
}

# IAM role untuk drift detection
resource "aws_iam_role" "drift_detector" {
  name               = "GitHubActionsTerraformDriftDetector"
  description        = "Role untuk drift detection via GitHub Actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "DriftDetection"
  }
}

# Attach policy ke role
resource "aws_iam_role_policy_attachment" "drift_detector" {
  role       = aws_iam_role.drift_detector.name
  policy_arn = aws_iam_policy.drift_detector.arn
}

# Outputs
output "drift_detector_role_arn" {
  description = "ARN dari IAM role untuk drift detection"
  value       = aws_iam_role.drift_detector.arn
}

output "drift_detector_policy_arn" {
  description = "ARN dari IAM policy untuk drift detection"
  value       = aws_iam_policy.drift_detector.arn
}
