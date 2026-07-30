#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 check|clear <namespace> <helm-release>" >&2
  exit 2
}

[[ $# == 3 ]] || usage
readonly MODE="$1"
readonly NAMESPACE="$2"
readonly RELEASE="$3"
[[ "$MODE" == "check" || "$MODE" == "clear" ]] || usage
[[ "$NAMESPACE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
  echo "namespace must be a DNS label" >&2
  exit 2
}
[[ "$RELEASE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
  echo "Helm release must be a DNS label" >&2
  exit 2
}

readonly SELECTOR="app.kubernetes.io/instance=${RELEASE},sddp.io/worker-pool"
objects="$(kubectl --namespace "$NAMESPACE" get scaledobjects.keda.sh \
  --selector "$SELECTOR" --output json)"
count="$(jq -r '.items | length' <<<"$objects")"
(( count > 0 )) || {
  echo "no scan-worker KEDA ScaledObjects matched ${SELECTOR}" >&2
  exit 1
}

jq -c '
  .items
  | sort_by(.metadata.name)
  | map({
      name: .metadata.name,
      pool: .metadata.labels["sddp.io/worker-pool"],
      minimum: (.spec.minReplicaCount // 0),
      maximum: (.spec.maxReplicaCount // 0),
      paused: (.metadata.annotations["autoscaling.keda.sh/paused"] // ""),
      paused_replicas: (.metadata.annotations["autoscaling.keda.sh/paused-replicas"] // "")
    })
' <<<"$objects"

if jq -e '.items[] | select((.spec.maxReplicaCount // 0) < 1)' <<<"$objects" >/dev/null; then
  echo "at least one scan-worker ScaledObject has maxReplicaCount below one; restore the signed Helm values before clearing an administrative pause" >&2
  exit 1
fi

if [[ "$MODE" == "check" ]]; then
  exit 0
fi
[[ "${ORE_HEAPHOUND_DEPLOYMENT_APPROVED:-}" == "true" ]] || {
  echo "clear requires ORE_HEAPHOUND_DEPLOYMENT_APPROVED=true from the approved release rollout" >&2
  exit 1
}

while IFS= read -r name; do
  kubectl --namespace "$NAMESPACE" annotate scaledobject.keda.sh "$name" \
    autoscaling.keda.sh/paused- \
    autoscaling.keda.sh/paused-replicas- \
    --overwrite
done < <(jq -r '.items[].metadata.name' <<<"$objects")

after="$(kubectl --namespace "$NAMESPACE" get scaledobjects.keda.sh \
  --selector "$SELECTOR" --output json)"
if jq -e '.items[] | select(
  (.metadata.annotations["autoscaling.keda.sh/paused"] // "") != "" or
  (.metadata.annotations["autoscaling.keda.sh/paused-replicas"] // "") != ""
)' <<<"$after" >/dev/null; then
  echo "a scan-worker administrative pause annotation remains" >&2
  exit 1
fi
echo "scan-worker KEDA administrative pause annotations cleared"
