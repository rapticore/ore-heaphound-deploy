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
