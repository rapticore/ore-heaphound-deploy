mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/ore-heaphound-ci"
      id         = "123456789012"
      user_id    = "AROAEXAMPLE:ore-heaphound-ci"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      id            = "ore-heaphound-ci-policy"
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      arn          = "arn:aws:sts::123456789012:assumed-role/ore-heaphound-ci/terraform"
      id           = "arn:aws:sts::123456789012:assumed-role/ore-heaphound-ci/terraform"
      issuer_arn   = "arn:aws:iam::123456789012:role/ore-heaphound-ci"
      issuer_id    = "AROAEXAMPLE"
      issuer_name  = "ore-heaphound-ci"
      session_name = "terraform"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      description = "US West (Oregon)"
      endpoint    = "ec2.us-west-2.amazonaws.com"
      id          = "us-west-2"
      name        = "us-west-2"
    }
  }

  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn        = "arn:aws:secretsmanager:us-west-2:123456789012:secret:/ore-heaphound-ci/operator-example"
      id         = "arn:aws:secretsmanager:us-west-2:123456789012:secret:/ore-heaphound-ci/operator-example"
      kms_key_id = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
      name       = "/ore-heaphound-ci/operator"
    }
  }
}
mock_provider "helm" {}
mock_provider "kubectl" {}

# The real AWS provider reads availability zones during planning. Supply the
# same plan-time shape without requiring credentials or contacting AWS. Other
# computed AWS resource attributes intentionally remain unknown until apply so
# this test catches their accidental use as resource instance keys.
override_data {
  target          = data.aws_availability_zones.available
  override_during = plan
  values = {
    id          = "us-west-2"
    group_names = ["us-west-2"]
    names       = ["us-west-2a", "us-west-2b", "us-west-2c"]
    state       = "available"
    zone_ids    = ["usw2-az1", "usw2-az2", "usw2-az3"]
  }
}

