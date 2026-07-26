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
    aws-ebs-csi-driver     = "v1.63.0-eksbuild.1"
    aws-efs-csi-driver     = "v3.4.0-eksbuild.1"
    coredns                = "v1.13.2-eksbuild.11"
    eks-pod-identity-agent = "v1.3.10-eksbuild.3"
    kube-proxy             = "v1.34.6-eksbuild.17"
    vpc-cni                = "v1.22.4-eksbuild.3"
  }

  validation {
    condition = (
      toset(keys(var.eks_addon_versions)) == toset([
        "aws-ebs-csi-driver",
        "aws-efs-csi-driver",
        "coredns",
        "eks-pod-identity-agent",
        "kube-proxy",
        "vpc-cni",
      ]) &&
      alltrue([
        for addon, version in {
          aws-ebs-csi-driver     = "v1.63.0-eksbuild.1"
          aws-efs-csi-driver     = "v3.4.0-eksbuild.1"
          coredns                = "v1.13.2-eksbuild.11"
          eks-pod-identity-agent = "v1.3.10-eksbuild.3"
          kube-proxy             = "v1.34.6-eksbuild.17"
          vpc-cni                = "v1.22.4-eksbuild.3"
        } : lookup(var.eks_addon_versions, addon, "") == version
      ])
    )
    error_message = "eks_addon_versions must exactly match the six versions verified by this immutable release."
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
  type    = string
  default = "db.r7g.large"
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

variable "enable_on_demand_fallback" {
  description = "Allow elastic scan and LLM pods to use on-demand nodes when Spot cannot be provisioned."
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
  type    = list(string)
  default = ["c", "m", "r"]
}

variable "gpu_instance_families" {
  type    = list(string)
  default = ["g5", "g6"]
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
