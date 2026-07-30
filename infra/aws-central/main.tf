data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "eks_pod_identity_assume" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "csi" {
  for_each = {
    ebs = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    efs = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  }

  name               = "${var.name}-${each.key}-csi"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "csi" {
  for_each = aws_iam_role.csi

  role       = each.value.name
  policy_arn = each.key == "ebs" ? "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" : "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_iam_role" "observability" {
  name               = "${var.name}-cloudwatch-observability"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "observability" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])

  role       = aws_iam_role.observability.name
  policy_arn = each.value
}

locals {
  azs                  = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name         = var.name
  operator_secret_name = coalesce(var.operator_secret_name, "/${var.name}/operator")
  private_subnets      = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  database_subnets     = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 4)]
  public_subnets       = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 8)]
  eks_control_plane_log_types = toset([
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ])
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets
  public_subnets   = local.public_subnets

  create_database_subnet_group = true

  enable_nat_gateway                              = true
  one_nat_gateway_per_az                          = true
  single_nat_gateway                              = false
  enable_dns_hostnames                            = true
  enable_dns_support                              = true
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_max_aggregation_interval               = 60
  flow_log_traffic_type                           = "ALL"

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }
  tags = var.tags
}

# This address intentionally matches the gateway endpoint already present in
# customer production state. Omitting it from a release makes a full plan
# propose deletion, forcing S3 traffic back through NAT and changing both the
# network boundary and cost posture.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  policy            = var.s3_gateway_endpoint_policy_json

  tags = merge(var.tags, {
    Name = "${var.name}-s3-gateway"
  })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name                             = local.cluster_name
  cluster_version                          = var.kubernetes_version
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access          = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  cluster_enabled_log_types                = local.eks_control_plane_log_types
  cloudwatch_log_group_retention_in_days   = var.log_retention_days

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns                = { addon_version = var.eks_addon_versions["coredns"] }
    kube-proxy             = { addon_version = var.eks_addon_versions["kube-proxy"] }
    vpc-cni                = { addon_version = var.eks_addon_versions["vpc-cni"] }
    eks-pod-identity-agent = { addon_version = var.eks_addon_versions["eks-pod-identity-agent"] }
    aws-ebs-csi-driver = {
      addon_version = var.eks_addon_versions["aws-ebs-csi-driver"]
      pod_identity_association = [{
        role_arn        = aws_iam_role.csi["ebs"].arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    aws-efs-csi-driver = {
      addon_version = var.eks_addon_versions["aws-efs-csi-driver"]
      pod_identity_association = [{
        role_arn        = aws_iam_role.csi["efs"].arn
        service_account = "efs-csi-controller-sa"
      }]
    }
    amazon-cloudwatch-observability = {
      addon_version = var.eks_addon_versions["amazon-cloudwatch-observability"]
      pod_identity_association = [{
        role_arn        = aws_iam_role.observability.arn
        service_account = "cloudwatch-agent"
      }]
    }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = ["m7g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = var.system_node_min_size
      desired_size   = var.system_node_desired_size
      max_size       = var.system_node_max_size
      labels = {
        "rapticore.io/workload" = "system"
        "rapticore.io/capacity" = "on-demand"
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_protocol_ipv6          = "disabled"
        http_put_response_hop_limit = 1
        http_tokens                 = "required"
      }
    }
    # The always-ready local-model replica is an availability baseline, not
    # elastic burst capacity. Keeping it in an EKS-managed on-demand group
    # prevents Karpenter consolidation from repeatedly replacing it with scarce
    # Spot capacity. The separate llm-spot NodePool serves replicas 2+.
    llm_baseline = {
      instance_types = var.llm_baseline_instance_types
      ami_type       = "AL2023_x86_64_NVIDIA"
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      labels = {
        "rapticore.io/workload" = "llm"
        "rapticore.io/capacity" = "on-demand"
      }
      taints = {
        llm = {
          key    = "rapticore.io/workload"
          value  = "llm"
          effect = "NO_SCHEDULE"
        }
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_protocol_ipv6          = "disabled"
        http_put_response_hop_limit = 1
        http_tokens                 = "required"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }
  tags = merge(var.tags, { "karpenter.sh/discovery" = local.cluster_name })

  depends_on = [aws_iam_role_policy_attachment.observability]
}

locals {
  oidc_issuer = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

check "system_node_scaling" {
  assert {
    condition = (
      var.system_node_min_size <= var.system_node_desired_size &&
      var.system_node_desired_size <= var.system_node_max_size
    )
    error_message = "System node sizing must satisfy min_size <= desired_size <= max_size."
  }
}

data "aws_iam_policy_document" "workload_assume" {
  for_each = {
    control_plane        = var.control_plane_service_account_name
    scan_worker          = var.scan_worker_service_account_name
    verification_preview = var.verification_preview_service_account_name
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${each.value}"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each = data.aws_iam_policy_document.workload_assume

  name               = "${var.name}-${replace(each.key, "_", "-")}"
  assume_role_policy = each.value.json
}

data "aws_iam_policy_document" "control_plane" {
  statement {
    sid = "WriteImmutableEvidenceAnchors"
    actions = [
      "s3:GetBucketLocation",
      "s3:PutObject",
      "s3:PutObjectRetention",
    ]
    resources = [
      aws_s3_bucket.anchors.arn,
      "${aws_s3_bucket.anchors.arn}/*",
    ]
  }

  statement {
    sid = "EncryptEvidenceAnchors"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.data.arn]
  }

  dynamic "statement" {
    for_each = length(var.source_bucket_arns) > 0 ? [1] : []
    content {
      sid       = "InventoryApprovedSourceBuckets"
      actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
      resources = var.source_bucket_arns
    }
  }
}

resource "aws_iam_role_policy" "control_plane" {
  name   = "least-privilege-control-plane"
  role   = aws_iam_role.workload["control_plane"].id
  policy = data.aws_iam_policy_document.control_plane.json
}

data "aws_iam_policy_document" "scan_worker" {
  dynamic "statement" {
    for_each = length(var.source_bucket_arns) > 0 ? [1] : []
    content {
      sid       = "DiscoverApprovedSourceBucketRegions"
      actions   = ["s3:GetBucketLocation"]
      resources = var.source_bucket_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.source_bucket_arns) > 0 ? [1] : []
    content {
      sid = "ReadVersionedApprovedSourceObjects"
      actions = [
        "s3:GetObject",
        "s3:GetObjectAttributes",
        "s3:GetObjectTagging",
        "s3:GetObjectVersion",
      ]
      resources = [for arn in var.source_bucket_arns : "${arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.source_kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "DecryptApprovedSourceObjects"
      actions   = ["kms:Decrypt"]
      resources = var.source_kms_key_arns
    }
  }
}

resource "aws_iam_role_policy" "scan_worker" {
  count = length(var.source_bucket_arns) > 0 ? 1 : 0

  name   = "least-privilege-source-reader"
  role   = aws_iam_role.workload["scan_worker"].id
  policy = data.aws_iam_policy_document.scan_worker.json
}

resource "aws_iam_role_policy" "verification_preview" {
  count = length(var.source_bucket_arns) > 0 ? 1 : 0

  name   = "least-privilege-verification-source-reader"
  role   = aws_iam_role.workload["verification_preview"].id
  policy = data.aws_iam_policy_document.scan_worker.json
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.37.2"

  cluster_name                    = module.eks.cluster_name
  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true
  enable_spot_termination         = true
  queue_name                      = "${var.name}-karpenter"
}

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  create_namespace = false
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.6.3"
  wait             = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      name = module.karpenter.service_account
    }
    replicas = 2
  })]

  depends_on = [module.eks, module.karpenter]
}

