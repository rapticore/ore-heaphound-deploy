#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-}"
readonly REGION="${2:-}"
readonly EXPECTED_ACCOUNT_ID="${3:-}"
readonly ROLE_NAME="AWSServiceRoleForEC2Spot"
readonly ROLE_PATH="/aws-service-role/spot.amazonaws.com/"
readonly SERVICE_NAME="spot.amazonaws.com"

if [[ "$MODE" != "check" && "$MODE" != "apply" ]] ||
  [[ ! "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
  [[ ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "usage: $0 check|apply AWS_REGION EXPECTED_ACCOUNT_ID" >&2
  exit 2
fi

for command_name in aws jq; do
  command -v "$command_name" >/dev/null ||
    { echo "$command_name is required" >&2; exit 1; }
done

readonly ACTUAL_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    --region "$REGION" \
    --query Account \
    --output text
)"
if [[ "$ACTUAL_ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  echo "AWS account does not match the reviewed deployment account" >&2
  exit 1
fi

read_role() {
  aws iam get-role \
    --role-name "$ROLE_NAME" \
    --output json
}

role_json=""
missing=false
error_text=""
if ! role_json="$(read_role 2>&1)"; then
  error_text="$role_json"
  role_json=""
  if [[ "$error_text" != *"NoSuchEntity"* ]]; then
    echo "unable to inspect the EC2 Spot service-linked role" >&2
    exit 1
  fi
  missing=true
fi

if [[ "$MODE" == "check" ]]; then
  jq -n \
    --arg role "$ROLE_NAME" \
    --argjson missing "$missing" \
    '{
      status: (if $missing then "creation-required" else "ready" end),
      role_name: $role,
      mutation_required: $missing
    }'
  exit 0
fi

if [[ "${ORE_HEAPHOUND_DEPLOYMENT_APPROVED:-}" != "true" ]]; then
  echo "apply requires the consolidated deployment approval (ORE_HEAPHOUND_DEPLOYMENT_APPROVED=true)" >&2
  exit 1
fi

if [[ "$missing" == "true" ]]; then
  create_error=""
  if ! create_error="$(
    aws iam create-service-linked-role \
      --aws-service-name "$SERVICE_NAME" \
      --output json 2>&1
  )"; then
    # Another approved deployment may win the same idempotent race.
    if [[ "$create_error" != *"InvalidInput"* && "$create_error" != *"EntityAlreadyExists"* ]]; then
      echo "unable to create the EC2 Spot service-linked role" >&2
      exit 1
    fi
  fi
  role_json="$(read_role)"
fi

if ! jq -e \
  --arg role "$ROLE_NAME" \
  --arg path "$ROLE_PATH" \
  --arg account "$EXPECTED_ACCOUNT_ID" \
  --arg service "$SERVICE_NAME" '
    .Role.RoleName == $role and
    .Role.Path == $path and
    .Role.Arn == ("arn:aws:iam::" + $account + ":role" + $path + $role) and
    any(
      .Role.AssumeRolePolicyDocument.Statement[];
      .Effect == "Allow" and
      .Action == "sts:AssumeRole" and
      .Principal.Service == $service
    )
  ' <<<"$role_json" >/dev/null; then
  echo "the EC2 Spot service-linked role exists but its identity or trust policy is unexpected" >&2
  exit 1
fi

jq -n --arg role "$ROLE_NAME" '{
  status: "ready",
  role_name: $role,
  mutation_required: false
}'
