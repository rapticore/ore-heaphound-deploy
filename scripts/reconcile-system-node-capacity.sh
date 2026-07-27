#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  ORE_HEAPHOUND_EXPECTED_CONTEXT=<kubectl-context> \
    reconcile-system-node-capacity.sh check <region> <account-id> <cluster-name> <node-group-name>

  ORE_HEAPHOUND_EXPECTED_CONTEXT=<kubectl-context> \
  ORE_HEAPHOUND_SYSTEM_NODE_MIGRATION_APPROVED=true \
  ORE_HEAPHOUND_APPROVED_PAYLOAD_SHA256=sha256:<digest> \
    reconcile-system-node-capacity.sh apply <region> <account-id> <cluster-name> <node-group-name>
EOF
  exit 2
}

[[ "$#" -eq 5 ]] || usage

readonly MODE="$1"
readonly REGION="$2"
readonly EXPECTED_ACCOUNT_ID="$3"
readonly CLUSTER_NAME="$4"
readonly NODE_GROUP_NAME="$5"
readonly EXPECTED_CONTEXT="${ORE_HEAPHOUND_EXPECTED_CONTEXT:-}"
readonly SOURCE_MIN_SIZE=2
readonly SOURCE_DESIRED_SIZE=2
readonly TARGET_DESIRED_SIZE=3
readonly TARGET_MIN_SIZE=3
readonly TARGET_MAX_SIZE=6

[[ "$MODE" == "check" || "$MODE" == "apply" ]] || usage
[[ -n "$EXPECTED_CONTEXT" ]] || usage
[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || {
  echo "expected account ID must contain exactly 12 digits" >&2
  exit 1
}
[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || {
  echo "invalid AWS region" >&2
  exit 1
}
[[ "$CLUSTER_NAME" =~ ^[0-9A-Za-z][0-9A-Za-z_-]{0,99}$ ]] || {
  echo "invalid EKS cluster name" >&2
  exit 1
}
[[ "$NODE_GROUP_NAME" =~ ^[0-9A-Za-z][0-9A-Za-z_-]{0,62}$ ]] || {
  echo "invalid EKS node-group name" >&2
  exit 1
}

for required_command in aws jq kubectl; do
  command -v "$required_command" >/dev/null || {
    echo "${required_command} is required" >&2
    exit 1
  }
done

readonly WORK_DIR="$(mktemp -d)"
chmod 0700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT
readonly REQUEST_FILE="${WORK_DIR}/update-nodegroup-config.json"
readonly COORDINATE_FILE="${WORK_DIR}/coordinate"
readonly NODE_GROUP_FILE="${WORK_DIR}/nodegroup.json"

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi
  echo "sha256sum or shasum is required" >&2
  exit 1
}

readonly CURRENT_CONTEXT="$(kubectl config current-context)"
[[ "$CURRENT_CONTEXT" == "$EXPECTED_CONTEXT" ]] || {
  echo "kubectl context mismatch; refusing system-node reconciliation" >&2
  exit 1
}

readonly CALLER_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    --region "$REGION" \
    --query Account \
    --output text \
    --no-cli-pager
)"
[[ "$CALLER_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
  echo "AWS account mismatch; refusing system-node reconciliation" >&2
  exit 1
}

describe_node_group() {
  aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP_NAME" \
    --query nodegroup \
    --output json \
    --no-cli-pager >"$NODE_GROUP_FILE"
}

validate_node_group_identity() {
  jq -e \
    --arg cluster "$CLUSTER_NAME" \
    --arg node_group "$NODE_GROUP_NAME" \
    '
      .clusterName == $cluster and
      .nodegroupName == $node_group and
      .status == "ACTIVE" and
      .version == "1.34" and
      .capacityType == "ON_DEMAND" and
      .amiType == "AL2023_ARM_64_STANDARD" and
      .instanceTypes == ["m7g.large"] and
      .labels["rapticore.io/workload"] == "system" and
      .labels["rapticore.io/capacity"] == "on-demand" and
      ((.health.issues // []) | length) == 0
    ' "$NODE_GROUP_FILE" >/dev/null || {
    echo "live node-group identity or health differs from the reviewed system pool" >&2
    exit 1
  }
}

describe_node_group
validate_node_group_identity

current_min_size="$(jq -er '.scalingConfig.minSize' "$NODE_GROUP_FILE")"
current_desired_size="$(jq -er '.scalingConfig.desiredSize' "$NODE_GROUP_FILE")"
current_max_size="$(jq -er '.scalingConfig.maxSize' "$NODE_GROUP_FILE")"
readonly current_min_size current_desired_size current_max_size

phase=""
mutation_required=false
case "${current_min_size}/${current_desired_size}/${current_max_size}" in
  "${SOURCE_MIN_SIZE}/${SOURCE_DESIRED_SIZE}/${TARGET_MAX_SIZE}")
    phase="desired-size-update-required"
    mutation_required=true
    ;;
  "${SOURCE_MIN_SIZE}/${TARGET_DESIRED_SIZE}/${TARGET_MAX_SIZE}")
    phase="terraform-reconciliation-ready"
    ;;
  "${TARGET_MIN_SIZE}/${TARGET_DESIRED_SIZE}/${TARGET_MAX_SIZE}")
    phase="complete"
    ;;
  *)
    echo "live scaling configuration is outside the reviewed 2/2/6, 2/3/6, or 3/3/6 states" >&2
    exit 1
    ;;
