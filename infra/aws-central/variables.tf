variable "name" {
  type    = string
  default = "ore-heaphound"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "kubernetes_version" {
  description = "Exact EKS Kubernetes version qualified with the pinned managed add-ons in eks_addon_versions."
  type        = string
  default     = "1.34"

  validation {
    condition     = var.kubernetes_version == "1.34"
    error_message = "This immutable deployment module is qualified only for EKS Kubernetes 1.34."
  }
}

variable "eks_addon_versions" {
  description = "Exact EKS managed add-on versions verified by prerequisites.lock.json. Update only through a new immutable release."
  type        = map(string)
  default = {
    amazon-cloudwatch-observability = "v6.4.0-eksbuild.1"
    aws-ebs-csi-driver              = "v1.63.0-eksbuild.1"
    aws-efs-csi-driver              = "v3.4.0-eksbuild.1"
    coredns                         = "v1.13.2-eksbuild.11"
    eks-pod-identity-agent          = "v1.3.10-eksbuild.3"
    kube-proxy                      = "v1.34.6-eksbuild.17"
    vpc-cni                         = "v1.22.4-eksbuild.3"
  }

  validation {
    condition = (
      toset(keys(var.eks_addon_versions)) == toset([
        "amazon-cloudwatch-observability",
        "aws-ebs-csi-driver",
        "aws-efs-csi-driver",
        "coredns",
        "eks-pod-identity-agent",
        "kube-proxy",
        "vpc-cni",
      ]) &&
      alltrue([
        for addon, version in {
          amazon-cloudwatch-observability = "v6.4.0-eksbuild.1"
          aws-ebs-csi-driver              = "v1.63.0-eksbuild.1"
          aws-efs-csi-driver              = "v3.4.0-eksbuild.1"
          coredns                         = "v1.13.2-eksbuild.11"
          eks-pod-identity-agent          = "v1.3.10-eksbuild.3"
          kube-proxy                      = "v1.34.6-eksbuild.17"
          vpc-cni                         = "v1.22.4-eksbuild.3"
        } : lookup(var.eks_addon_versions, addon, "") == version
      ])
    )
    error_message = "eks_addon_versions must exactly match the seven versions verified by this immutable release."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Exact administrator/CI CIDRs allowed to reach the public EKS API endpoint. Public internet-wide access is forbidden."
  type        = list(string)

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs :
      can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Provide at least one valid restricted CIDR; 0.0.0.0/0 and ::/0 are forbidden."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "s3_gateway_endpoint_policy_json" {
  description = "Optional existing S3 gateway endpoint policy. Null preserves the AWS full-access default; customer overlays should supply the exact policy already recorded in state."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.s3_gateway_endpoint_policy_json == null || can(jsondecode(var.s3_gateway_endpoint_policy_json))
    error_message = "s3_gateway_endpoint_policy_json must be null or valid JSON."
  }
}

variable "namespace" {
  type    = string
  default = "sddp"
}

variable "control_plane_service_account_name" {
  type    = string
  default = "sddp-control-plane"
}

variable "scan_worker_service_account_name" {
  type    = string
  default = "sddp-scan-worker"
}

variable "verification_preview_service_account_name" {
  type    = string
  default = "sddp-verification-preview"
}

variable "source_bucket_arns" {
  description = "Exact S3 source bucket ARNs. The API may list them; scan workers may read versioned objects but cannot write or delete."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.source_bucket_arns : can(regex("^arn:[^:]+:s3:::[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$", arn))])
    error_message = "source_bucket_arns must contain bucket ARNs without object wildcards."
  }
}

variable "source_kms_key_arns" {
  description = "Optional customer-managed KMS keys used by approved source objects."
  type        = list(string)
  default     = []
}

variable "database_name" {
  type    = string
  default = "sddp"
}

variable "database_username" {
  type    = string
  default = "sddp_admin"
}

variable "database_instance_class" {
  description = "Exact RDS class. New deployments use the m8g production baseline; upgrades must pin the currently approved class in the private tfvars overlay and never rely on the default after an out-of-band AWS resize."
  type        = string
  default     = "db.m8g.2xlarge"
}

variable "anchor_bucket_name" {
  description = "Globally unique S3 bucket used for signed evidence anchors."
  type        = string
}

variable "anchor_retention_days" {
  type    = number
  default = 365

  validation {
    condition     = var.anchor_retention_days >= 365
    error_message = "Production evidence retention must be at least 365 days."
  }
}

variable "log_retention_days" {
  description = "Retention for EKS control-plane, VPC flow, and NLB access logs."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 90 && var.log_retention_days <= 3650
    error_message = "log_retention_days must be between 90 and 3650."
  }
}

variable "backup_retention_days" {
  description = "Retention for daily encrypted RDS and EFS recovery points."
  type        = number
  default     = 35

  validation {
    condition     = var.backup_retention_days >= 35 && var.backup_retention_days <= 3650
    error_message = "backup_retention_days must be between 35 and 3650."
  }
}

variable "enable_on_demand_fallback" {
  description = "Allow elastic scan pods to use on-demand nodes when Spot cannot be provisioned. The single LLM baseline node is always on-demand; LLM burst capacity remains Spot-only."
  type        = bool
  default     = true
}

variable "system_node_min_size" {
  description = "Minimum on-demand ARM64 system-node count. Three nodes safely accommodate a concurrent application rollout."
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_min_size >= 2 && var.system_node_min_size <= 20 && floor(var.system_node_min_size) == var.system_node_min_size
    error_message = "system_node_min_size must be a whole number between 2 and 20."
  }
}

