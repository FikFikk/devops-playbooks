# =============================================================================
# Terraform — PostgreSQL HA Infrastructure di AWS
# Menyediakan: RDS PostgreSQL Multi-AZ, Aurora Serverless v2, atau
#              EC2 + EBS untuk Patroni cluster self-managed
#
# Topologi yang dibuat:
# - VPC dengan private subnets di 3 AZ
# - Security groups yang ketat
# - EC2 instances untuk Patroni cluster
# - EBS volumes teroptimasi
# - S3 bucket untuk backup (dengan enkripsi + cross-region replication)
# - Route53 health checks
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "database-cluster/terraform.tfstate"
    region = "ap-southeast-1"
    # Aktifkan state locking
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "database-reliability"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "database"
    }
  }
}

# Provider untuk DR region (cross-region backup)
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "database-reliability"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "database"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================
variable "primary_region" {
  description = "AWS region utama untuk database cluster"
  type        = string
  default     = "ap-southeast-1"
}

variable "dr_region" {
  description = "AWS region untuk disaster recovery backup"
  type        = string
  default     = "ap-southeast-3"
}

variable "environment" {
  description = "Environment name (production/staging)"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block untuk VPC database"
  type        = string
  default     = "10.100.0.0/16"
}

variable "db_instance_type" {
  description = "EC2 instance type untuk database nodes"
  type        = string
  default     = "r6i.2xlarge"  # 8 vCPU, 64GB RAM — sesuaikan dengan kebutuhan
}

variable "db_volume_size_gb" {
  description = "Ukuran data volume dalam GB"
  type        = number
  default     = 500
}

variable "db_node_count" {
  description = "Jumlah database node (minimal 3 untuk HA)"
  type        = number
  default     = 3
}

# =============================================================================
# Data Sources
# =============================================================================
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# =============================================================================
# VPC & Networking
# =============================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name             = "db-${var.environment}-vpc"
  cidr             = var.vpc_cidr
  azs              = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets  = ["10.100.1.0/24", "10.100.2.0/24", "10.100.3.0/24"]
  public_subnets   = ["10.100.101.0/24", "10.100.102.0/24", "10.100.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = var.environment != "production"  # HA NAT di production

  enable_vpc_flow_log                      = true
  create_flow_log_cloudwatch_log_group     = true
  create_flow_log_cloudwatch_iam_role      = true
  flow_log_cloudwatch_log_group_retention  = 30

  tags = {
    Name = "db-${var.environment}-vpc"
  }
}

# =============================================================================
# Security Group untuk Database Nodes
# =============================================================================
resource "aws_security_group" "db_nodes" {
  name_prefix = "db-nodes-${var.environment}-"
  vpc_id      = module.vpc.vpc_id
  description = "Security group untuk database nodes Patroni cluster"

  # PostgreSQL traffic antar database nodes
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
    description = "PostgreSQL antar db nodes"
  }

  # Replication traffic
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "PostgreSQL dari VPC (aplikasi & monitoring)"
  }

  # Patroni REST API
  ingress {
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    self        = true
    description = "Patroni REST API antar nodes"
  }

  ingress {
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Patroni REST API dari VPC (HAProxy health check)"
  }

  # etcd cluster communication
  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
    description = "etcd cluster communication"
  }

  # Monitoring
  ingress {
    from_port   = 9187
    to_port     = 9187
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "postgres_exporter untuk Prometheus"
  }

  # SSH (hanya dari bastion)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH dari bastion host"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "bastion" {
  name_prefix = "bastion-${var.environment}-"
  vpc_id      = module.vpc.vpc_id
  description = "Bastion host untuk akses DB nodes"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_OFFICE_IP/32"]  # Ganti dengan IP kantor!
    description = "SSH dari IP kantor"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =============================================================================
