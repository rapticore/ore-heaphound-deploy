#!/usr/bin/env bash
set -euo pipefail

# Customer-owned release reconciler for conservative, unattended application
# updates. It intentionally refuses every release that would change Terraform
# state, detector/model identity, prerequisites, third-party images, or the
# rendered control-plane contract beyond the signed application/extraction
# digests and release labels. A stopped run is handed to the installation agent;
# it is never converted into a partial or container-only upgrade.

usage() {
  echo "usage: $0 check|plan|apply <customer-config.env>" >&2
  exit 2
}

[[ $# == 2 ]] || usage
readonly MODE="$1"
readonly CONFIG="$2"
[[ "$MODE" == "check" || "$MODE" == "plan" || "$MODE" == "apply" ]] || usage
[[ -f "$CONFIG" ]] || {
  echo "customer configuration does not exist: $CONFIG" >&2
  exit 2
}

# The configuration is customer-owned executable shell input. It must never
# come from the release repository.
# shellcheck source=/dev/null
. "$CONFIG"

readonly PUBLIC_REPOSITORY="${ORE_HEAPHOUND_PUBLIC_REPOSITORY:-https://github.com/rapticore/ore-heaphound-deploy}"
readonly RELEASE_API="${ORE_HEAPHOUND_RELEASE_API:-https://api.github.com/repos/rapticore/ore-heaphound-deploy/releases?per_page=100}"
readonly CHANNEL="${ORE_HEAPHOUND_RELEASE_CHANNEL:-stable}"
readonly NAMESPACE="${ORE_HEAPHOUND_NAMESPACE:-sddp}"
readonly CONTROL_RELEASE="${ORE_HEAPHOUND_CONTROL_RELEASE:-ore-heaphound}"
readonly ADMISSION_RELEASE="${ORE_HEAPHOUND_ADMISSION_RELEASE:-ore-heaphound-admission}"
readonly PRIVATE_VALUES="${ORE_HEAPHOUND_PRIVATE_VALUES:-}"
readonly PRIVATE_ADMISSION_VALUES="${ORE_HEAPHOUND_PRIVATE_ADMISSION_VALUES:-}"
readonly TERRAFORM_VARS="${ORE_HEAPHOUND_TERRAFORM_VARS:-}"
readonly TERRAFORM_BACKEND_CONFIG="${ORE_HEAPHOUND_TERRAFORM_BACKEND_CONFIG:-}"
readonly RDS_INSTANCE_ID="${ORE_HEAPHOUND_RDS_INSTANCE_ID:-}"
readonly EXPECTED_DB_CLASS="${ORE_HEAPHOUND_EXPECTED_DB_CLASS:-}"
readonly STATE_DIR="${ORE_HEAPHOUND_RECONCILER_STATE_DIR:-}"
readonly HEALTH_URL="${ORE_HEAPHOUND_HEALTH_URL:-}"
readonly AUTOMATIC_APPLY="${ORE_HEAPHOUND_AUTOMATIC_APPLY:-false}"
readonly REMOTE_EXECUTION_PLANES="${ORE_HEAPHOUND_REMOTE_EXECUTION_PLANES:-unknown}"
readonly TIMEOUT="${ORE_HEAPHOUND_ROLLOUT_TIMEOUT:-30m}"
readonly SOURCE_REPOSITORY="rapticore/ore_heaphound"
readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly APPLICATION_REPOSITORY="public.ecr.aws/n7r3j2c0/ore-heaphound"
readonly EXTRACTION_REPOSITORY="public.ecr.aws/n7r3j2c0/ore-heaphound-tika"

case "$CHANNEL" in
  stable|develop) ;;
  *)
    echo "ORE_HEAPHOUND_RELEASE_CHANNEL must be stable or develop" >&2
    exit 2
    ;;
esac

for command in aws cosign curl git helm jq kubectl sha256sum tar terraform; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 2
  }
done

