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

output "control_plane_role_arn" {
  value = aws_iam_role.workload["control_plane"].arn
}

output "scan_worker_role_arn" {
  value = aws_iam_role.workload["scan_worker"].arn
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
