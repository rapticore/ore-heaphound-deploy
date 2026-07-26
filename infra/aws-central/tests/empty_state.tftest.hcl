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
    condition     = aws_db_instance.postgres.db_subnet_group_name == module.vpc.database_subnet_group_name
    error_message = "RDS must consume the DB subnet group owned by the VPC module."
  }

  assert {
    condition     = var.karpenter_ami_alias == "al2023@v20260724"
    error_message = "Karpenter must use the evaluated immutable AL2023 AMI release."
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
    condition     = data.aws_secretsmanager_secret.operator.name == "/ore-heaphound-ci/operator"
    error_message = "The central plan must reference the exact bootstrap-owned operator secret."
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
      aws_eks_pod_identity_association.external_secrets.namespace == "external-secrets" &&
      aws_eks_pod_identity_association.external_secrets.service_account == "external-secrets"
    )
    error_message = "External Secrets must use its dedicated EKS Pod Identity."
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
