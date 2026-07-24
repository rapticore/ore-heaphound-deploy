variable "project_id" { type = string }
variable "name" {
  type    = string
  default = "ore-heaphound-gcp"
}
variable "region" {
  type    = string
  default = "us-central1"
}
variable "network" {
  description = "Existing VPC network self-link."
  type        = string
}
variable "subnetwork" {
  description = "Existing subnetwork self-link with secondary pod/service ranges."
  type        = string
}
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }
variable "master_ipv4_cidr_block" {
  description = "Unused /28 RFC1918 range for the GKE control-plane peering."
  type        = string
  default     = "172.16.0.0/28"
}
variable "authorized_cidrs" {
  description = "Restricted administrator/CI CIDRs allowed to reach the GKE public control-plane endpoint."
  type        = map(string)

  validation {
    condition = length(var.authorized_cidrs) > 0 && alltrue([
      for cidr, _ in var.authorized_cidrs :
      can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Provide at least one valid restricted CIDR; 0.0.0.0/0 and ::/0 are forbidden."
  }
}
variable "source_bucket_names" {
  description = "GCS buckets the remote worker may read."
  type        = set(string)
  default     = []
}
variable "namespace" {
  type    = string
  default = "sddp"
}
variable "kubernetes_service_account_name" {
  type    = string
  default = "sddp-remote-worker"
}
variable "enable_on_demand_fallback" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = { project = "ore-heaphound", managed-by = "opentofu" }
}
