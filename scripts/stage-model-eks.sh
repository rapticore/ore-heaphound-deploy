#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: ORE_HEAPHOUND_EXPECTED_CONTEXT=<context> $0 <resolved-model-pvc-manifest>" >&2
  exit 2
}

[[ "$#" -eq 1 ]] || usage
[[ -n "${ORE_HEAPHOUND_EXPECTED_CONTEXT:-}" ]] || usage

readonly STORAGE_MANIFEST="$1"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly STAGING_MANIFEST="${SCRIPT_DIR}/../manifests/model-staging-eks.yaml"
readonly NAMESPACE="sddp"
readonly JOB_NAME="sddp-model-stager"

command -v kubectl >/dev/null || {
  echo "kubectl is required" >&2
  exit 1
}
for manifest in "$STORAGE_MANIFEST" "$STAGING_MANIFEST"; do
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    echo "manifest must be a regular non-symlink file: $manifest" >&2
    exit 1
  }
  if grep -q 'REPLACE_' "$manifest"; then
    echo "manifest still contains an unresolved REPLACE_ marker: $manifest" >&2
    exit 1
  fi
done

readonly CURRENT_CONTEXT="$(kubectl config current-context)"
[[ "$CURRENT_CONTEXT" == "$ORE_HEAPHOUND_EXPECTED_CONTEXT" ]] || {
  echo "kubectl context mismatch; refusing model staging." >&2
  exit 1
}

staging_applied=false
delete_staging_resources() {
  local failed=0
  kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=true >/dev/null || failed=1
  kubectl -n "$NAMESPACE" delete networkpolicy "$JOB_NAME" --ignore-not-found --wait=true >/dev/null || failed=1
  kubectl -n "$NAMESPACE" delete serviceaccount "$JOB_NAME" --ignore-not-found --wait=true >/dev/null || failed=1
  return "$failed"
}

cleanup() {
  rc=$?
  trap - EXIT
  if [[ "$staging_applied" == "true" ]]; then
    if ! delete_staging_resources; then
      echo "One or more temporary staging resources could not be deleted." >&2
      if [[ "$rc" -eq 0 ]]; then
        rc=1
      fi
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

kubectl apply -f "$STORAGE_MANIFEST"
kubectl -n "$NAMESPACE" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  pvc/sddp-models-rox \
  --timeout=10m

kubectl apply -f "$STAGING_MANIFEST"
staging_applied=true

if ! kubectl -n "$NAMESPACE" wait \
  --for=condition=complete \
  "job/${JOB_NAME}" \
  --timeout=60m; then
  kubectl -n "$NAMESPACE" get "job/${JOB_NAME}" -o wide >&2 || true
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=100 >&2 || true
  exit 1
fi

readonly STAGING_LOG="$(
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=100
)"
if ! grep -q '^MODEL_STAGING_VERIFIED$' <<<"$STAGING_LOG"; then
  echo "Model staging completed without the exact verification marker." >&2
  exit 1
fi

delete_staging_resources
staging_applied=false
echo "Digest-bound model staged and verified; temporary staging resources removed."