resource "helm_release" "keda" {
  namespace        = "keda"
  create_namespace = true
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.18.2"
  wait             = true

  values = [yamlencode({
    podSecurityContext = { seccompProfile = { type = "RuntimeDefault" } }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "metrics_server" {
  namespace  = "kube-system"
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.13.0"
  wait       = true

  depends_on = [module.eks]
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.name}-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.name}-load-balancer-controller"
  description = "Version-matched AWS Load Balancer Controller v3.4.2 permissions"
  policy      = file("${path.module}/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = local.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn

  depends_on = [module.eks]
}

resource "helm_release" "load_balancer_controller" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.2"
  wait       = true
  timeout    = 900

  values = [yamlencode({
    clusterName  = module.eks.cluster_name
    region       = var.region
    vpcId        = module.vpc.vpc_id
    replicaCount = 2
    image = {
      repository = "public.ecr.aws/eks/aws-load-balancer-controller"
      tag        = "v3.4.2@sha256:3d2c0cddc6cb80e85ca0d9487d8363736fe283501505726491593beb7be2aff9"
    }
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    podDisruptionBudget = { maxUnavailable = 1 }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "aws-load-balancer-controller"
        }
      }
    }]
  })]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.load_balancer_controller,
    aws_iam_role_policy_attachment.load_balancer_controller,
  ]
}

