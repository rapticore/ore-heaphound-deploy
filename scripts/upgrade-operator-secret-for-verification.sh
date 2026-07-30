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
readonly VERIFICATION_PASSWORD_FILE="${WORK_DIR}/verification-password"
readonly UPGRADED_SECRET_FILE="${WORK_DIR}/upgraded-secret.json"
readonly CLIENT_TOKEN_FILE="${WORK_DIR}/client-token"
readonly NEW_VERSION_FILE="${WORK_DIR}/new-version"

# Read value and VersionId together. AWSCURRENT moves only if the version read
# here is still current, so this add-only upgrade cannot overwrite a rotation.
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
  (.SDDP_VERIFICATION_DATABASE_URL | type == "string" and length > 0) and
  (.SDDP_VERIFICATION_ROLE_PASSWORD | type == "string" and length >= 16)
' "$CURRENT_SECRET_FILE" >/dev/null; then
  echo "Operator secret already contains the verification-preview credentials; no change made."
  exit 0
fi

if ! jq -e '
  (has("SDDP_VERIFICATION_DATABASE_URL") or
   has("SDDP_VERIFICATION_ROLE_PASSWORD")) | not
' "$CURRENT_SECRET_FILE" >/dev/null; then
  echo "operator secret contains a partial verification credential; refusing an ambiguous rotation" >&2
  exit 1
fi

openssl rand -base64 48 >"$VERIFICATION_PASSWORD_FILE"
openssl rand -hex 32 >"$CLIENT_TOKEN_FILE"

jq \
  --rawfile verification_password "$VERIFICATION_PASSWORD_FILE" \
  --arg host "$DATABASE_ENDPOINT" \
  --arg database "$DATABASE_NAME" '
    ($verification_password | rtrimstr("\n")) as $verification |
    . + {
      SDDP_VERIFICATION_DATABASE_URL:
        ("postgresql://sddp_verification_preview:" + ($verification | @uri) + "@" +
         $host + ":5432/" + ($database | @uri) +
         "?sslmode=verify-full"),
      SDDP_VERIFICATION_ROLE_PASSWORD: $verification
    }
  ' "$CURRENT_SECRET_FILE" >"$UPGRADED_SECRET_FILE"

# Stage privately, then compare-and-swap AWSCURRENT. Secrets Manager preserves
# the former value as AWSPREVIOUS for recovery.
aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --client-request-token "$(<"$CLIENT_TOKEN_FILE")" \
  --secret-string "file://${UPGRADED_SECRET_FILE}" \
  --version-stages SDDP_VERIFICATION_UPGRADE_PENDING \
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
    --version-stage SDDP_VERIFICATION_UPGRADE_PENDING \
    --remove-from-version-id "$NEW_VERSION" \
    >/dev/null 2>&1 || true
  echo "operator secret changed concurrently; staged credentials were not activated" >&2
  exit 1
fi

aws secretsmanager update-secret-version-stage \
  --region "$REGION" \
  --secret-id "$OPERATOR_SECRET_ARN" \
  --version-stage SDDP_VERIFICATION_UPGRADE_PENDING \
  --remove-from-version-id "$NEW_VERSION" \
  >/dev/null

echo "Operator secret upgraded with a dedicated verification-preview credential; existing fields were preserved."