run "empty_state_plan" {
  command = plan

  variables {
    name                                 = "ore-heaphound-ci"
    region                               = "us-west-2"
    anchor_bucket_name                   = "ore-heaphound-ci-anchor"
    cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
  }

  assert {
    condition = toset(keys(aws_efs_mount_target.models)) == toset([
      "0",
      "1",
      "2",
    ])
    error_message = "The empty-state plan must create one EFS mount target for each plan-time-known private subnet."
  }

  assert {
    condition     = module.vpc.database_subnet_group_name == var.name
    error_message = "The VPC module must be the single owner of the named RDS DB subnet group."
  }

  assert {
    condition = (
      aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" &&
      aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-west-2.s3" &&
      length(aws_vpc_endpoint.s3.route_table_ids) > 0 &&
      length(module.vpc.private_route_table_ids) == length(data.aws_availability_zones.available.names)
    )
    error_message = "The release must own the existing private-route S3 gateway endpoint at aws_vpc_endpoint.s3."
  }

  assert {
    condition     = aws_db_instance.postgres.db_subnet_group_name == module.vpc.database_subnet_group_name
    error_message = "RDS must consume the DB subnet group owned by the VPC module."
  }

  assert {
    condition = (
      aws_db_instance.postgres.publicly_accessible == false &&
      length(aws_security_group.database.egress) == 0 &&
      length(aws_security_group.database.ingress) == 1 &&
      one(aws_security_group.database.ingress).protocol == "tcp" &&
      one(aws_security_group.database.ingress).from_port == 5432 &&
      one(aws_security_group.database.ingress).to_port == 5432 &&
      length(coalesce(one(aws_security_group.database.ingress).cidr_blocks, toset([]))) == 0 &&
      length(coalesce(one(aws_security_group.database.ingress).ipv6_cidr_blocks, toset([]))) == 0 &&
      length(one(aws_security_group.database.ingress).security_groups) == 1
    )
    error_message = "RDS must remain private, admit PostgreSQL only from EKS nodes, and have no outbound rules."
  }

  assert {
    condition     = aws_db_instance.postgres.instance_class == "db.m8g.2xlarge"
    error_message = "New production installations must use the m8g database baseline unless an exact customer-approved class is pinned in private tfvars."
  }

  assert {
    condition     = aws_db_instance.postgres.multi_az == false
    error_message = "The approved production cost baseline is Single-AZ RDS."
  }

  assert {
    condition     = var.karpenter_ami_alias == "al2023@v20260724"
    error_message = "Karpenter must use the evaluated immutable AL2023 AMI release."
  }

  assert {
    condition = alltrue([
      for name, manifest in kubectl_manifest.node_pool :
      manifest.yaml_body != null && (
        !startswith(name, "scan_") ||
        (
          strcontains(manifest.yaml_body, "karpenter.k8s.aws/instance-generation") &&
          strcontains(manifest.yaml_body, "karpenter.k8s.aws/instance-cpu")
        )
      )
    ])
    error_message = "Every scan NodePool must enforce the configured minimum instance generation and vCPU count."
  }

  assert {
    condition = (
      var.scan_min_instance_generation == 5 &&
      var.scan_min_instance_vcpu == 2 &&
      length(var.scan_instance_families) == 0
    )
    error_message = "Default scan capacity must preserve generation-5+, category-diversified behavior without excluding standard 2-vCPU family members."
  }

  assert {
    condition = (
      var.system_node_min_size == 3 &&
      var.system_node_desired_size == 3 &&
      var.system_node_max_size == 6
    )
    error_message = "The release must default to the reviewed 3/3/6 system-node capacity."
  }

  assert {
    condition = (
      toset(var.llm_baseline_instance_types) == toset(["g6.xlarge", "g5.xlarge"]) &&
      toset(keys(kubectl_manifest.node_pool)) == toset([
        "scan_spot",
        "llm_spot",
        "scan_fallback",
      ])
    )
    error_message = "The release must keep one managed on-demand LLM baseline and use Karpenter only for Spot LLM burst capacity."
  }

  assert {
    condition = (
      strcontains(kubectl_manifest.node_pool["llm_spot"].yaml_body, "\"karpenter.sh/capacity-type\"") &&
      strcontains(kubectl_manifest.node_pool["llm_spot"].yaml_body, "\"spot\"") &&
      strcontains(kubectl_manifest.node_pool["llm_spot"].yaml_body, "\"WhenEmpty\"")
    )
    error_message = "LLM burst must remain Spot-only and may consolidate only after the GPU node is empty."
  }

  assert {
    condition     = data.aws_secretsmanager_secret.operator.name == "/ore-heaphound-ci/operator"
    error_message = "The central plan must reference the exact bootstrap-owned operator secret."
  }

  assert {
    condition = toset(keys(aws_iam_role.workload)) == toset([
      "control_plane",
      "scan_worker",
      "verification_preview",
    ])
    error_message = "Verification preview must have a distinct workload identity rather than reusing the API or scan-worker role."
  }

  assert {
    condition     = output.operator_secret_kms_key_arn == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "External Secrets must use the KMS key discovered from the bootstrap-owned operator secret."
  }

  assert {
    condition     = var.eks_addon_versions["kube-proxy"] == "v1.34.6-eksbuild.17"
    error_message = "The EKS managed add-on set must match the immutable release lock."
  }

  assert {
    condition = (
      var.eks_addon_versions["amazon-cloudwatch-observability"] == "v6.4.0-eksbuild.1" &&
      length(aws_iam_role_policy_attachment.observability) == 2
    )
    error_message = "Container metrics, logs, and traces require the exact CloudWatch Observability add-on and dedicated Pod Identity."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.external_secrets.namespace == "external-secrets" &&
      aws_eks_pod_identity_association.external_secrets.service_account == "external-secrets"
    )
    error_message = "External Secrets must use its dedicated EKS Pod Identity."
  }

  assert {
    condition = (
      helm_release.load_balancer_controller.version == "3.4.2" &&
      aws_eks_pod_identity_association.load_balancer_controller.service_account == "aws-load-balancer-controller"
    )
    error_message = "The managed production edge requires the exact locked AWS Load Balancer Controller and Pod Identity."
  }

  assert {
    condition = (
      aws_db_instance.postgres.performance_insights_enabled == true &&
      aws_db_instance.postgres.monitoring_interval == 60 &&
      toset(aws_db_instance.postgres.enabled_cloudwatch_logs_exports) == toset(["postgresql", "upgrade"])
    )
    error_message = "RDS production telemetry must remain enabled."
  }

  assert {
    condition = alltrue(flatten([
      for rule in aws_backup_plan.central.rule :
      [for lifecycle in rule.lifecycle : lifecycle.delete_after == 35]
    ]))
    error_message = "The daily encrypted backup plan must select both RDS and EFS with the reviewed retention."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.access_logs.restrict_public_buckets == true
    error_message = "The managed NLB access-log bucket must stay private and authorize only AWS log delivery."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.anchors.restrict_public_buckets == true &&
      aws_s3_bucket_object_lock_configuration.anchors.rule[0].default_retention[0].mode == "COMPLIANCE"
    )
    error_message = "The immutable anchor bucket must remain private and compliance-locked."
  }

  assert {
    condition = (
      local.eks_control_plane_log_types == toset([
        "api",
        "audit",
        "authenticator",
        "controllerManager",
        "scheduler",
      ]) &&
      module.vpc.vpc_flow_log_destination_type == "cloud-watch-logs"
    )
    error_message = "EKS control-plane audit logs and complete VPC flow logging must remain enabled."
  }

  assert {
    condition = (
      length(aws_iam_role.remediation_executor) == 0 &&
      length(aws_s3_bucket.quarantine) == 0 &&
      length(aws_s3_bucket.redacted) == 0 &&
      output.remediation_executor_role_arn == "" &&
      output.quarantine_bucket == "" &&
      output.redacted_bucket == ""
    )
    error_message = "Remediation-disabled plans must create no write identity or remediation buckets."
  }
}

