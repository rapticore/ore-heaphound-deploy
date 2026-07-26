#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <region> <database-endpoint> <database-name> <master-secret-arn> <operator-secret-arn> <operator-secret-kms-key-arn>" >&2
  exit 2
}

[[ "$#" -eq 6 ]] || usage

readonly REGION="$1"
readonly DATABASE_ENDPOINT="$2"
readonly DATABASE_NAME="$3"
readonly MASTER_SECRET_ARN="$4"
readonly OPERATOR_SECRET_ARN="$5"
readonly OPERATOR_SECRET_KMS_KEY_ARN="$6"

[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || usage
[[ "$DATABASE_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] || usage
[[ "$DATABASE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage
[[ "$MASTER_SECRET_ARN" =~ ^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$ ]] || usage
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
for secret_arn in "$MASTER_SECRET_ARN" "$OPERATOR_SECRET_ARN"; do
  [[ "$secret_arn" == arn:*:secretsmanager:"${REGION}":"${CALLER_ACCOUNT}":secret:* ]] || {
    echo "refusing a secret ARN outside the authenticated AWS account or selected region" >&2
    exit 1
  }
done
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

readonly EXISTING_VERSION_COUNT="$(
  aws secretsmanager list-secret-version-ids \
    --region "$REGION" \
    --secret-id "$OPERATOR_SECRET_ARN" \
    --query 'length(Versions)' \
    --output text
)"
[[ "$EXISTING_VERSION_COUNT" == "0" ]] || {
  echo "operator secret already has a version; refusing to overwrite it" >&2
  exit 1
}

umask 077
readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

readonly MASTER_FILE="${WORK_DIR}/master.json"
readonly RUNTIME_PASSWORD_FILE="${WORK_DIR}/runtime-password"
readonly WEB_PASSWORD_FILE="${WORK_DIR}/web-password"
readonly OPERATOR_FILE="${WORK_DIR}/operator.json"

aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$MASTER_SECRET_ARN" \
  --query SecretString \
  --output text >"$MASTER_FILE"

jq -e '
  type == "object" and
  (.username | type == "string" and length > 0) and
  (.password | type == "string" and length > 0)
' "$MASTER_FILE" >/dev/null

openssl rand -base64 48 >"$RUNTIME_PASSWORD_FILE"
openssl rand -base64 48 >"$WEB_PASSWORD_FILE"

jq -n \
  --slurpfile master "$MASTER_FILE" \
  --rawfile runtime_password "$RUNTIME_PASSWORD_FILE" \
  --rawfile web_password "$WEB_PASSWORD_FILE" \
  --arg host "$DATABASE_ENDPOINT" \
  --arg database "$DATABASE_NAME" '
    ($master[0]) as $admin |
    ($runtime_password | rtrimstr("\n")) as $runtime |
    ($web_password | rtrimstr("\n")) as $web |
    {
      SDDP_MIGRATION_DATABASE_URL:
        ("postgresql://" + ($admin.username | @uri) + ":" +
         ($admin.password | @uri) + "@" + $host + ":5432/" +
         ($database | @uri) + "?sslmode=verify-full"),
      SDDP_DATABASE_URL:
        ("postgresql://sddp_runtime:" + ($runtime | @uri) + "@" +
         $host + ":5432/" + ($database | @uri) +
         "?sslmode=verify-full"),
      SDDP_RUNTIME_ROLE_PASSWORD: $runtime,
      SDDP_WEB_DATABASE_URL:
        ("postgresql://sddp_web:" + ($web | @uri) + "@" +
         $host + ":5432/" + ($database | @uri) +
         "?sslmode=verify-full"),
      SDDP_WEB_ROLE_PASSWORD: $web
    }
  ' >"$OPERATOR_FILE"

aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --secret-string "file://${OPERATOR_FILE}" \
  >/dev/null

echo "Operator secret populated through the encrypted non-echoing bootstrap path."
