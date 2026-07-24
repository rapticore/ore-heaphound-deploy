output "cluster_name" { value = google_container_cluster.this.name }
output "region" { value = var.region }
output "worker_service_account_email" { value = google_service_account.worker.email }
output "helm_service_account_annotation" {
  value = {
    "iam.gke.io/gcp-service-account" = google_service_account.worker.email
  }
}