if [[ "$MODE" != "check" ]]; then
  for required_path in "$PRIVATE_VALUES" "$TERRAFORM_VARS" "$TERRAFORM_BACKEND_CONFIG"; do
    [[ "$required_path" == /* && -f "$required_path" ]] || {
      echo "plan/apply requires absolute existing private values, Terraform variables, and backend configuration paths" >&2
      exit 2
    }
  done
fi
if [[ -n "$PRIVATE_ADMISSION_VALUES" && ( "$PRIVATE_ADMISSION_VALUES" != /* || ! -f "$PRIVATE_ADMISSION_VALUES" ) ]]; then
  echo "ORE_HEAPHOUND_PRIVATE_ADMISSION_VALUES must be an absolute existing path" >&2
  exit 2
fi
if [[ "$MODE" == "apply" ]]; then
  [[ "$AUTOMATIC_APPLY" == "true" ]] || {
    echo "apply requires the standing customer policy ORE_HEAPHOUND_AUTOMATIC_APPLY=true" >&2
    exit 1
  }
  [[ "$STATE_DIR" == /* && -d "$STATE_DIR" ]] || {
    echo "apply requires an existing absolute ORE_HEAPHOUND_RECONCILER_STATE_DIR" >&2
    exit 2
  }
  [[ -n "$RDS_INSTANCE_ID" ]] || {
    echo "apply requires ORE_HEAPHOUND_RDS_INSTANCE_ID for the pre-upgrade snapshot" >&2
    exit 2
  }
  [[ "$REMOTE_EXECUTION_PLANES" == "false" ]] || {
    echo "automatic central reconciliation requires an explicit ORE_HEAPHOUND_REMOTE_EXECUTION_PLANES=false; installed remote planes require installation-agent orchestration" >&2
    exit 1
  }
fi

readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ore-heaphound-release.XXXXXX")"
LOCK_DIR=""
cleanup() {
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

release_identity() {
  printf 'https://github.com/%s/.github/workflows/release.yml@refs/tags/%s' \
    "$SOURCE_REPOSITORY" "$1"
}

current_tag() {
  local chart
  chart="$(
    helm list --namespace "$NAMESPACE" --output json |
      jq -er --arg release "$CONTROL_RELEASE" \
        '[.[] | select(.name == $release) | .chart] | if length == 1 then .[0] else error("control Helm release not found or duplicated") end'
  )"
  [[ "$chart" =~ ^sddp-([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?)$ ]] || {
    echo "cannot derive an immutable release tag from Helm chart: $chart" >&2
    return 1
  }
  printf 'v%s\n' "${BASH_REMATCH[1]}"
}

candidate_is_newer() {
  jq -en --arg current "$1" --arg candidate "$2" '
    def parts:
      capture("^v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(-develop\\.(?<develop>[0-9]+))?$")
      | [
          (.major | tonumber),
          (.minor | tonumber),
          (.patch | tonumber),
          ((.develop // "-1") | tonumber)
        ];
    ($candidate | parts) > ($current | parts)
  '
}

release_index() {
  if [[ -n "${ORE_HEAPHOUND_RELEASE_INDEX_FILE:-}" ]]; then
    [[ "${ORE_HEAPHOUND_RELEASE_INDEX_FILE}" == /* ]] || {
      echo "ORE_HEAPHOUND_RELEASE_INDEX_FILE must be absolute" >&2
      return 1
    }
    cat "${ORE_HEAPHOUND_RELEASE_INDEX_FILE}"
    return
  fi
  local curl_args=(--fail --silent --show-error --location)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${curl_args[@]}" "$RELEASE_API"
}

latest_tag() {
  local pattern
  if [[ "$CHANNEL" == "develop" ]]; then
    pattern='^v[0-9]+\.[0-9]+\.[0-9]+-develop\.[0-9]+$'
  else
    pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
  fi
  release_index |
    jq -er --arg pattern "$pattern" '
      [
        .[]
        | select((.draft // false) == false)
        | .tag_name
        | select(test($pattern))
        | {
            tag: .,
            parts: (
              capture("^v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(-develop\\.(?<develop>[0-9]+))?$")
              | [
                  (.major | tonumber),
                  (.minor | tonumber),
                  (.patch | tonumber),
                  ((.develop // "-1") | tonumber)
                ]
            )
          }
      ]
      | sort_by(.parts)
      | last.tag
    '
}

prove_annotated_public_tag() {
  local tag="$1"
  local refs
  refs="$(git ls-remote --tags "${PUBLIC_REPOSITORY}.git" "refs/tags/${tag}" "refs/tags/${tag}^{}")"
  [[ "$(wc -l <<<"$refs" | tr -d ' ')" -eq 2 ]] ||
    {
      echo "public release tag is missing or is not annotated: $tag" >&2
      return 1
    }
}

download_kit() {
  local tag="$1"
  local destination="$2"
  local version="${tag#v}"
  local base="${PUBLIC_REPOSITORY}/releases/download/${tag}"
  local archive="ore-heaphound-deploy-${version}.tar.gz"
  mkdir -p "$destination"
  for name in "$archive" "${archive}.sha256" "${archive}.sigstore.json"; do
    curl --fail --silent --show-error --location \
      "${base}/${name}" --output "${destination}/${name}"
  done
  (
    cd "$destination"
    sha256sum --check "${archive}.sha256" >/dev/null
  )
  cosign verify-blob \
    --bundle "${destination}/${archive}.sigstore.json" \
    --certificate-identity "$(release_identity "$tag")" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "${destination}/${archive}" >/dev/null

  # Refuse path traversal even though the archive has already been verified.
  if tar -tzf "${destination}/${archive}" |
    awk 'BEGIN { bad=0 } /(^|\/)\.\.(\/|$)|^\// { bad=1 } END { exit !bad }'; then
    echo "signed deployment archive contains an unsafe path" >&2
    return 1
  fi
  if tar -tvzf "${destination}/${archive}" |
    awk 'BEGIN { bad=0 } substr($1,1,1) ~ /^[lh]$/ { bad=1 } END { exit !bad }'; then
    echo "signed deployment archive contains a link entry" >&2
    return 1
  fi
  tar -xzf "${destination}/${archive}" -C "$destination"
  [[ -d "${destination}/customer-deploy" ]] || {
    echo "signed deployment archive lacks customer-deploy/" >&2
    return 1
  }
}

env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

verify_kit() {
  local tag="$1"
  local kit="$2"
  local identity
  identity="$(release_identity "$tag")"
  for required in \
    release-manifest.json release-manifest.sigstore.json release.env \
    detector-bundle-manifest.json detector-bundle-manifest.sha256 \
    withdrawn-releases.json model.lock.json prerequisites.lock.json; do
    [[ -s "${kit}/${required}" ]] || {
      echo "release kit is missing ${required}" >&2
      return 1
    }
  done
  cosign verify-blob \
    --bundle "${kit}/release-manifest.sigstore.json" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "${kit}/release-manifest.json" >/dev/null
  jq -e --arg tag "$tag" --arg repository "$SOURCE_REPOSITORY" '
    .schema_version == 1 and
    .version == $tag and
    .source.repository == $repository and
    (.source.commit | test("^[a-f0-9]{40}$")) and
    .database.migration_count > 0 and
    (.database.last_migration | test("^[0-9]{4}_[A-Za-z0-9_]+\\.sql$")) and
    .artifacts.detector_bundle.quality_status != null
  ' "${kit}/release-manifest.json" >/dev/null
  if jq -e --arg tag "$tag" '.releases[]? | select(.tag == $tag and .status == "withdrawn")' \
    "${kit}/withdrawn-releases.json" >/dev/null; then
    echo "candidate release is withdrawn: $tag" >&2
    return 1
  fi

  local detector_digest
  detector_digest="$(sha256sum "${kit}/detector-bundle-manifest.json" | awk '{print $1}')"
  [[ "$detector_digest" == "$(jq -er '.artifacts.detector_bundle.sha256' "${kit}/release-manifest.json")" ]]
  [[ "$detector_digest" == "$(tr -d '[:space:]' <"${kit}/detector-bundle-manifest.sha256")" ]]

  local application_image extraction_image
  application_image="$(jq -er '.images[] | select(.component == "application") | .reference + "@" + .digest' "${kit}/release-manifest.json")"
  extraction_image="$(jq -er '.images[] | select(.component == "extraction") | .reference + "@" + .digest' "${kit}/release-manifest.json")"
  [[ "$application_image" == "$(env_value "${kit}/release.env" APPLICATION_IMAGE)" ]]
  [[ "$extraction_image" == "$(env_value "${kit}/release.env" EXTRACTION_IMAGE)" ]]
  [[ "$application_image" == "${APPLICATION_REPOSITORY}@sha256:"* ]]
  [[ "$extraction_image" == "${EXTRACTION_REPOSITORY}@sha256:"* ]]
  for image in "$application_image" "$extraction_image"; do
    cosign verify \
      --certificate-identity "$identity" \
      --certificate-oidc-issuer "$OIDC_ISSUER" \
      "$image" >/dev/null
  done
}

prepare_charts() {
  local tag="$1"
  local kit="$2"
  local chart_dir="$3"
  local identity
  identity="$(release_identity "$tag")"
  local version="${tag#v}"
  mkdir -p "$chart_dir"
  local spec chart_ref digest
  for spec in \
    "sddp|CONTROL_PLANE_CHART|SDDP_DIGEST" \
    "sddp-execution-plane|EXECUTION_PLANE_CHART|SDDP_EXECUTION_PLANE_DIGEST" \
    "sddp-admission|ADMISSION_CHART|SDDP_ADMISSION_DIGEST"; do
    IFS='|' read -r chart_name ref_key digest_key <<<"$spec"
    chart_ref="$(env_value "${kit}/release.env" "$ref_key")"
    digest="$(env_value "${kit}/release.env" "$digest_key")"
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
    cosign verify \
      --certificate-identity "$identity" \
      --certificate-oidc-issuer "$OIDC_ISSUER" \
      "${chart_ref#oci://}@${digest}" >/dev/null
    helm pull "$chart_ref" --version "$version" --destination "$chart_dir"
  done
  jq -r --arg directory "$chart_dir" \
    '.artifacts.helm_charts[] | "\(.sha256)  \($directory)/\(.name)"' \
    "${kit}/release-manifest.json" |
    sha256sum --check -
}

compare_release_posture() {
  local current_kit="$1"
  local candidate_kit="$2"
  local field current_value candidate_value
  for field in \
    '.artifacts.detector_bundle.sha256' \
    '.artifacts.detector_bundle.quality_status' \
    '.artifacts.capability_catalog.sha256'; do
    current_value="$(jq -er "$field" "${current_kit}/release-manifest.json")"
    candidate_value="$(jq -er "$field" "${candidate_kit}/release-manifest.json")"
    [[ "$current_value" == "$candidate_value" ]] || {
      echo "automatic policy stopped on release posture change: ${field}" >&2
      return 1
    }
  done
  for inventory in model.lock.json prerequisites.lock.json; do
    [[ "$(sha256sum "${current_kit}/${inventory}" | awk '{print $1}')" == \
      "$(sha256sum "${candidate_kit}/${inventory}" | awk '{print $1}')" ]] || {
      echo "automatic policy stopped on signed inventory change: ${inventory}" >&2
      return 1
    }
  done
  local current_count candidate_count current_last candidate_last
  current_count="$(jq -er '.database.migration_count' "${current_kit}/release-manifest.json")"
  candidate_count="$(jq -er '.database.migration_count' "${candidate_kit}/release-manifest.json")"
  current_last="$(jq -er '.database.last_migration' "${current_kit}/release-manifest.json")"
  candidate_last="$(jq -er '.database.last_migration' "${candidate_kit}/release-manifest.json")"
  [[ "$candidate_count" == "$current_count" && "$candidate_last" == "$current_last" ]] || {
    echo "automatic policy stopped on a database migration inventory change" >&2
    return 1
  }
  diff -u \
    <(jq -S '.policy.allowedThirdPartyImages' "${current_kit}/values/admission.yaml" 2>/dev/null || sed -n '/allowedThirdPartyImages:/,/signerSubject:/p' "${current_kit}/values/admission.yaml" | sed '/signerSubject:/d') \
    <(jq -S '.policy.allowedThirdPartyImages' "${candidate_kit}/values/admission.yaml" 2>/dev/null || sed -n '/allowedThirdPartyImages:/,/signerSubject:/p' "${candidate_kit}/values/admission.yaml" | sed '/signerSubject:/d') \
    >/dev/null || {
      echo "automatic policy stopped on third-party admission image change" >&2
      return 1
    }
}

image_overrides() {
  local kit="$1"
  local application_reference application_registry application_repository
  local application_digest extraction_reference extraction_digest
  application_reference="$(jq -er '.images[] | select(.component == "application") | .reference' "${kit}/release-manifest.json")"
  [[ "$application_reference" == */* ]] || {
    echo "application image reference lacks registry/repository separation" >&2
    return 1
  }
  application_registry="${application_reference%%/*}"
  application_repository="${application_reference#*/}"
  application_digest="$(jq -er '.images[] | select(.component == "application") | .digest' "${kit}/release-manifest.json")"
  extraction_reference="$(jq -er '.images[] | select(.component == "extraction") | .reference' "${kit}/release-manifest.json")"
  extraction_digest="$(jq -er '.images[] | select(.component == "extraction") | .digest' "${kit}/release-manifest.json")"
  printf '%s\n' \
    "--set-string" "image.registry=${application_registry}" \
    "--set-string" "image.repository=${application_repository}" \
    "--set-string" "image.digest=${application_digest}" \
    "--set-string" "extraction.image.repository=${extraction_reference}" \
    "--set-string" "extraction.image.digest=${extraction_digest}"
}