resource "helm_release" "kyverno" {
  namespace        = "kyverno"
  create_namespace = true
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.8.2"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    admissionController  = { replicas = 2 }
    backgroundController = { replicas = 2 }
    cleanupController    = { replicas = 2 }
    reportsController    = { replicas = 2 }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  namespace        = "external-secrets"
  create_namespace = true
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.8.0"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      create = true
      name   = "external-secrets"
    }
    leaderElect = true
  })]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.external_secrets,
  ]
}

resource "helm_release" "nvidia_device_plugin" {
  namespace        = "nvidia-device-plugin"
  create_namespace = true
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.19.3"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    # Every workload=llm node is GPU-backed: one EKS-managed on-demand baseline
    # plus Karpenter Spot burst nodes. Avoid a privileged cluster-wide Node
    # Feature Discovery DaemonSet solely for this plugin.
    nfd = { enabled = false }
    nodeSelector = {
      "rapticore.io/workload" = "llm"
    }
    tolerations = [
      {
        key      = "CriticalAddonsOnly"
        operator = "Exists"
      },
      {
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        key      = "rapticore.io/workload"
        operator = "Equal"
        value    = "llm"
        effect   = "NoSchedule"
      },
    ]
  })]

  depends_on = [module.eks]
}

resource "kubectl_manifest" "node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = var.name }
    spec = {
      amiSelectorTerms           = [{ alias = var.karpenter_ami_alias }]
      role                       = module.karpenter.node_iam_role_name
      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = local.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = local.cluster_name } }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "100Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1
        httpTokens              = "required"
      }
      tags = var.tags
    }
  })

  depends_on = [helm_release.karpenter]
}

locals {
  node_pools = merge({
    scan_spot = {
      workload   = "scan"
      capacity   = "spot"
      weight     = 100
      families   = []
      categories = var.scan_instance_categories
      cpu        = "1000"
      memory     = "4000Gi"
    }
    llm_spot = {
      workload   = "llm"
      capacity   = "spot"
      weight     = 100
      families   = var.gpu_instance_families
      categories = []
      cpu        = "500"
      memory     = "2000Gi"
    }
    }, var.enable_on_demand_fallback ? {
    scan_fallback = {
      workload   = "scan"
      capacity   = "on-demand"
      weight     = 10
      families   = []
      categories = var.scan_instance_categories
      cpu        = "500"
      memory     = "2000Gi"
    }
  } : {})
}

resource "kubectl_manifest" "node_pool" {
  for_each = local.node_pools

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = replace(each.key, "_", "-") }
    spec = {
      weight = each.value.weight
      template = {
        metadata = {
          labels = {
            "rapticore.io/workload" = each.value.workload
            "rapticore.io/capacity" = each.value.capacity == "spot" ? "spot" : "on-demand"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = var.name
          }
          taints = [{
            key    = "rapticore.io/workload"
            value  = each.value.workload
            effect = "NoSchedule"
          }]
          requirements = concat([
            { key = "karpenter.sh/capacity-type", operator = "In", values = [each.value.capacity] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            ], each.value.workload == "scan" ? [
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["4"] }
            ] : [], length(each.value.families) > 0 ? [
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = each.value.families }
            ] : [
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = each.value.categories }
          ])
        }
      }
      limits = {
        cpu    = each.value.cpu
        memory = each.value.memory
      }
      disruption = {
        # GPU model pods carry a warm model/cache and are expensive to restart.
        # Spot interruptions remain recoverable, but routine consolidation only
        # removes an empty LLM node; it never churns a busy underutilized node.
        consolidationPolicy = each.value.workload == "llm" ? "WhenEmpty" : "WhenEmptyOrUnderutilized"
        consolidateAfter    = each.value.workload == "llm" ? "10m" : "60s"
      }
    }
  })

  depends_on = [kubectl_manifest.node_class]
}

resource "aws_kms_key" "data" {
  description             = "${var.name} customer data encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

data "aws_secretsmanager_secret" "operator" {
  # The prerequisite/bootstrap state is the sole owner of this empty encrypted
  # object. Central reads metadata only so a fresh plan cannot duplicate,
  # import, re-key, delete, or read the value of a bootstrap-owned secret.
  name = local.operator_secret_name
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid = "ReadExactOperatorSecret"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [data.aws_secretsmanager_secret.operator.arn]
  }

  statement {
    sid       = "DecryptExactOperatorSecret"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_secretsmanager_secret.operator.kms_key_id]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [data.aws_secretsmanager_secret.operator.arn]
    }
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-exact-operator-secret"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = local.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn

  depends_on = [module.eks]
}