variable "system_node_desired_size" {
  description = "Desired on-demand ARM64 system-node count."
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_desired_size >= 2 && var.system_node_desired_size <= 20 && floor(var.system_node_desired_size) == var.system_node_desired_size
    error_message = "system_node_desired_size must be a whole number between 2 and 20."
  }
}

variable "system_node_max_size" {
  description = "Maximum on-demand ARM64 system-node count."
  type        = number
  default     = 6

  validation {
    condition     = var.system_node_max_size >= 3 && var.system_node_max_size <= 20 && floor(var.system_node_max_size) == var.system_node_max_size
    error_message = "system_node_max_size must be a whole number between 3 and 20."
  }
}

variable "scan_instance_categories" {
  description = "EC2 instance categories allowed for scan NodePools when scan_instance_families is empty."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "scan_instance_families" {
  description = "Optional exact EC2 instance families for scan NodePools. Non-empty values take precedence over scan_instance_categories."
  type        = list(string)
  default     = []

  validation {
    condition = (
      length(var.scan_instance_families) <= 16 &&
      alltrue([
        for family in var.scan_instance_families :
        can(regex("^[a-z][a-z0-9-]*$", family))
      ])
    )
    error_message = "scan_instance_families must contain at most 16 valid EC2 instance-family names."
  }
}

variable "scan_min_instance_generation" {
  description = "Minimum EC2 generation allowed for scan NodePools."
  type        = number
  default     = 5

  validation {
    condition = (
      var.scan_min_instance_generation >= 1 &&
      var.scan_min_instance_generation <= 99 &&
      floor(var.scan_min_instance_generation) == var.scan_min_instance_generation
    )
    error_message = "scan_min_instance_generation must be a whole number between 1 and 99."
  }
}

variable "scan_min_instance_vcpu" {
  description = "Minimum vCPU count allowed for each scan NodePool instance."
  type        = number
  default     = 2

  validation {
    condition = (
      var.scan_min_instance_vcpu >= 2 &&
      var.scan_min_instance_vcpu <= 192 &&
      floor(var.scan_min_instance_vcpu) == var.scan_min_instance_vcpu
    )
    error_message = "scan_min_instance_vcpu must be a whole number between 2 and 192."
  }
}

variable "gpu_instance_families" {
  type    = list(string)
  default = ["g5", "g6"]
}

variable "llm_baseline_instance_types" {
  description = "Diversified on-demand GPU instance types for the fixed one-node LLM availability baseline."
  type        = list(string)
  default     = ["g6.xlarge", "g5.xlarge"]

  validation {
    condition = (
      length(var.llm_baseline_instance_types) >= 1 &&
      length(var.llm_baseline_instance_types) <= 8 &&
      alltrue([
        for instance_type in var.llm_baseline_instance_types :
        can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", instance_type))
      ])
    )
    error_message = "llm_baseline_instance_types must contain 1-8 valid EC2 instance types."
  }
}

variable "karpenter_ami_alias" {
  description = "Evaluated immutable EKS AL2023 AMI release used by Karpenter. Mutable @latest aliases are forbidden."
  type        = string
  default     = "al2023@v20260724"

  validation {
    condition     = can(regex("^al2023@v[0-9]{8}$", var.karpenter_ami_alias))
    error_message = "karpenter_ami_alias must pin an evaluated AL2023 release such as al2023@v20260724; @latest is forbidden."
  }
}

variable "operator_secret_name" {
  description = "Exact bootstrap-owned AWS Secrets Manager name for the operator JSON object. AWS central references its metadata but never owns or imports it. Defaults to /<name>/operator."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.operator_secret_name == null || (
      startswith(var.operator_secret_name, "/") &&
      length(var.operator_secret_name) >= 3 &&
      length(var.operator_secret_name) <= 512
    )
    error_message = "operator_secret_name must be null or an absolute Secrets Manager path beginning with /."
  }
}

variable "operator_kubernetes_secret_name" {
  description = "Kubernetes Secret synchronized from the operator Secrets Manager JSON object."
  type        = string
  default     = "sddp-production-operator-secrets"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.operator_kubernetes_secret_name))
    error_message = "operator_kubernetes_secret_name must be a valid DNS label."
  }
}

variable "tags" {
  description = "Stable infrastructure identity tags. During reconciliation preserve the exact tags already recorded in state; do not change ReleaseTag to the software release being reconciled."
  type        = map(string)
  default = {
    Project   = "ore-heaphound"
    ManagedBy = "opentofu"
  }
}

variable "remediation_enabled" {
  description = "Create the remediation executor identity and its quarantine/redacted buckets. When false the deployment has no source-write capability at all."
  type        = bool
  default     = false
}

variable "remediation_executor_service_account_name" {
  type    = string
  default = "sddp-remediation-executor"
}

variable "remediation_rollback_retention_days" {
  description = "Rollback window and S3 lifecycle deadline for PHI-bearing quarantine snapshots."
  type        = number
  default     = 7

  validation {
    condition = (
      var.remediation_rollback_retention_days >= 1 &&
      var.remediation_rollback_retention_days <= 365 &&
      floor(var.remediation_rollback_retention_days) == var.remediation_rollback_retention_days
    )
    error_message = "remediation_rollback_retention_days must be a whole number from 1 through 365."
  }
}