render_control() {
  local tag="$1"
  local kit="$2"
  local charts="$3"
  local output="$4"
  local version="${tag#v}"
  local overrides=()
  while IFS= read -r value; do overrides+=("$value"); done < <(image_overrides "$kit")
  helm template "$CONTROL_RELEASE" "${charts}/sddp-${version}.tgz" \
    --namespace "$NAMESPACE" \
    --values "${kit}/values/central-eks.yaml" \
    --values "$PRIVATE_VALUES" \
    "${overrides[@]}" >"$output"
  ! grep -q 'REPLACE_' "$output"
}

normalize_control_render() {
  sed -E \
    -e '/^[[:space:]]*helm\.sh\/chart:/d' \
    -e '/^[[:space:]]*app\.kubernetes\.io\/version:/d' \
    -e '/^[[:space:]]*image: .*@(sha256:)?[a-f0-9]{64}"?$/d' \
    "$1"
}

plan_release() {
  local current_tag_value="$1"
  local candidate_tag="$2"
  local current_kit="$3"
  local candidate_kit="$4"
  local current_charts="$5"
  local candidate_charts="$6"

  local terraform_dir="${candidate_kit}/infra/aws-central"
  terraform -chdir="$terraform_dir" init -input=false -reconfigure \
    -backend-config="$TERRAFORM_BACKEND_CONFIG" >/dev/null
  local plan_file="${WORK_DIR}/candidate.tfplan"
  set +e
  terraform -chdir="$terraform_dir" plan -input=false -lock-timeout=5m \
    -detailed-exitcode -var-file="$TERRAFORM_VARS" -out="$plan_file" >/dev/null
  local plan_exit=$?
  set -e
  if (( plan_exit == 2 )); then
    terraform -chdir="$terraform_dir" show -json "$plan_file" |
      jq '{
        automatic_reconciliation: "stopped",
        reason: "terraform_change_requires_installation_agent",
        actions: [.resource_changes[]? | {
          address,
          actions: .change.actions
        }]
      }'
    return 20
  fi
  (( plan_exit == 0 )) || {
    echo "Terraform planning failed" >&2
    return "$plan_exit"
  }

  local current_render="${WORK_DIR}/current-control.yaml"
  local candidate_render="${WORK_DIR}/candidate-control.yaml"
  render_control "$current_tag_value" "$current_kit" "$current_charts" "$current_render"
  render_control "$candidate_tag" "$candidate_kit" "$candidate_charts" "$candidate_render"
  diff -u \
    <(normalize_control_render "$current_render") \
    <(normalize_control_render "$candidate_render") >/dev/null || {
      echo "automatic policy stopped on a rendered control-plane change beyond signed image digests/release labels" >&2
      return 21
    }

  local candidate_version="${candidate_tag#v}"
  local admission_args=(
    --namespace "$NAMESPACE"
    --values "${candidate_kit}/values/admission.yaml"
    --set-string "policy.signerSubjects[0]=$(release_identity "$current_tag_value")"
  )
  if [[ -n "$PRIVATE_ADMISSION_VALUES" ]]; then
    admission_args+=(--values "$PRIVATE_ADMISSION_VALUES")
  fi
  helm template "$ADMISSION_RELEASE" \
    "${candidate_charts}/sddp-admission-${candidate_version}.tgz" \
    "${admission_args[@]}" >"${WORK_DIR}/candidate-admission.yaml"
  ! grep -q 'REPLACE_' "${WORK_DIR}/candidate-admission.yaml"
  grep -Fq "$(release_identity "$current_tag_value")" "${WORK_DIR}/candidate-admission.yaml"
  grep -Fq "$(release_identity "$candidate_tag")" "${WORK_DIR}/candidate-admission.yaml"

  jq -n \
    --arg current "$current_tag_value" \
    --arg candidate "$candidate_tag" \
    --arg source_commit "$(jq -er '.source.commit' "${candidate_kit}/release-manifest.json")" \
    --arg manifest_sha256 "$(sha256sum "${candidate_kit}/release-manifest.json" | awk '{print $1}')" \
    '{
      status: "automatic_policy_passed",
      current_release: $current,
      candidate_release: $candidate,
      source_commit: $source_commit,
      release_manifest_sha256: $manifest_sha256,
      terraform_changes: 0,
      admission_signers: [$current, $candidate]
    }'
}