resource "kubectl_manifest" "workload_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.namespace
      labels = {
        "app.kubernetes.io/part-of"                  = "ore-heaphound"
        "pod-security.kubernetes.io/enforce"         = "restricted"
        "pod-security.kubernetes.io/enforce-version" = "v${var.kubernetes_version}"
      }
    }
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "operator_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "ore-heaphound-operator"
      namespace = var.namespace
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
        }
      }
    }
  })

  depends_on = [
    helm_release.external_secrets,
    kubectl_manifest.workload_namespace,
  ]
}

resource "kubectl_manifest" "operator_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ore-heaphound-operator"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "SecretStore"
        name = "ore-heaphound-operator"
      }
      target = {
        name           = var.operator_kubernetes_secret_name
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
      }
      dataFrom = [{
        extract = {
          key = local.operator_secret_name
        }
      }]
    }
  })

  depends_on = [
    kubectl_manifest.operator_secret_store,
  ]
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-postgres-"
  description = "PostgreSQL access from the EKS node security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "postgres" {
  identifier = var.name

  engine                                = "postgres"
  engine_version                        = "16.13"
  instance_class                        = var.database_instance_class
  allocated_storage                     = 100
  max_allocated_storage                 = 2000
  storage_type                          = "gp3"
  storage_encrypted                     = true
  kms_key_id                            = aws_kms_key.data.arn
  db_name                               = var.database_name
  username                              = var.database_username
  manage_master_user_password           = true
  multi_az                              = true
  publicly_accessible                   = false
  db_subnet_group_name                  = module.vpc.database_subnet_group_name
  vpc_security_group_ids                = [aws_security_group.database.id]
  backup_retention_period               = 35
  deletion_protection                   = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${var.name}-final"
  auto_minor_version_upgrade            = true
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.data.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
}

locals {
  access_log_bucket_name = substr("${var.name}-${data.aws_caller_identity.current.account_id}-${var.region}-access-logs", 0, 63)
}

resource "aws_s3_bucket" "access_logs" {
  bucket = local.access_log_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration { days = var.log_retention_days }
    noncurrent_version_expiration { noncurrent_days = var.log_retention_days }
  }
}

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.access_logs.arn]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/ore-heaphound/nlb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}

resource "aws_s3_bucket" "anchors" {
  bucket              = var.anchor_bucket_name
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "anchors" {
  bucket                  = aws_s3_bucket.anchors.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "anchors" {
  bucket = aws_s3_bucket.anchors.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "anchors" {
  bucket = aws_s3_bucket.anchors.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "anchors" {
  bucket = aws_s3_bucket.anchors.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.anchor_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.anchors]
}

data "aws_iam_policy_document" "anchors_transport" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.anchors.arn,
      "${aws_s3_bucket.anchors.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "anchors" {
  bucket = aws_s3_bucket.anchors.id
  policy = data.aws_iam_policy_document.anchors_transport.json
}

resource "aws_efs_file_system" "models" {
  encrypted        = true
  kms_key_id       = aws_kms_key.data.arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.name}-models-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 2049
    to_port         = 2049
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_efs_mount_target" "models" {
  # Resource IDs are unknown until apply and therefore cannot be for_each
  # keys. Keep the instance keys plan-time stable and use the computed subnet
  # IDs only as resource attributes.
  for_each = {
    for index in range(length(local.private_subnets)) :
    tostring(index) => index
  }

  file_system_id  = aws_efs_file_system.models.id
  subnet_id       = module.vpc.private_subnets[each.value]
  security_groups = [aws_security_group.efs.id]
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_vault" "central" {
  name        = "${var.name}-recovery"
  kms_key_arn = aws_kms_key.data.arn
}

resource "aws_backup_plan" "central" {
  name = "${var.name}-daily"
  rule {
    rule_name         = "daily-rds-efs"
    target_vault_name = aws_backup_vault.central.name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 720
    lifecycle {
      delete_after = var.backup_retention_days
    }
    recovery_point_tags = merge(var.tags, { BackupPlan = "${var.name}-daily" })
  }
}

resource "aws_backup_selection" "central" {
  name         = "${var.name}-rds-efs"
  plan_id      = aws_backup_plan.central.id
  iam_role_arn = aws_iam_role.backup.arn
  resources = [
    aws_db_instance.postgres.arn,
    aws_efs_file_system.models.arn,
  ]

  depends_on = [aws_iam_role_policy_attachment.backup]
}