esac
readonly phase mutation_required

printf '%s' \
  "${EXPECTED_ACCOUNT_ID}|${REGION}|${CLUSTER_NAME}|${NODE_GROUP_NAME}" \
  >"$COORDINATE_FILE"
readonly COORDINATE_SHA256="$(sha256_file "$COORDINATE_FILE")"
readonly CLIENT_REQUEST_TOKEN="ore-heaphound-capacity-${COORDINATE_SHA256:0:24}"

jq -cnS \
  --arg client_request_token "$CLIENT_REQUEST_TOKEN" \
  --arg cluster_name "$CLUSTER_NAME" \
  --arg node_group_name "$NODE_GROUP_NAME" \
  '{
    clientRequestToken: $client_request_token,
    clusterName: $cluster_name,
    nodegroupName: $node_group_name,
    scalingConfig: {
      desiredSize: 3,
      maxSize: 6,
      minSize: 2
    }
  }' >"$REQUEST_FILE"
chmod 0600 "$REQUEST_FILE"
readonly REQUEST_SHA256="sha256:$(sha256_file "$REQUEST_FILE")"

print_preflight() {
  jq -nS \
    --arg account_id "$EXPECTED_ACCOUNT_ID" \
    --arg region "$REGION" \
    --arg cluster_name "$CLUSTER_NAME" \
    --arg node_group_name "$NODE_GROUP_NAME" \
    --arg phase "$phase" \
    --argjson current_min_size "$current_min_size" \
    --argjson current_desired_size "$current_desired_size" \
    --argjson current_max_size "$current_max_size" \
    --argjson mutation_required "$mutation_required" \
    --arg request_sha256 "$REQUEST_SHA256" \
    --slurpfile request "$REQUEST_FILE" \
    '{
      schema_version: 1,
      operation: "eks-system-node-desired-size-migration",
      account_id: $account_id,
      region: $region,
      cluster_name: $cluster_name,
      node_group_name: $node_group_name,
      phase: $phase,
      current: {
        min_size: $current_min_size,
        desired_size: $current_desired_size,
        max_size: $current_max_size
      },
      intermediate_target: {
        min_size: 2,
        desired_size: 3,
        max_size: 6
      },
      terraform_target: {
        min_size: 3,
        desired_size: 3,
        max_size: 6
      },
      mutation_required: $mutation_required,
      request_sha256: $request_sha256,
      request: $request[0]
    }'
}

if [[ "$MODE" == "check" ]]; then
  print_preflight
  exit 0
fi