validate_database() {
  local database_json
  database_json="$(
    aws rds describe-db-instances \
      --db-instance-identifier "$RDS_INSTANCE_ID" \
      --output json
  )"
  jq -e '
    .DBInstances | length == 1 and
    .[0].DBInstanceStatus == "available" and
    .[0].MultiAZ == false and
    (.[0].PendingModifiedValues | length == 0)
  ' <<<"$database_json" >/dev/null || {
    echo "RDS is not the approved available Single-AZ instance or has pending modifications" >&2
    return 1
  }
  if [[ -n "$EXPECTED_DB_CLASS" ]]; then
    jq -e --arg class "$EXPECTED_DB_CLASS" \
      '.DBInstances[0].DBInstanceClass == $class' <<<"$database_json" >/dev/null || {
      echo "RDS class differs from ORE_HEAPHOUND_EXPECTED_DB_CLASS" >&2
      return 1
    }
  fi
}

apply_release() {
  local current_tag_value="$1"
  local candidate_tag="$2"
  local current_kit="$3"
  local candidate_kit="$4"
  local candidate_charts="$5"
  local candidate_version="${candidate_tag#v}"

  validate_database
  local snapshot_id
  snapshot_id="ore-heaphound-pre-${candidate_version//./-}-$(date -u +%Y%m%d%H%M%S)"
  aws rds create-db-snapshot \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot_id"

  local admission_args=(
    --namespace "$NAMESPACE"
    --create-namespace
    --values "${candidate_kit}/values/admission.yaml"
    --set-string "policy.signerSubjects[0]=$(release_identity "$current_tag_value")"
    --atomic
    --timeout 10m
  )
  if [[ -n "$PRIVATE_ADMISSION_VALUES" ]]; then
    admission_args+=(--values "$PRIVATE_ADMISSION_VALUES")
  fi
  helm upgrade --install "$ADMISSION_RELEASE" \
    "${candidate_charts}/sddp-admission-${candidate_version}.tgz" \
    "${admission_args[@]}"

  local current_image candidate_image
  current_image="$(jq -er '.images[] | select(.component == "application") | .reference + "@" + .digest' "${current_kit}/release-manifest.json")"
  candidate_image="$(jq -er '.images[] | select(.component == "application") | .reference + "@" + .digest' "${candidate_kit}/release-manifest.json")"
  kubectl run ore-heaphound-current-release-probe \
    --namespace "$NAMESPACE" --image "$current_image" --restart Never \
    --dry-run=server --output yaml >/dev/null
  kubectl run ore-heaphound-candidate-release-probe \
    --namespace "$NAMESPACE" --image "$candidate_image" --restart Never \
    --dry-run=server --output yaml >/dev/null

  local control_args=()
  while IFS= read -r value; do control_args+=("$value"); done < <(image_overrides "$candidate_kit")
  helm upgrade --install "$CONTROL_RELEASE" \
    "${candidate_charts}/sddp-${candidate_version}.tgz" \
    --namespace "$NAMESPACE" \
    --values "${candidate_kit}/values/central-eks.yaml" \
    --values "$PRIVATE_VALUES" \
    "${control_args[@]}" \
    --atomic --timeout "$TIMEOUT"

  kubectl rollout status deployment \
    --namespace "$NAMESPACE" \
    --selector "app.kubernetes.io/instance=${CONTROL_RELEASE}" \
    --timeout "$TIMEOUT"
  [[ "$(current_tag)" == "$candidate_tag" ]] || {
    echo "Helm did not report the candidate release after rollout" >&2
    return 1
  }
  if [[ -n "$HEALTH_URL" ]]; then
    curl --fail --silent --show-error --location --max-time 15 \
      "$HEALTH_URL" >/dev/null
  fi

  local report_tmp="${STATE_DIR}/last-success.json.tmp"
  jq -n \
    --arg previous "$current_tag_value" \
    --arg current "$candidate_tag" \
    --arg snapshot "$snapshot_id" \
    --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manifest_sha256 "$(sha256sum "${candidate_kit}/release-manifest.json" | awk '{print $1}')" \
    '{
      status: "succeeded",
      previous_release: $previous,
      current_release: $current,
      database_snapshot: $snapshot,
      completed_at: $completed_at,
      release_manifest_sha256: $manifest_sha256
    }' >"$report_tmp"
  chmod 0600 "$report_tmp"
  mv "$report_tmp" "${STATE_DIR}/last-success.json"
}

