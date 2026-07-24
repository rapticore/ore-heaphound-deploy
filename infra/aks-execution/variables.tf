variable "name" {
  type    = string
  default = "ore-heaphound-azure"
}
variable "location" {
  type    = string
  default = "westus2"
}
variable "resource_group_name" { type = string }
variable "subnet_id" { type = string }
variable "source_storage_scope_ids" {
  description = "Storage account or container resource IDs the worker may read."
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