wait_for_ready_nodes() {
  local attempt nodes ready_nodes
  for ((attempt = 1; attempt <= 120; attempt++)); do
    nodes="$(
      kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${NODE_GROUP_NAME}" \
        -o json
    )"
    ready_nodes="$(
      jq -r '
        [
          .items[] |
          select((.spec.unschedulable // false) == false) |
          select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        ] | length
      ' <<<"$nodes"
    )"
    if ((ready_nodes >= TARGET_DESIRED_SIZE)); then
      printf '%s' "$ready_nodes"
      return
    fi
    sleep 5
  done
  echo "timed out waiting for three Ready system nodes" >&2
  exit 1
}

if [[ "$phase" == "complete" ]]; then
  readonly READY_NODES="$(wait_for_ready_nodes)"
  jq -nS \
    --arg phase "$phase" \
    --argjson ready_nodes "$READY_NODES" \
    '{status: "already-complete", phase: $phase, ready_nodes: $ready_nodes}'
  exit 0
fi

if [[ "$phase" == "terraform-reconciliation-ready" ]]; then
  readonly READY_NODES="$(wait_for_ready_nodes)"
  jq -nS \
    --arg phase "$phase" \
    --arg request_sha256 "$REQUEST_SHA256" \
    --argjson ready_nodes "$READY_NODES" \
    '{
      status: "already-prepared",
      phase: $phase,
      request_sha256: $request_sha256,
      ready_nodes: $ready_nodes
    }'
  exit 0
fi

[[ "${ORE_HEAPHOUND_SYSTEM_NODE_MIGRATION_APPROVED:-}" == "true" ]] || {
  echo "explicit system-node migration approval has not been recorded" >&2
  exit 1
}
[[ "${ORE_HEAPHOUND_APPROVED_PAYLOAD_SHA256:-}" == "$REQUEST_SHA256" ]] || {
  echo "approved payload digest does not match the exact released request" >&2
  exit 1
}

readonly UPDATE_ID="$(
  aws eks update-nodegroup-config \
    --region "$REGION" \
    --cli-input-json "file://${REQUEST_FILE}" \
    --query update.id \
    --output text \
    --no-cli-pager
)"
[[ -n "$UPDATE_ID" && "$UPDATE_ID" != "None" ]] || {
  echo "EKS did not return a system-node update ID" >&2
  exit 1
}

update_succeeded=false
for ((attempt = 1; attempt <= 120; attempt++)); do
  update_status="$(
    aws eks describe-update \
      --region "$REGION" \
      --name "$CLUSTER_NAME" \
      --nodegroup-name "$NODE_GROUP_NAME" \
      --update-id "$UPDATE_ID" \
      --query update.status \
      --output text \
      --no-cli-pager
  )"
  case "$update_status" in
    Successful)
      update_succeeded=true
      break
      ;;
    Failed | Cancelled)
      echo "EKS system-node desired-size update ended with status ${update_status}" >&2
      exit 1
      ;;
    InProgress)
      sleep 5
      ;;
    *)
      echo "unexpected EKS system-node update status: ${update_status}" >&2
      exit 1
      ;;
  esac
done
[[ "$update_succeeded" == "true" ]] || {
  echo "timed out waiting for the EKS system-node desired-size update" >&2
  exit 1
}

aws eks wait nodegroup-active \
  --region "$REGION" \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --no-cli-pager

describe_node_group
validate_node_group_identity
jq -e '
  .scalingConfig.minSize == 2 and
  .scalingConfig.desiredSize == 3 and
  .scalingConfig.maxSize == 6
' "$NODE_GROUP_FILE" >/dev/null || {
  echo "system-node desired-size update did not reach the reviewed 2/3/6 state" >&2
  exit 1
}

readonly READY_NODES="$(wait_for_ready_nodes)"
jq -nS \
  --arg request_sha256 "$REQUEST_SHA256" \
  --arg update_id "$UPDATE_ID" \
  --argjson ready_nodes "$READY_NODES" \
  '{
    status: "prepared-for-terraform",
    phase: "terraform-reconciliation-ready",
    request_sha256: $request_sha256,
    update_id: $update_id,
    scaling: {
      min_size: 2,
      desired_size: 3,
      max_size: 6
    },
    ready_nodes: $ready_nodes
  }'
