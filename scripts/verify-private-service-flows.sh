#!/usr/bin/env bash
set -euo pipefail

# Qualify the live NetworkPolicy contract that blocked develop.23.2.
#
# The probe uses the exact signed application image being qualified. One Job
# carries the verification-preview labels and must reach the private extraction
# service. A second carries an ordinary component label and must NOT reach the
# same service. Together they prove the allowed path without weakening the
# extraction pool's default-deny boundary.

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <namespace> <helm-release> <application-image@sha256:digest>" >&2
  exit 2
fi

readonly NAMESPACE="$1"
readonly RELEASE="$2"
readonly APPLICATION_IMAGE="$3"

[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || {
  echo "namespace is not a Kubernetes DNS label" >&2
  exit 2
}
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || {
  echo "Helm release is not a Kubernetes DNS label" >&2
  exit 2
}
[[ "$APPLICATION_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {
  echo "application image must be an immutable image@sha256:digest reference" >&2
  exit 2
}

for command in kubectl jq; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 2
  }
done

service_json="$(kubectl get service --namespace "$NAMESPACE" \
  --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=extraction" \
  --output json)"
readonly SERVICE_COUNT="$(jq -er '.items | length' <<<"$service_json")"
[[ "$SERVICE_COUNT" -eq 1 ]] || {
  echo "expected exactly one extraction Service for release $RELEASE, found $SERVICE_COUNT" >&2
  exit 1
}
readonly EXTRACTION_SERVICE="$(jq -er '.items[0].metadata.name' <<<"$service_json")"
readonly EXTRACTION_PORT="$(jq -er '.items[0].spec.ports[] | select(.name == "tika") | .port' <<<"$service_json")"
readonly APP_NAME="$(jq -er '.items[0].metadata.labels["app.kubernetes.io/name"]' <<<"$service_json")"
[[ "$EXTRACTION_SERVICE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || exit 1
[[ "$APP_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || exit 1
[[ "$EXTRACTION_PORT" =~ ^[0-9]+$ ]] && (( EXTRACTION_PORT >= 1 && EXTRACTION_PORT <= 65535 )) || exit 1

readonly SUFFIX="$(date -u +%H%M%S)-$$"
readonly ALLOW_JOB="sddp-flow-allow-${SUFFIX}"
readonly DENY_JOB="sddp-flow-deny-${SUFFIX}"
cleanup() {
  kubectl delete job --namespace "$NAMESPACE" "$ALLOW_JOB" "$DENY_JOB" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

apply_probe() {
  local name="$1"
  local component="$2"
  local expect="$3"
  kubectl apply --namespace "$NAMESPACE" --filename - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 30
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
        app.kubernetes.io/instance: ${RELEASE}
        app.kubernetes.io/component: ${component}
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: probe
          image: ${APPLICATION_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-ec"]
          args:
            - |
              if wget -q -T 8 -t 1 -O /dev/null http://${EXTRACTION_SERVICE}:${EXTRACTION_PORT}/tika; then
                test "${expect}" = allowed
              else
                test "${expect}" = denied
              fi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 5m, memory: 16Mi }
            limits: { cpu: 100m, memory: 64Mi }
EOF
}

apply_probe "$ALLOW_JOB" verification-preview allowed
apply_probe "$DENY_JOB" network-policy-denied-probe denied

for job in "$ALLOW_JOB" "$DENY_JOB"; do
  if ! kubectl wait --namespace "$NAMESPACE" --for=condition=complete \
      --timeout=45s "job/${job}"; then
    kubectl describe job --namespace "$NAMESPACE" "$job" >&2 || true
    kubectl logs --namespace "$NAMESPACE" "job/${job}" >&2 || true
    echo "private-service NetworkPolicy qualification failed: $job" >&2
    exit 1
  fi
done

echo "private-service NetworkPolicy qualification passed: verification-preview reached extraction TCP ${EXTRACTION_PORT}; an unapproved component was denied"
