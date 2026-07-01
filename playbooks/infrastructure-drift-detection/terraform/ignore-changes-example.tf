# ignore-changes-example.tf
# Contoh penggunaan lifecycle ignore_changes untuk mengurangi false positive drift

# Contoh 1: Ignore auto-generated attributes
resource "aws_instance" "app" {
  ami           = "ami-12345678"
  instance_type = "t3.medium"
  
  tags = {
    Name = "app-server"
  }
  
  lifecycle {
    ignore_changes = [
      # Ignore timestamp yang auto-update
      tags["LastUpdated"],
      tags["CreatedDate"],
      
      # User data sering berubah karena secrets rotation
      user_data,
      user_data_base64,
      
      # AMI ID bisa berubah saat auto-patching
      # ami, # Hati-hati: ini bisa hide drift yang legit
    ]
  }
}

# Contoh 2: Autoscaling group - ignore desired capacity
resource "aws_autoscaling_group" "app" {
  name                = "app-asg"
  min_size            = 2
  max_size            = 10
  desired_capacity    = 3
  vpc_zone_identifier = var.subnet_ids
  
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  
  lifecycle {
    ignore_changes = [
      # Desired capacity berubah saat auto-scaling, ini expected
      desired_capacity,
      
      # Load balancer bisa attach/detach otomatis
      target_group_arns,
    ]
  }
}

# Contoh 3: RDS - ignore minor version upgrades
resource "aws_db_instance" "main" {
  identifier        = "main-db"
  engine            = "postgres"
  engine_version    = "15.3"
  instance_class    = "db.t3.medium"
  allocated_storage = 100
  
  lifecycle {
    ignore_changes = [
      # AWS auto-apply minor version patches
      engine_version,
      
      # Latest snapshot bisa berubah
      latest_restorable_time,
    ]
  }
}

# Contoh 4: Lambda function - ignore last_modified
resource "aws_lambda_function" "processor" {
  function_name = "data-processor"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  
  filename         = "lambda.zip"
  source_code_hash = filebase64sha256("lambda.zip")
  
  lifecycle {
    ignore_changes = [
      # Last modified timestamp auto-update
      last_modified,
      
      # Qualified ARN berubah setiap deploy
      qualified_arn,
      
      # Version berubah saat publish
      version,
    ]
  }
}

# Contoh 5: EKS - ignore platform version
resource "aws_eks_cluster" "main" {
  name     = "main-cluster"
  role_arn = aws_iam_role.eks.arn
  version  = "1.28"
  
  vpc_config {
    subnet_ids = var.subnet_ids
  }
  
  lifecycle {
    ignore_changes = [
      # Platform version auto-update oleh AWS
      # platform_version, # Uncomment jika mau ignore
    ]
  }
}

# Contoh 6: S3 bucket - ignore replication status
resource "aws_s3_bucket" "data" {
  bucket = "my-data-bucket"
  
  lifecycle {
    ignore_changes = [
      # Replication configuration bisa dimanage eksternal
      replication_configuration,
      
      # Lifecycle rules kadang di-tune manual
      # lifecycle_rule, # Hati-hati, bisa hide config drift
    ]
  }
}

# ⚠️  BEST PRACTICES:
# 1. Dokumentasikan KENAPA field di-ignore
# 2. Review ignore_changes secara berkala (quarterly)
# 3. Jangan ignore security-critical fields (security_groups, iam_role, encryption)
# 4. Prefer explicit ignore daripada wildcard
# 5. Monitor ignored fields dengan CloudWatch Events atau Config Rules

# Anti-pattern: Jangan lakukan ini!
# resource "aws_instance" "bad_example" {
#   ami = "ami-12345"
#   
#   lifecycle {
#     ignore_changes = all  # ❌ BAHAYA: Ignore semua drift!
#   }
# }
