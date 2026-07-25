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
}