# EC2 Instances untuk Database Nodes
# =============================================================================
resource "aws_instance" "db_nodes" {
  count = var.db_node_count

  ami           = data.aws_ami.ubuntu_22_04.id
  instance_type = var.db_instance_type

  # Sebar di 3 AZ untuk HA
  subnet_id = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]

  vpc_security_group_ids = [aws_security_group.db_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.db_nodes.name

  key_name = aws_key_pair.db_ops.key_name

  # Nonaktifkan public IP — akses via bastion
  associate_public_ip_address = false

  # Root volume — OS
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    delete_on_termination = true
    throughput            = 125

    tags = {
      Name = "db-${count.index == 0 ? "primary" : "replica-0${count.index}"}-${var.environment}-root"
    }
  }

  # Data volume — PostgreSQL data
  ebs_block_device {
    device_name           = "/dev/xvdf"
    volume_type           = "gp3"
    volume_size           = var.db_volume_size_gb
    iops                  = 16000  # Max IOPS untuk gp3
    throughput            = 1000   # MB/s
    encrypted             = true
    delete_on_termination = false  # JANGAN hapus saat instance dihapus!
    snapshot_id           = null

    tags = {
      Name = "db-${count.index == 0 ? "primary" : "replica-0${count.index}"}-${var.environment}-data"
      Type = "postgres-data"
    }
  }

  # WAL volume — PostgreSQL WAL (pisahkan dari data untuk performa)
  ebs_block_device {
    device_name           = "/dev/xvdg"
    volume_type           = "gp3"
    volume_size           = 100
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = false

    tags = {
      Name = "db-${count.index == 0 ? "primary" : "replica-0${count.index}"}-${var.environment}-wal"
    }
  }

  # Metadata options — nonaktifkan IMDSv1 untuk keamanan
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # Wajibkan IMDSv2
    http_put_response_hop_limit = 1
  }

  # User data — setup awal
  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tpl", {
    node_index    = count.index
    environment   = var.environment
    s3_bucket     = aws_s3_bucket.db_backup.bucket
    aws_region    = var.primary_region
  }))

  tags = {
    Name = "db-${count.index == 0 ? "primary" : "replica-0${count.index}"}-${var.environment}"
    Role = count.index == 0 ? "primary" : "replica"
  }
}

# =============================================================================
# S3 Bucket untuk Backup
# =============================================================================
resource "aws_s3_bucket" "db_backup" {
  bucket = "db-backup-${var.environment}-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true  # Jangan hapus bucket backup!
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "db_backup" {
  bucket = aws_s3_bucket.db_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "db_backup" {
  bucket = aws_s3_bucket.db_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "db_backup" {
  bucket = aws_s3_bucket.db_backup.id

  rule {
    id     = "backup-lifecycle"
    status = "Enabled"

    transition {
      days          = 14
      storage_class = "INTELLIGENT_TIERING"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365  # Hapus setelah 1 tahun
    }
  }
}

# Block semua public access
resource "aws_s3_bucket_public_access_block" "db_backup" {
  bucket                  = aws_s3_bucket.db_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Replication ke DR region
resource "aws_s3_bucket" "db_backup_dr" {
  provider = aws.dr
  bucket   = "db-backup-dr-${var.environment}-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "db_backup_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.db_backup_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_replication_configuration" "backup_replication" {
  bucket = aws_s3_bucket.db_backup.id
  role   = aws_iam_role.replication.arn

  depends_on = [aws_s3_bucket_versioning.db_backup]

  rule {
    id     = "ReplicateBackupsToDR"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.db_backup_dr.arn
      storage_class = "GLACIER_IR"  # Hemat biaya di DR
    }
  }
}

# =============================================================================
# KMS Key untuk enkripsi backup
# =============================================================================
resource "aws_kms_key" "backup" {
  description             = "KMS key untuk enkripsi database backup"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true  # Untuk cross-region restore

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow DB nodes to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.db_nodes.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "backup" {
  name          = "alias/db-backup-${var.environment}"
  target_key_id = aws_kms_key.backup.key_id
}

# =============================================================================
# IAM Role untuk DB Nodes
# =============================================================================
resource "aws_iam_role" "db_nodes" {
  name = "db-nodes-${var.environment}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "db_nodes_s3" {
  name = "db-nodes-s3-backup-access"
  role = aws_iam_role.db_nodes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.db_backup.arn,
          "${aws_s3_bucket.db_backup.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.backup.arn
      }
    ]
  })
}

# SSM untuk akses tanpa SSH jika perlu
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.db_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "db_nodes" {
  name = "db-nodes-${var.environment}-profile"
  role = aws_iam_role.db_nodes.name
}

# =============================================================================
# Key Pair untuk SSH
# =============================================================================
resource "aws_key_pair" "db_ops" {
  key_name   = "db-ops-${var.environment}"
  public_key = file("~/.ssh/db_ops_key.pub")  # Generate terlebih dahulu!
}

# =============================================================================
# Outputs
# =============================================================================
output "db_node_private_ips" {
  description = "Private IPs dari database nodes"
  value       = aws_instance.db_nodes[*].private_ip
}

output "backup_bucket_name" {
  description = "Nama S3 bucket untuk backup"
  value       = aws_s3_bucket.db_backup.bucket
}

output "backup_kms_key_id" {
  description = "KMS Key ID untuk enkripsi backup"
  value       = aws_kms_key.backup.key_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
