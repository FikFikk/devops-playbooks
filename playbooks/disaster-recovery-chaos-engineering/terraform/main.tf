###############################################################################
# Disaster Recovery — Multi-Region Infrastructure
# Provider: AWS (adaptable untuk GCP/Azure)
# File: terraform/main.tf
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    bucket         = "terraform-state-dr-infra"
    key            = "dr-infrastructure/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "project_name" {
  description = "Nama project"
  type        = string
  default     = "myapp"
}

variable "environment" {
  description = "Environment (production/staging)"
  type        = string
  default     = "production"
}

variable "primary_region" {
  description = "Region utama"
  type        = string
  default     = "ap-southeast-1"
}

variable "dr_region" {
  description = "Region DR"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr_primary" {
  description = "CIDR block untuk VPC primary"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_cidr_dr" {
  description = "CIDR block untuk VPC DR"
  type        = string
  default     = "10.1.0.0/16"
}

variable "db_instance_class" {
  description = "Instance class untuk RDS"
  type        = string
  default     = "db.r6g.large"
}

variable "eks_node_instance_type" {
  description = "Instance type untuk EKS nodes"
  type        = string
  default     = "m6i.xlarge"
}

variable "domain_name" {
  description = "Domain name untuk aplikasi"
  type        = string
  default     = "app.example.com"
}

variable "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID"
  type        = string
}

# =============================================================================
# Providers — Multi-Region
# =============================================================================

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Purpose     = "primary"
    }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Purpose     = "disaster-recovery"
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_availability_zones" "primary" {
  state = "available"
}

data "aws_availability_zones" "dr" {
  provider = aws.dr
  state    = "available"
}

data "aws_caller_identity" "current" {}

# =============================================================================
# VPC — Primary Region
# =============================================================================

module "vpc_primary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.project_name}-primary-vpc"
  cidr = var.vpc_cidr_primary

  azs             = slice(data.aws_availability_zones.primary.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr_primary, 8, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr_primary, 8, i + 100)]

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tag untuk EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Region = var.primary_region
    Role   = "primary"
  }
}

# =============================================================================
# VPC — DR Region
# =============================================================================

module "vpc_dr" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  providers = {
    aws = aws.dr
  }

  name = "${var.project_name}-dr-vpc"
  cidr = var.vpc_cidr_dr

  azs             = slice(data.aws_availability_zones.dr.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr_dr, 8, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr_dr, 8, i + 100)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # Cost saving di DR (warm standby)
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Region = var.dr_region
    Role   = "disaster-recovery"
  }
}

# =============================================================================
# VPC Peering — Cross-Region
# =============================================================================

resource "aws_vpc_peering_connection" "primary_to_dr" {
  vpc_id      = module.vpc_primary.vpc_id
  peer_vpc_id = module.vpc_dr.vpc_id
  peer_region = var.dr_region

  tags = {
    Name = "${var.project_name}-primary-to-dr-peering"
  }
}

resource "aws_vpc_peering_connection_accepter" "dr_accept" {
  provider                  = aws.dr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_dr.id
  auto_accept               = true

  tags = {
    Name = "${var.project_name}-dr-accept-peering"
  }
}

# Route tables untuk peering
resource "aws_route" "primary_to_dr" {
  count                     = length(module.vpc_primary.private_route_table_ids)
  route_table_id            = module.vpc_primary.private_route_table_ids[count.index]
  destination_cidr_block    = var.vpc_cidr_dr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_dr.id
}

resource "aws_route" "dr_to_primary" {
  provider                  = aws.dr
  count                     = length(module.vpc_dr.private_route_table_ids)
  route_table_id            = module.vpc_dr.private_route_table_ids[count.index]
  destination_cidr_block    = var.vpc_cidr_primary
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_dr.id
}

# =============================================================================
# EKS — Primary Cluster
# =============================================================================

module "eks_primary" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${var.project_name}-primary"
  cluster_version = "1.29"

  vpc_id     = module.vpc_primary.vpc_id
  subnet_ids = module.vpc_primary.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  eks_managed_node_groups = {
    main = {
      instance_types = [var.eks_node_instance_type]
      min_size       = 3
      max_size       = 10
      desired_size   = 3

      labels = {
        role = "main"
      }
    }
  }

  # Addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_primary.iam_role_arn
    }
  }

  tags = {
    Region = var.primary_region
    Role   = "primary"
  }
}

# =============================================================================
# EKS — DR Cluster (Warm Standby)
# =============================================================================

module "eks_dr" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  providers = {
    aws = aws.dr
  }

  cluster_name    = "${var.project_name}-dr"
  cluster_version = "1.29"

  vpc_id     = module.vpc_dr.vpc_id
  subnet_ids = module.vpc_dr.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  eks_managed_node_groups = {
    main = {
      instance_types = [var.eks_node_instance_type]
      min_size       = 1   # Warm standby — minimal nodes
      max_size       = 10
      desired_size   = 2   # Cukup untuk menjalankan core services

      labels = {
        role = "dr-standby"
      }
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_dr.iam_role_arn
    }
  }

  tags = {
    Region = var.dr_region
    Role   = "disaster-recovery"
  }
}

# =============================================================================
# IRSA untuk EBS CSI Driver
# =============================================================================

module "ebs_csi_irsa_primary" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name             = "${var.project_name}-primary-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks_primary.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "ebs_csi_irsa_dr" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  providers = {
    aws = aws.dr
  }

  role_name             = "${var.project_name}-dr-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks_dr.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# =============================================================================
# RDS — Primary Database
# =============================================================================

resource "aws_db_subnet_group" "primary" {
  name       = "${var.project_name}-primary-db-subnet"
  subnet_ids = module.vpc_primary.private_subnets

  tags = {
    Name = "${var.project_name}-primary-db-subnet"
  }
}

