terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

variable "cloud_provider" {
  description = "Cloud provider untuk billing export (aws, gcp, azure)"
  type        = string
  validation {
    condition     = contains(["aws", "gcp", "azure"], var.cloud_provider)
    error_message = "cloud_provider harus: aws, gcp, atau azure"
  }
}

variable "billing_export_name" {
  description = "Nama untuk billing export"
  type        = string
  default     = "opencost-billing-export"
}

variable "project_id" {
  description = "GCP Project ID (required untuk GCP)"
  type        = string
  default     = ""
}

variable "subscription_id" {
  description = "Azure Subscription ID (required untuk Azure)"
  type        = string
  default     = ""
}

# ========================================
# AWS: Cost and Usage Report (CUR)
# ========================================

resource "aws_s3_bucket" "cur_bucket" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = "opencost-cur-${data.aws_caller_identity.current[0].account_id}"
  
  tags = {
    Purpose = "OpenCost Billing Data"
    ManagedBy = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "cur_bucket_versioning" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.cur_bucket[0].id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cur_bucket_lifecycle" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.cur_bucket[0].id

  rule {
    id     = "expire-old-cur-data"
    status = "Enabled"

    expiration {
      days = 90  # Keep 90 days of billing data
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "cur_bucket_policy" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.cur_bucket[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCURService"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy"
        ]
        Resource = aws_s3_bucket.cur_bucket[0].arn
      },
      {
        Sid    = "AllowCURWrite"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cur_bucket[0].arn}/*"
      }
    ]
  })
}

resource "aws_cur_report_definition" "opencost_cur" {
  count                      = var.cloud_provider == "aws" ? 1 : 0
  report_name                = var.billing_export_name
  time_unit                  = "HOURLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = aws_s3_bucket.cur_bucket[0].id
  s3_region                  = data.aws_region.current[0].name
  s3_prefix                  = "cur-data"
  
  additional_artifacts = ["ATHENA"]
  
  report_versioning = "OVERWRITE_REPORT"
  
  refresh_closed_reports = true
}

# IAM Role untuk OpenCost access ke S3
resource "aws_iam_role" "opencost_role" {
  count = var.cloud_provider == "aws" ? 1 : 0
  name  = "opencost-billing-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current[0].account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:opencost-system:opencost"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "opencost_s3_access" {
  count = var.cloud_provider == "aws" ? 1 : 0
  name  = "opencost-s3-access"
  role  = aws_iam_role.opencost_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.cur_bucket[0].arn,
          "${aws_s3_bucket.cur_bucket[0].arn}/*"
        ]
      }
    ]
  })
}

data "aws_caller_identity" "current" {
  count = var.cloud_provider == "aws" ? 1 : 0
}

data "aws_region" "current" {
  count = var.cloud_provider == "aws" ? 1 : 0
}

data "aws_eks_cluster" "cluster" {
  count = var.cloud_provider == "aws" ? 1 : 0
  name  = "primary"  # Update dengan nama EKS cluster Anda
}

# ========================================
# GCP: BigQuery Billing Export
# ========================================

provider "google" {
  project = var.project_id
}

resource "google_bigquery_dataset" "billing_export" {
  count       = var.cloud_provider == "gcp" ? 1 : 0
  dataset_id  = "opencost_billing_export"
  location    = "US"
  description = "OpenCost billing data export"

  default_table_expiration_ms = 7776000000  # 90 days

  labels = {
    purpose    = "opencost-billing"
    managed_by = "terraform"
  }
}

# Service Account untuk OpenCost
resource "google_service_account" "opencost_sa" {
  count        = var.cloud_provider == "gcp" ? 1 : 0
  account_id   = "opencost-billing-reader"
  display_name = "OpenCost Billing Reader"
  description  = "Service account untuk OpenCost read billing data"
}

resource "google_project_iam_member" "opencost_bigquery_access" {
  count   = var.cloud_provider == "gcp" ? 1 : 0
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.opencost_sa[0].email}"
}

resource "google_project_iam_member" "opencost_bigquery_job" {
  count   = var.cloud_provider == "gcp" ? 1 : 0
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.opencost_sa[0].email}"
}

resource "google_service_account_key" "opencost_key" {
  count              = var.cloud_provider == "gcp" ? 1 : 0
  service_account_id = google_service_account.opencost_sa[0].name
}

# ========================================
# Azure: Cost Export
# ========================================

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "opencost_rg" {
  count    = var.cloud_provider == "azure" ? 1 : 0
  name     = "opencost-billing-rg"
  location = "East US"

  tags = {
    Purpose   = "OpenCost Billing"
    ManagedBy = "Terraform"
  }
}

resource "azurerm_storage_account" "billing_storage" {
  count                    = var.cloud_provider == "azure" ? 1 : 0
  name                     = "opencostbilling${substr(md5(var.subscription_id), 0, 8)}"
  resource_group_name      = azurerm_resource_group.opencost_rg[0].name
  location                 = azurerm_resource_group.opencost_rg[0].location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    Purpose   = "Billing Export"
    ManagedBy = "Terraform"
  }
}

resource "azurerm_storage_container" "billing_container" {
  count                 = var.cloud_provider == "azure" ? 1 : 0
  name                  = "billing-exports"
  storage_account_name  = azurerm_storage_account.billing_storage[0].name
  container_access_type = "private"
}

# User Assigned Managed Identity untuk OpenCost
resource "azurerm_user_assigned_identity" "opencost_identity" {
  count               = var.cloud_provider == "azure" ? 1 : 0
  name                = "opencost-billing-reader"
  resource_group_name = azurerm_resource_group.opencost_rg[0].name
  location            = azurerm_resource_group.opencost_rg[0].location
}

resource "azurerm_role_assignment" "opencost_storage_access" {
  count                = var.cloud_provider == "azure" ? 1 : 0
  scope                = azurerm_storage_account.billing_storage[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.opencost_identity[0].principal_id
}

resource "azurerm_role_assignment" "opencost_cost_reader" {
  count                = var.cloud_provider == "azure" ? 1 : 0
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_user_assigned_identity.opencost_identity[0].principal_id
}

# ========================================
# Outputs
# ========================================

output "aws_cur_bucket" {
  description = "S3 bucket untuk AWS Cost and Usage Report"
  value       = var.cloud_provider == "aws" ? aws_s3_bucket.cur_bucket[0].id : null
}

output "aws_opencost_role_arn" {
  description = "IAM Role ARN untuk OpenCost"
  value       = var.cloud_provider == "aws" ? aws_iam_role.opencost_role[0].arn : null
}

output "gcp_bigquery_dataset" {
  description = "BigQuery dataset untuk GCP billing export"
  value       = var.cloud_provider == "gcp" ? google_bigquery_dataset.billing_export[0].dataset_id : null
}

output "gcp_service_account_email" {
  description = "Service account email untuk OpenCost"
  value       = var.cloud_provider == "gcp" ? google_service_account.opencost_sa[0].email : null
}

output "gcp_service_account_key" {
  description = "Service account key (base64 encoded) - SENSITIF!"
  value       = var.cloud_provider == "gcp" ? google_service_account_key.opencost_key[0].private_key : null
  sensitive   = true
}

output "azure_storage_account" {
  description = "Azure storage account untuk billing export"
  value       = var.cloud_provider == "azure" ? azurerm_storage_account.billing_storage[0].name : null
}

output "azure_container_name" {
  description = "Azure storage container untuk billing data"
  value       = var.cloud_provider == "azure" ? azurerm_storage_container.billing_container[0].name : null
}

output "azure_identity_client_id" {
  description = "Azure managed identity client ID"
  value       = var.cloud_provider == "azure" ? azurerm_user_assigned_identity.opencost_identity[0].client_id : null
}

output "next_steps" {
  description = "Next steps setelah Terraform apply"
  value       = var.cloud_provider == "aws" ? <<-EOT
    AWS Setup Complete!
    
    1. CUR Report akan mulai generate dalam 24 jam
    2. Update OpenCost values.yaml dengan:
       - S3 Bucket: ${aws_s3_bucket.cur_bucket[0].id}
       - IAM Role: ${aws_iam_role.opencost_role[0].arn}
    
    3. Configure Kubernetes ServiceAccount:
       kubectl annotate serviceaccount opencost \
         -n opencost-system \
         eks.amazonaws.com/role-arn=${aws_iam_role.opencost_role[0].arn}
    
    4. Verify CUR data:
       aws s3 ls s3://${aws_s3_bucket.cur_bucket[0].id}/cur-data/
  EOT
  : var.cloud_provider == "gcp" ? <<-EOT
    GCP Setup Complete!
    
    1. Enable Billing Export di GCP Console:
       - Billing > Billing Export > BigQuery
       - Dataset: ${google_bigquery_dataset.billing_export[0].dataset_id}
    
    2. Create Kubernetes secret:
       kubectl create secret generic gcp-billing \
         -n opencost-system \
         --from-literal=service-account-key='$(terraform output -raw gcp_service_account_key | base64 -d)'
    
    3. Update OpenCost values.yaml:
       - BigQuery Dataset: ${google_bigquery_dataset.billing_export[0].dataset_id}
       - Project ID: ${var.project_id}
    
    4. Verify export:
       bq ls ${google_bigquery_dataset.billing_export[0].dataset_id}
  EOT
  : <<-EOT
    Azure Setup Complete!
    
    1. Configure Cost Export di Azure Portal:
       - Cost Management > Exports
       - Storage: ${azurerm_storage_account.billing_storage[0].name}
       - Container: ${azurerm_storage_container.billing_container[0].name}
    
    2. Create Kubernetes secret:
       kubectl create secret generic azure-billing \
         -n opencost-system \
         --from-literal=subscription-id=${var.subscription_id} \
         --from-literal=client-id=${azurerm_user_assigned_identity.opencost_identity[0].client_id}
    
    3. Configure AKS pod identity atau workload identity
    
    4. Verify export:
       az storage blob list \
         --account-name ${azurerm_storage_account.billing_storage[0].name} \
         --container-name ${azurerm_storage_container.billing_container[0].name}
  EOT
}
