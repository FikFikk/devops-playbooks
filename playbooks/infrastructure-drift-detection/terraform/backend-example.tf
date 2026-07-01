# backend-example.tf
# Contoh konfigurasi Terraform backend untuk drift detection

terraform {
  required_version = ">= 1.5"
  
  # S3 Backend dengan state locking
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "production/infrastructure.tfstate"
    region         = "ap-southeast-1"
    
    # DynamoDB untuk state locking
    dynamodb_table = "terraform-state-lock"
    
    # Enkripsi at rest
    encrypt        = true
    kms_key_id     = "arn:aws:kms:ap-southeast-1:123456789:key/abcd-1234"
    
    # Workspace support
    workspace_key_prefix = "workspaces"
  }
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Alternative: Terraform Cloud backend
# terraform {
#   cloud {
#     organization = "my-company"
#     
#     workspaces {
#       name = "production-infrastructure"
#       # atau tags untuk multi-workspace
#       # tags = ["production", "infrastructure"]
#     }
#   }
# }

# Local untuk testing (JANGAN untuk production)
# terraform {
#   backend "local" {
#     path = "terraform.tfstate"
#   }
# }

# Common tags untuk semua resources
locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Repository  = "github.com/my-org/infrastructure"
    Environment = var.environment
    Owner       = "platform-team"
    Project     = var.project_name
  }
}

# Variable definitions
variable "environment" {
  description = "Environment name (production, staging, development)"
  type        = string
  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be production, staging, or development"
  }
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
}

# Provider configuration dengan default tags
provider "aws" {
  region = "ap-southeast-1"
  
  default_tags {
    tags = local.common_tags
  }
  
  # Assume role untuk proper IAM separation
  assume_role {
    role_arn     = "arn:aws:iam::123456789:role/TerraformExecutionRole"
    session_name = "terraform-${var.environment}"
  }
}
