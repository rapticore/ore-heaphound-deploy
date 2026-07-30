output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "database_endpoint" {
  value = aws_db_instance.postgres.address
}

output "database_name" {
  value = var.database_name
}

output "database_master_secret_arn" {
  value = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "anchor_bucket" {
  value = aws_s3_bucket.anchors.id
}

output "data_kms_key_arn" {
  value = aws_kms_key.data.arn
}

output "model_efs_id" {
  value = aws_efs_file_system.models.id
}

output "access_log_bucket" {
  description = "S3 bucket authorized for the released NLB access-log prefix."
  value       = aws_s3_bucket.access_logs.id
}

output "backup_vault_name" {
  value = aws_backup_vault.central.name
}

output "load_balancer_controller_role_arn" {
  value = aws_iam_role.load_balancer_controller.arn
}

output "control_plane_role_arn" {
  value = aws_iam_role.workload["control_plane"].arn
}

output "scan_worker_role_arn" {
  value = aws_iam_role.workload["scan_worker"].arn
}

output "verification_preview_role_arn" {
  description = "Dedicated source-read identity for short-lived no-store finding verification."
  value       = aws_iam_role.workload["verification_preview"].arn
}

output "operator_secret_arn" {
  description = "Bootstrap-owned encrypted operator secret referenced by AWS central. Neither its metadata nor value is owned by this state."
  value       = data.aws_secretsmanager_secret.operator.arn
}

output "operator_secret_kms_key_arn" {
  description = "Customer-managed KMS key protecting the bootstrap-owned operator secret."
  value       = data.aws_secretsmanager_secret.operator.kms_key_id
}

output "operator_kubernetes_secret_name" {
  value = var.operator_kubernetes_secret_name
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "remediation_executor_role_arn" {
  description = "Write-scoped executor identity. Empty when remediation is disabled."
  value       = try(aws_iam_role.remediation_executor[0].arn, "")
}

output "quarantine_bucket" {
  description = "Rollback snapshot destination. Empty when remediation is disabled."
  value       = try(aws_s3_bucket.quarantine[0].id, "")
}

output "redacted_bucket" {
  description = "Redacted-copy destination. Empty when remediation is disabled."
  value       = try(aws_s3_bucket.redacted[0].id, "")
}

output "remediation_rollback_window" {
  description = "Helm remediation.rollbackWindow matching the quarantine lifecycle deadline."
  value       = var.remediation_enabled ? "${var.remediation_rollback_retention_days * 24}h" : ""
}