run "remediation_enabled_plan" {
  command = plan

  variables {
    name                                 = "ore-heaphound-ci"
    region                               = "us-west-2"
    anchor_bucket_name                   = "ore-heaphound-ci-anchor"
    cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
    remediation_enabled                  = true
    remediation_rollback_retention_days  = 7
    source_bucket_arns                   = ["arn:aws:s3:::partner-source"]
    source_kms_key_arns                  = ["arn:aws:kms:us-west-2:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
  }

  assert {
    condition = (
      length(aws_iam_role.remediation_executor) == 1 &&
      length(aws_s3_bucket.quarantine) == 1 &&
      length(aws_s3_bucket.redacted) == 1 &&
      aws_s3_bucket_public_access_block.quarantine[0].restrict_public_buckets &&
      aws_s3_bucket_public_access_block.redacted[0].restrict_public_buckets
    )
    error_message = "Remediation-enabled plans must create the isolated executor and private destination buckets."
  }

  assert {
    condition = (
      length(aws_iam_role_policy.scan_worker) == 1 &&
      length(aws_iam_role_policy.verification_preview) == 1 &&
      aws_iam_role_policy.scan_worker[0].name == "least-privilege-source-reader" &&
      aws_iam_role_policy.verification_preview[0].name == "least-privilege-verification-source-reader"
    )
    error_message = "Source-read authority must be attached independently to scan-worker and verification-preview identities, using the same exact read policy."
  }

  assert {
    condition = (
      toset(one([
        for statement in data.aws_iam_policy_document.control_plane.statement :
        statement if statement.sid == "InventoryRedactedOutputsForResidualVerification"
      ]).actions) == toset(["s3:ListBucket"]) &&
      toset(one(
        one([
          for statement in data.aws_iam_policy_document.control_plane.statement :
          statement if statement.sid == "InventoryRedactedOutputsForResidualVerification"
        ]).condition
      ).values) == toset(["redacted/*"]) &&
      toset(one([
        for statement in data.aws_iam_policy_document.scan_worker.statement :
        statement if statement.sid == "ReadVersionedRedactedOutputs"
        ]).actions) == toset([
        "s3:GetObject",
        "s3:GetObjectAttributes",
        "s3:GetObjectTagging",
        "s3:GetObjectVersion",
        "s3:GetObjectVersionAttributes",
        "s3:GetObjectVersionTagging",
      ]) &&
      toset(one([
        for statement in data.aws_iam_policy_document.scan_worker.statement :
        statement if statement.sid == "DecryptRedactedOutputs"
      ]).actions) == toset(["kms:Decrypt"])
    )
    error_message = "Residual verification must inventory only redacted/* and give scan-worker plus verification-preview exact versioned-object/KMS read access."
  }

  assert {
    condition = alltrue(flatten([
      for statement in data.aws_iam_policy_document.scan_worker.statement : [
        for action in statement.actions :
        !startswith(action, "s3:Put") && !startswith(action, "s3:Delete") && action != "s3:ListBucket" && action != "kms:Encrypt" && action != "kms:GenerateDataKey"
      ]
    ]))
    error_message = "The shared scan-worker/verification-preview policy must remain read-only and must not enumerate buckets."
  }

  assert {
    condition = (
      aws_s3_bucket_versioning.quarantine[0].versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_versioning.redacted[0].versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_lifecycle_configuration.quarantine[0].rule[0].expiration[0].days == 7 &&
      aws_s3_bucket_lifecycle_configuration.quarantine[0].rule[0].noncurrent_version_expiration[0].noncurrent_days == 1 &&
      aws_s3_bucket_lifecycle_configuration.quarantine[0].rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 1 &&
      output.remediation_rollback_window == "168h"
    )
    error_message = "Quarantine retention and the application rollback window must remain bound to the same deadline, and unfinished multipart copies must be cleaned up."
  }

  assert {
    condition = (
      toset(one([
        for statement in data.aws_iam_policy_document.remediation_executor[0].statement :
        statement if statement.sid == "VerifyRemovedSourceObjects"
      ]).actions) == toset(["s3:ListBucket"]) &&
      toset(one([
        for statement in data.aws_iam_policy_document.remediation_executor[0].statement :
        statement if statement.sid == "VerifyRemovedSourceObjects"
      ]).resources) == toset(["arn:aws:s3:::partner-source"]) &&
      toset(one([
        for statement in data.aws_iam_policy_document.remediation_executor[0].statement :
        statement if statement.sid == "MutateApprovedSourceObjectsUnderApproval"
        ]).actions) == toset([
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:PutObjectTagging",
      ]) &&
      toset(one([
        for statement in data.aws_iam_policy_document.remediation_executor[0].statement :
        statement if statement.sid == "WriteQuarantineCopies"
        ]).actions) == toset([
        "s3:AbortMultipartUpload",
        "s3:GetObject",
        "s3:PutObject",
        "s3:PutObjectTagging",
      ]) &&
      contains(one([
        for statement in data.aws_iam_policy_document.remediation_executor[0].statement :
        statement if statement.sid == "PurgeExpiredQuarantineVersions"
      ]).actions, "s3:DeleteObjectVersion")
    )
    error_message = "Source absence verification must be bucket-scoped; large-object snapshot/restore must permit bounded multipart cleanup; source mutation must preserve tags and never gain permanent version deletion."
  }

  assert {
    condition = (
      toset([
        for statement in data.aws_iam_policy_document.quarantine_transport[0].statement :
        statement.sid
        ]) == toset([
        "DenyInsecureTransport",
        "DenyExplicitNonKMSEncryption",
        "DenyExplicitWrongKMSKey",
      ]) &&
      toset([
        for statement in data.aws_iam_policy_document.redacted_transport[0].statement :
        statement.sid
        ]) == toset([
        "DenyInsecureTransport",
        "DenyExplicitNonKMSEncryption",
        "DenyExplicitWrongKMSKey",
      ])
    )
    error_message = "Both remediation buckets must deny insecure transport and any explicit KMS downgrade or wrong-key write."
  }
}

run "high_throughput_scan_pool" {
  command = plan

  variables {
    name                                 = "ore-heaphound-ci"
    region                               = "us-west-2"
    anchor_bucket_name                   = "ore-heaphound-ci-anchor"
    cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
    scan_instance_families               = ["m8a"]
    scan_min_instance_generation         = 8
    scan_min_instance_vcpu               = 16
    scan_instance_vcpus                  = [16]
    enable_llm_on_demand_burst           = true
    llm_on_demand_burst_gpu_limit        = 3
    enable_spot_to_spot_consolidation    = true
    database_allocated_storage           = 400
    database_max_allocated_storage       = 2000
    database_iops                        = 12000
    database_storage_throughput          = 500
  }

  assert {
    condition = alltrue([
      for name, manifest in kubectl_manifest.node_pool :
      !startswith(name, "scan_") || (
        strcontains(manifest.yaml_body, "karpenter.k8s.aws/instance-family") &&
        strcontains(manifest.yaml_body, "m8a") &&
        strcontains(manifest.yaml_body, "karpenter.k8s.aws/instance-generation") &&
        strcontains(manifest.yaml_body, "\"7\"") &&
        strcontains(manifest.yaml_body, "karpenter.k8s.aws/instance-cpu") &&
        strcontains(manifest.yaml_body, "\"16\"")
      )
    ])
    error_message = "The high-throughput scan profile must render m8a-only, generation-8+, exact 16-vCPU requirements for every scan NodePool."
  }

  assert {
    condition = (
      strcontains(kubectl_manifest.node_pool["llm_on_demand_burst"].yaml_body, "\"on-demand\"") &&
      strcontains(kubectl_manifest.node_pool["llm_on_demand_burst"].yaml_body, "\"nvidia.com/gpu\"") &&
      var.llm_on_demand_burst_gpu_limit == 3 &&
      strcontains(kubectl_manifest.node_pool["llm_on_demand_burst"].yaml_body, "\"WhenEmpty\"") &&
      strcontains(kubectl_manifest.node_pool["llm_spot"].yaml_body, "\"WhenEmpty\"")
    )
    error_message = "With Spot-to-Spot enabled, both elastic LLM pools must consolidate only when empty and the optional on-demand pool must remain bounded to three single-GPU nodes."
  }

  assert {
    condition = (
      aws_db_instance.postgres.allocated_storage == 400 &&
      aws_db_instance.postgres.max_allocated_storage == 2000 &&
      aws_db_instance.postgres.iops == 12000 &&
      aws_db_instance.postgres.storage_throughput == 500
    )
    error_message = "The high-throughput RDS profile must preserve the reviewed 400-GiB, 12,000-IOPS, 500-MiB/s gp3 settings."
  }
}

run "reject_unlocked_addon_version" {
  command = plan

  variables {
    name                                 = "ore-heaphound-ci"
    region                               = "us-west-2"
    anchor_bucket_name                   = "ore-heaphound-ci-anchor"
    cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
    eks_addon_versions = {
      aws-ebs-csi-driver     = "v1.63.0-eksbuild.1"
      aws-efs-csi-driver     = "v3.4.0-eksbuild.1"
      coredns                = "v1.13.2-eksbuild.11"
      eks-pod-identity-agent = "v1.3.10-eksbuild.3"
      kube-proxy             = "v1.34.6-eksbuild.18"
      vpc-cni                = "v1.22.4-eksbuild.3"
    }
  }

  expect_failures = [var.eks_addon_versions]
}
