#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <region> <database-endpoint> <database-name> <operator-secret-arn> <operator-secret-kms-key-arn>" >&2
  exit 2
}

[[ "$#" -eq 5 ]] || usage

readonly REGION="$1"
readonly DATABASE_ENDPOINT="$2"
readonly DATABASE_NAME="$3"
readonly OPERATOR_SECRET_ARN="$4"
readonly OPERATOR_SECRET_KMS_KEY_ARN="$5"

[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || usage
[[ "$DATABASE_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] || usage
[[ "$DATABASE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage
[[ "$OPERATOR_SECRET_ARN" =~ ^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$ ]] || usage
[[ "$OPERATOR_SECRET_KMS_KEY_ARN" =~ ^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/[A-Za-z0-9-]+$ ]] || usage

for command_name in aws jq openssl; do
  command -v "$command_name" >/dev/null || {
    echo "${command_name} is required" >&2
    exit 1
  }
done

readonly CALLER_ACCOUNT="$(
  aws sts get-caller-identity --query Account --output text
)"
[[ "$OPERATOR_SECRET_ARN" == arn:*:secretsmanager:"${REGION}":"${CALLER_ACCOUNT}":secret:* ]] || {
  echo "refusing an operator secret outside the authenticated AWS account or selected region" >&2
  exit 1
}
[[ "$OPERATOR_SECRET_KMS_KEY_ARN" == arn:*:kms:"${REGION}":"${CALLER_ACCOUNT}":key/* ]] || {
  echo "refusing a KMS key outside the authenticated AWS account or selected region" >&2
  exit 1
}

readonly OPERATOR_KMS_KEY="$(
  aws secretsmanager describe-secret \
    --region "$REGION" \
    --secret-id "$OPERATOR_SECRET_ARN" \
    --query KmsKeyId \
    --output text
)"
[[ "$OPERATOR_KMS_KEY" == "$OPERATOR_SECRET_KMS_KEY_ARN" ]] || {
  echo "operator secret is not encrypted with the expected bootstrap KMS key" >&2
  exit 1
}

umask 077
readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

readonly CURRENT_RESPONSE_FILE="${WORK_DIR}/current-response.json"
readonly CURRENT_SECRET_FILE="${WORK_DIR}/current-secret.json"
readonly CURRENT_VERSION_FILE="${WORK_DIR}/current-version"
readonly EXECUTOR_PASSWORD_FILE="${WORK_DIR}/executor-password"
readonly UPGRADED_SECRET_FILE="${WORK_DIR}/upgraded-secret.json"
readonly CLIENT_TOKEN_FILE="${WORK_DIR}/client-token"
readonly NEW_VERSION_FILE="${WORK_DIR}/new-version"

# Read the value and VersionId in one request. The VersionId is later used as a
# compare-and-swap precondition when AWSCURRENT moves, so a concurrent rotation
# cannot be overwritten silently.
aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --version-stage AWSCURRENT \
  --output json >"$CURRENT_RESPONSE_FILE"

jq -er '.VersionId | select(type == "string" and length > 0)' \
  "$CURRENT_RESPONSE_FILE" >"$CURRENT_VERSION_FILE"
jq -e '.SecretString | fromjson | select(type == "object")' \
  "$CURRENT_RESPONSE_FILE" >"$CURRENT_SECRET_FILE"

if jq -e '
  (.SDDP_EXECUTOR_DATABASE_URL | type == "string" and length > 0) and
  (.SDDP_EXECUTOR_ROLE_PASSWORD | type == "string" and length >= 16)
' "$CURRENT_SECRET_FILE" >/dev/null; then
  echo "Operator secret already contains the remediation executor credentials; no change made."
  exit 0
fi

if ! jq -e '
  (has("SDDP_EXECUTOR_DATABASE_URL") or has("SDDP_EXECUTOR_ROLE_PASSWORD")) | not
' "$CURRENT_SECRET_FILE" >/dev/null; then
  echo "operator secret contains a partial executor credential; refusing an ambiguous rotation" >&2
  exit 1
fi

openssl rand -base64 48 >"$EXECUTOR_PASSWORD_FILE"
openssl rand -hex 32 >"$CLIENT_TOKEN_FILE"

jq \
  --rawfile executor_password "$EXECUTOR_PASSWORD_FILE" \
  --arg host "$DATABASE_ENDPOINT" \
  --arg database "$DATABASE_NAME" '
    ($executor_password | rtrimstr("\n")) as $executor |
    . + {
      SDDP_EXECUTOR_DATABASE_URL:
        ("postgresql://sddp_executor:" + ($executor | @uri) + "@" +
         $host + ":5432/" + ($database | @uri) +
         "?sslmode=verify-full"),
      SDDP_EXECUTOR_ROLE_PASSWORD: $executor
    }
  ' "$CURRENT_SECRET_FILE" >"$UPGRADED_SECRET_FILE"

# Publish under a private staging label first. Moving AWSCURRENT is a separate
# compare-and-swap operation that names the exact version read above. On success
# Secrets Manager retains the former value as AWSPREVIOUS for recovery.
aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --client-request-token "$(<"$CLIENT_TOKEN_FILE")" \
  --secret-string "file://${UPGRADED_SECRET_FILE}" \
  --version-stages SDDP_REMEDIATION_UPGRADE_PENDING \
  --query VersionId \
  --output text >"$NEW_VERSION_FILE"

readonly CURRENT_VERSION="$(<"$CURRENT_VERSION_FILE")"
readonly NEW_VERSION="$(<"$NEW_VERSION_FILE")"
[[ -n "$NEW_VERSION" && "$NEW_VERSION" != "None" ]] || {
  echo "Secrets Manager did not return the staged operator-secret version" >&2
  exit 1
}

if ! aws secretsmanager update-secret-version-stage \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --version-stage AWSCURRENT \
  --move-to-version-id "$NEW_VERSION" \
  --remove-from-version-id "$CURRENT_VERSION" \
  >/dev/null; then
  aws secretsmanager update-secret-version-stage \
    --region "$REGION" \
    --secret-id "$OPERATOR_SECRET_ARN" \
    --version-stage SDDP_REMEDIATION_UPGRADE_PENDING \
    --remove-from-version-id "$NEW_VERSION" \
    >/dev/null 2>&1 || true
  echo "operator secret changed concurrently; staged credentials were not activated" >&2
  exit 1
fi

aws secretsmanager update-secret-version-stage \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --version-stage SDDP_REMEDIATION_UPGRADE_PENDING \
  --remove-from-version-id "$NEW_VERSION" \
  >/dev/null

echo "Operator secret upgraded with a dedicated remediation executor credential; existing fields were preserved."
