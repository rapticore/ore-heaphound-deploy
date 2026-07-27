# Remediation (FR-8) infrastructure.
#
# Discovery is read-only and source mutation is separately authorized (PRD
# invariant 3), so nothing here is attached to the control-plane or scan-worker
# identity. The executor runs in its own pod under its own IRSA role and is the
# only identity in the deployment that can write or delete a source object.
#
# Everything is gated on var.remediation_enabled so a scan-and-triage-only
# deployment creates no write-capable identity at all.

locals {
  remediation_enabled = var.remediation_enabled

  # Object wildcards for the approved source buckets, reused by the conditional
  # write and delete statements below.
  source_object_arns = [for arn in var.source_bucket_arns : "${arn}/*"]
}

data "aws_iam_policy_document" "remediation_assume" {
  count = local.remediation_enabled ? 1 : 0

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
      values   = ["system:serviceaccount:${var.namespace}:${var.remediation_executor_service_account_name}"]
    }
  }
}

resource "aws_iam_role" "remediation_executor" {
  count = local.remediation_enabled ? 1 : 0

  name               = "${var.name}-remediation-executor"
  assume_role_policy = data.aws_iam_policy_document.remediation_assume[0].json
  tags               = var.tags
}

# Quarantine holds the pre-change snapshot that makes rollback possible, so it
# is versioned and retained independently of the source and redacted buckets.
resource "aws_s3_bucket" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket = "${var.name}-quarantine-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.quarantine[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.quarantine[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.quarantine[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.quarantine[0].id

  rule {
    id     = "expire-rollback-snapshots"
    status = "Enabled"

    filter {
      prefix = "quarantine/"
    }

    # The executor normally removes the exact version at this deadline. S3
    # lifecycle is the independent retention backstop if the workload is down.
    expiration {
      days = var.remediation_rollback_retention_days
    }

    # Expiring a current object in a versioned bucket creates a delete marker;
    # remove the resulting noncurrent sensitive version promptly.
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.quarantine]
}

data "aws_iam_policy_document" "quarantine_transport" {
  count = local.remediation_enabled ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.quarantine[0].arn,
      "${aws_s3_bucket.quarantine[0].arn}/*",
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

  # An omitted encryption header uses the exact bucket-default KMS key above.
  # If a client supplies an encryption header, refuse any other algorithm or
  # key so a compromised executor cannot downgrade the destination.
  statement {
    sid       = "DenyExplicitNonKMSEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.quarantine[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyExplicitWrongKMSKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.quarantine[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.data.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "quarantine" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.quarantine[0].id
  policy = data.aws_iam_policy_document.quarantine_transport[0].json
}

# Redacted copies. Separate from quarantine so a rollback that deletes the
# redacted output can never touch a rollback snapshot.
resource "aws_s3_bucket" "redacted" {
  count = local.remediation_enabled ? 1 : 0

  bucket = "${var.name}-redacted-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "redacted" {
  count = local.remediation_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.redacted[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "redacted" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.redacted[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redacted" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.redacted[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "redacted_transport" {
  count = local.remediation_enabled ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.redacted[0].arn,
      "${aws_s3_bucket.redacted[0].arn}/*",
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

  statement {
    sid       = "DenyExplicitNonKMSEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.redacted[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyExplicitWrongKMSKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.redacted[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.data.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "redacted" {
  count = local.remediation_enabled ? 1 : 0

  bucket = aws_s3_bucket.redacted[0].id
  policy = data.aws_iam_policy_document.redacted_transport[0].json
}

data "aws_iam_policy_document" "remediation_executor" {
  count = local.remediation_enabled ? 1 : 0

  statement {
    sid = "WriteQuarantineCopies"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = ["${aws_s3_bucket.quarantine[0].arn}/quarantine/*"]
  }

  statement {
    sid = "WriteRedactedCopies"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.redacted[0].arn}/redacted/*"]
  }

  # Delete only the exact output version observed by rollback. The redactor
  # supplies both VersionId and ETag, so this cannot become a bucket-wide
  # cleanup capability or leave a sensitive noncurrent version behind.
  statement {
    sid       = "RemoveExactRedactedOutputVersions"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.redacted[0].arn}/redacted/*"]
  }

  # Rollback snapshots expire independently of rollback. Versioned S3 deletion
  # must target the exact version or it only creates a delete marker and retains
  # the PHI-bearing bytes.
  statement {
    sid       = "PurgeExpiredQuarantineVersions"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.quarantine[0].arn}/quarantine/*"]
  }

  # Read the source object to render a redaction, and read its tags/ACL for the
  # in-place preflight that refuses custom ACLs and SSE-C.
  dynamic "statement" {
    for_each = length(var.source_bucket_arns) > 0 ? [1] : []
    content {
      sid = "ReadApprovedSourceObjectsForRendering"
      actions = [
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:GetObjectTagging",
      ]
      resources = local.source_object_arns
    }
  }

  # The destructive grant. Quarantine and in-place redaction overwrite or remove
  # the source object; both are version-bound at execution time and both take a
  # quarantine snapshot first. Scoped to the exact approved source buckets.
  dynamic "statement" {
    for_each = length(var.source_bucket_arns) > 0 ? [1] : []
    content {
      sid = "MutateApprovedSourceObjectsUnderApproval"
      actions = [
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:PutObjectTagging",
      ]
      resources = local.source_object_arns
    }
  }

  statement {
    sid = "UseDataKeyForRemediationCopies"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = concat([aws_kms_key.data.arn], var.source_kms_key_arns)
  }
}

resource "aws_iam_role_policy" "remediation_executor" {
  count = local.remediation_enabled ? 1 : 0

  name   = "least-privilege-remediation-executor"
  role   = aws_iam_role.remediation_executor[0].id
  policy = data.aws_iam_policy_document.remediation_executor[0].json
}