if [[ "$MODE" == "apply" ]]; then
  LOCK_DIR="${STATE_DIR}/active.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || {
    echo "another reconciliation is active; remove only a proven-stale lock under operator review: $LOCK_DIR" >&2
    exit 1
  }
fi

readonly CURRENT_TAG="$(current_tag)"
readonly CANDIDATE_TAG="$(latest_tag)"
prove_annotated_public_tag "$CANDIDATE_TAG"

if [[ "$CURRENT_TAG" == "$CANDIDATE_TAG" ]]; then
  jq -n --arg release "$CURRENT_TAG" '{status:"current", release:$release}'
  exit 0
fi
candidate_is_newer "$CURRENT_TAG" "$CANDIDATE_TAG" >/dev/null || {
  echo "release channel candidate is not newer than the deployed release" >&2
  exit 1
}

download_kit "$CURRENT_TAG" "${WORK_DIR}/current"
download_kit "$CANDIDATE_TAG" "${WORK_DIR}/candidate"
readonly CURRENT_KIT="${WORK_DIR}/current/customer-deploy"
readonly CANDIDATE_KIT="${WORK_DIR}/candidate/customer-deploy"
verify_kit "$CURRENT_TAG" "$CURRENT_KIT"
verify_kit "$CANDIDATE_TAG" "$CANDIDATE_KIT"
compare_release_posture "$CURRENT_KIT" "$CANDIDATE_KIT"

if [[ "$MODE" == "check" ]]; then
  jq -n \
    --arg current "$CURRENT_TAG" \
    --arg candidate "$CANDIDATE_TAG" \
    '{status:"verified_candidate_available", current_release:$current, candidate_release:$candidate}'
  exit 0
fi

readonly CURRENT_CHARTS="${WORK_DIR}/current-charts"
readonly CANDIDATE_CHARTS="${WORK_DIR}/candidate-charts"
prepare_charts "$CURRENT_TAG" "$CURRENT_KIT" "$CURRENT_CHARTS"
prepare_charts "$CANDIDATE_TAG" "$CANDIDATE_KIT" "$CANDIDATE_CHARTS"
plan_release \
  "$CURRENT_TAG" "$CANDIDATE_TAG" \
  "$CURRENT_KIT" "$CANDIDATE_KIT" \
  "$CURRENT_CHARTS" "$CANDIDATE_CHARTS"

if [[ "$MODE" == "apply" ]]; then
  apply_release \
    "$CURRENT_TAG" "$CANDIDATE_TAG" \
    "$CURRENT_KIT" "$CANDIDATE_KIT" "$CANDIDATE_CHARTS"
fi
