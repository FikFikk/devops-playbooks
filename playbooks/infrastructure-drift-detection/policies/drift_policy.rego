# drift_policy.rego - Open Policy Agent policy untuk drift detection
# Usage: terraform show -json plan.tfplan | conftest test -p policies/ -

package terraform.drift

# Deny jika ada resource yang akan di-update (drift terdeteksi)
deny[msg] {
  resource := input.resource_changes[_]
  resource.change.actions[_] == "update"
  
  msg = sprintf("Drift detected: %s will be updated. Manual changes detected outside of Terraform.", [resource.address])
}

# Deny jika ada resource yang hilang (drift deletion)
deny[msg] {
  resource := input.resource_changes[_]
  resource.change.actions[_] == "delete"
  
  msg = sprintf("Drift detected: %s is missing from infrastructure. Resource was deleted outside of Terraform.", [resource.address])
}

# Warning untuk resource yang akan dibuat (unmanaged resources)
warn[msg] {
  resource := input.resource_changes[_]
  resource.change.actions[_] == "create"
  
  msg = sprintf("Unmanaged resource detected: %s exists in infrastructure but not in Terraform state.", [resource.address])
}

# Critical drift: Security-related resources
deny[msg] {
  resource := input.resource_changes[_]
  contains(resource.type, "security_group")
  resource.change.actions[_] != "no-op"
  
  msg = sprintf("CRITICAL: Security group drift detected on %s. Immediate review required.", [resource.address])
}

deny[msg] {
  resource := input.resource_changes[_]
  startswith(resource.type, "aws_iam")
  resource.change.actions[_] != "no-op"
  
  msg = sprintf("CRITICAL: IAM drift detected on %s. Security impact - immediate review required.", [resource.address])
}

# High-priority drift: Database and compute
deny[msg] {
  resource := input.resource_changes[_]
  critical_types := ["aws_db_instance", "aws_rds_cluster", "aws_eks_cluster", "aws_ec2_instance"]
  resource.type == critical_types[_]
  resource.change.actions[_] != "no-op"
  
  msg = sprintf("HIGH PRIORITY: Critical resource drift detected on %s (type: %s)", [resource.address, resource.type])
}

# Generate drift summary
drift_summary[resource] {
  resource := input.resource_changes[_]
  resource.change.actions[_] != "no-op"
}

# Count drifted resources by type
drift_count_by_type[type] = count {
  resources := [r | r := input.resource_changes[_]; r.change.actions[_] != "no-op"; r.type == type]
  count := count(resources)
  count > 0
}

# Allow list untuk low-impact drift (warning only)
warn[msg] {
  resource := input.resource_changes[_]
  allowed_drift_types := ["aws_s3_bucket_lifecycle_configuration", "aws_cloudwatch_log_retention_policy"]
  resource.type == allowed_drift_types[_]
  resource.change.actions[_] != "no-op"
  
  msg = sprintf("Low-impact drift: %s (type: %s). Consider allowing this via ignore_changes.", [resource.address, resource.type])
}