resource "aws_security_group" "db_primary" {
  name_prefix = "${var.project_name}-primary-db-"
  vpc_id      = module.vpc_primary.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_primary, var.vpc_cidr_dr]
    description = "PostgreSQL dari VPC primary dan DR"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "primary" {
  cluster_identifier = "${var.project_name}-primary-db"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"
  engine_mode        = "provisioned"

  database_name   = var.project_name
  master_username = "dbadmin"
  master_password = "CHANGE_ME_USE_SECRETS_MANAGER" # Gunakan aws_secretsmanager_secret

  db_subnet_group_name   = aws_db_subnet_group.primary.name
  vpc_security_group_ids = [aws_security_group.db_primary.id]

  backup_retention_period      = 35  # Retensi backup 35 hari
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "mon:04:00-mon:05:00"

  storage_encrypted = true
  deletion_protection = true

  # Global Database untuk cross-region replication
  # (dikelola terpisah via aws_rds_global_cluster jika dibutuhkan)

  serverlessv2_scaling_configuration {
    min_capacity = 2
    max_capacity = 16
  }

  tags = {
    Name   = "${var.project_name}-primary-db"
    Region = var.primary_region
    Role   = "primary"
  }
}

resource "aws_rds_cluster_instance" "primary" {
  count              = 2
  identifier         = "${var.project_name}-primary-db-${count.index}"
  cluster_identifier = aws_rds_cluster.primary.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.primary.engine
  engine_version     = aws_rds_cluster.primary.engine_version
}

# =============================================================================
# S3 Bucket — Velero Backup dengan Cross-Region Replication
# =============================================================================

resource "aws_s3_bucket" "velero_primary" {
  bucket = "${var.project_name}-velero-backup-primary"

  tags = {
    Name   = "${var.project_name}-velero-backup-primary"
    Region = var.primary_region
  }
}

resource "aws_s3_bucket_versioning" "velero_primary" {
  bucket = aws_s3_bucket.velero_primary.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_primary" {
  bucket = aws_s3_bucket.velero_primary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Object Lock untuk immutable backups (ransomware protection)
resource "aws_s3_bucket_object_lock_configuration" "velero_primary" {
  bucket = aws_s3_bucket.velero_primary.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 30
    }
  }
}

resource "aws_s3_bucket" "velero_dr" {
  provider = aws.dr
  bucket   = "${var.project_name}-velero-backup-dr"

  tags = {
    Name   = "${var.project_name}-velero-backup-dr"
    Region = var.dr_region
  }
}

resource "aws_s3_bucket_versioning" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Cross-Region Replication
resource "aws_iam_role" "s3_replication" {
  name = "${var.project_name}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_replication" {
  name = "${var.project_name}-s3-replication-policy"
  role = aws_iam_role.s3_replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.velero_primary.arn]
      },
      {
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.velero_primary.arn}/*"]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.velero_dr.arn}/*"]
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "velero" {
  depends_on = [
    aws_s3_bucket_versioning.velero_primary,
    aws_s3_bucket_versioning.velero_dr
  ]

  bucket = aws_s3_bucket.velero_primary.id
  role   = aws_iam_role.s3_replication.arn

  rule {
    id     = "replicate-velero-backups"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.velero_dr.arn
      storage_class = "STANDARD_IA"
    }
  }
}

# =============================================================================
# Route 53 — Health Check & Failover Routing
# =============================================================================

resource "aws_route53_health_check" "primary" {
  fqdn              = "primary-alb.${var.domain_name}"
  port               = 443
  type               = "HTTPS"
  resource_path      = "/health"
  failure_threshold  = 3
  request_interval   = 10
  measure_latency    = true

  tags = {
    Name = "${var.project_name}-primary-health-check"
  }
}

resource "aws_route53_health_check" "dr" {
  fqdn              = "dr-alb.${var.domain_name}"
  port               = 443
  type               = "HTTPS"
  resource_path      = "/health"
  failure_threshold  = 3
  request_interval   = 10
  measure_latency    = true

  tags = {
    Name = "${var.project_name}-dr-health-check"
  }
}

resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    # Referensi ke ALB primary (definisikan ALB resource terpisah)
    name                   = "primary-alb.${var.domain_name}"
    zone_id                = var.hosted_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "dr" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier = "dr"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = "dr-alb.${var.domain_name}"
    zone_id                = var.hosted_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.dr.id
}

# =============================================================================
# CloudWatch Alarms — DR Monitoring
# =============================================================================

resource "aws_sns_topic" "dr_alerts" {
  name = "${var.project_name}-dr-alerts"
}

resource "aws_cloudwatch_metric_alarm" "primary_health" {
  alarm_name          = "${var.project_name}-primary-region-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Primary region health check failed — DR failover mungkin aktif"
  alarm_actions       = [aws_sns_topic.dr_alerts.arn]
  ok_actions          = [aws_sns_topic.dr_alerts.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "primary_vpc_id" {
  value = module.vpc_primary.vpc_id
}

output "dr_vpc_id" {
  value = module.vpc_dr.vpc_id
}

output "primary_eks_cluster_name" {
  value = module.eks_primary.cluster_name
}

output "dr_eks_cluster_name" {
  value = module.eks_dr.cluster_name
}

output "primary_db_endpoint" {
  value = aws_rds_cluster.primary.endpoint
}

output "velero_bucket_primary" {
  value = aws_s3_bucket.velero_primary.id
}

output "velero_bucket_dr" {
  value = aws_s3_bucket.velero_dr.id
}

output "primary_health_check_id" {
  value = aws_route53_health_check.primary.id
}
