#!/usr/bin/env bash
set -euo pipefail

# Governed installation-agent repair lane for the control Helm chart.
#
# This helper does not alter a signed release. It derives a visibly different
# local repair chart from an exact signed control-chart package, proves that the
# application images and Helm hooks are unchanged, and records the source and
# rendered diffs needed to reconcile the repair into a new signed release.

usage() {
  echo "usage: $0 plan|apply|close <customer-config.env>" >&2
  exit 2
}

[[ $# == 2 ]] || usage
readonly MODE="$1"
readonly CONFIG="$2"
[[ "$MODE" == "plan" || "$MODE" == "apply" || "$MODE" == "close" ]] || usage
[[ -f "$CONFIG" ]] || {
  echo "customer configuration does not exist: $CONFIG" >&2
  exit 2
}

# This is customer-owned executable shell input. It must be permission-restricted
# and must never be committed to the release repository.
# shellcheck source=/dev/null
. "$CONFIG"

readonly BASE_CHART="${ORE_HEAPHOUND_BASE_CONTROL_CHART:-}"
readonly BASE_CHART_SHA256="${ORE_HEAPHOUND_BASE_CONTROL_CHART_SHA256:-}"
readonly BASE_RELEASE_TAG="${ORE_HEAPHOUND_BASE_RELEASE_TAG:-}"
readonly REPAIR_CHART_DIR="${ORE_HEAPHOUND_REPAIR_CONTROL_CHART_DIR:-}"
readonly RELEASE_VALUES="${ORE_HEAPHOUND_RELEASE_VALUES:-}"
readonly PRIVATE_VALUES="${ORE_HEAPHOUND_PRIVATE_VALUES:-}"
readonly STATE_DIR="${ORE_HEAPHOUND_RECONCILER_STATE_DIR:-}"
readonly BUNDLE_DIR="${ORE_HEAPHOUND_REPAIR_BUNDLE:-}"
readonly CHANGE_REF="${ORE_HEAPHOUND_REPAIR_CHANGE_REF:-}"
readonly NAMESPACE="${ORE_HEAPHOUND_NAMESPACE:-sddp}"
readonly CONTROL_RELEASE="${ORE_HEAPHOUND_CONTROL_RELEASE:-ore-heaphound}"
readonly EXPECTED_CURRENT_CHART="${ORE_HEAPHOUND_EXPECTED_CURRENT_CONTROL_CHART:-}"
readonly TIMEOUT="${ORE_HEAPHOUND_ROLLOUT_TIMEOUT:-30m}"
readonly APPLY_APPROVED="${ORE_HEAPHOUND_REPAIR_APPLY:-false}"
readonly APPROVED_SHA256="${ORE_HEAPHOUND_REPAIR_APPROVED_SHA256:-}"
readonly STACK_ON_ACTIVE="${ORE_HEAPHOUND_REPAIR_STACK_ON_ACTIVE:-false}"
readonly HEALTH_URL="${ORE_HEAPHOUND_HEALTH_URL:-}"
readonly CLOSE_APPROVED="${ORE_HEAPHOUND_REPAIR_CLOSE:-false}"
readonly RECONCILED_RELEASE="${ORE_HEAPHOUND_RECONCILED_RELEASE:-}"
readonly RECONCILED_SOURCE_COMMIT="${ORE_HEAPHOUND_RECONCILED_SOURCE_COMMIT:-}"
readonly RECONCILED_CHART="${ORE_HEAPHOUND_RECONCILED_CONTROL_CHART:-}"
readonly RECONCILED_CHART_SHA256="${ORE_HEAPHOUND_RECONCILED_CONTROL_CHART_SHA256:-}"
readonly ACTIVE_MARKER="${STATE_DIR}/active-helm-repair.json"

for command in helm jq sha256sum tar; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 2
  }
done

[[ "$STATE_DIR" == /* && -d "$STATE_DIR" ]] || {
  echo "ORE_HEAPHOUND_RECONCILER_STATE_DIR must be an existing absolute directory" >&2
  exit 2
}

require_absolute_file() {
  local label="$1"
  local path="$2"
  [[ "$path" == /* && -f "$path" ]] || {
    echo "$label must be an absolute existing file" >&2
    exit 2
  }
}

require_absolute_directory() {
  local label="$1"
  local path="$2"
  [[ "$path" == /* && -d "$path" ]] || {
    echo "$label must be an absolute existing directory" >&2
    exit 2
  }
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

values_args() {
  if [[ -n "$RELEASE_VALUES" ]]; then
    printf '%s\n' --values "$RELEASE_VALUES"
  fi
  printf '%s\n' --values "$PRIVATE_VALUES"
}

render_chart() {
  local chart="$1"
  local output="$2"
  local args=()
  while IFS= read -r value; do args+=("$value"); done < <(values_args)
  helm template "$CONTROL_RELEASE" "$chart" \
    --namespace "$NAMESPACE" \
    "${args[@]}" >"$output"
  if grep -q 'REPLACE_' "$output"; then
    echo "render contains an unresolved REPLACE_ placeholder" >&2
    return 1
  fi
}

normalize_render() {
  sed -E \
    -e '/^[[:space:]]*helm\.sh\/chart:/d' \
    -e '/^[[:space:]]*app\.kubernetes\.io\/version:/d' \
    "$1"
}

extract_images() {
  sed -n -E \
    's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' \
    "$1" | sort -u
}

extract_hooks() {
  awk '
    function flush() {
      if (document ~ /helm\.sh\/hook/) printf "%s---\n", document
      document=""
    }
    /^---$/ { flush(); next }
    { document=document $0 ORS }
    END { flush() }
  ' "$1"
}

wait_for_release_deployments() {
  local found=false resource
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    found=true
    kubectl --namespace "$NAMESPACE" rollout status "$resource" --timeout "$TIMEOUT"
  done < <(kubectl --namespace "$NAMESPACE" get deployment \
    --selector "app.kubernetes.io/instance=${CONTROL_RELEASE}" \
    --output name)
  [[ "$found" == "true" ]] || {
    echo "control release has no selected Deployments to verify" >&2
    return 1
  }
}

verify_bundle() {
  local bundle="$1"
  require_absolute_directory ORE_HEAPHOUND_REPAIR_BUNDLE "$bundle"
  for required in repair-record.json source.patch render.diff control-repair.tgz approval.sha256; do
    [[ -s "${bundle}/${required}" ]] || {
      echo "repair bundle is missing ${required}" >&2
      return 1
    }
  done

  local expected actual
  expected="$(jq -er '.artifacts.source_patch_sha256' "${bundle}/repair-record.json")"
  actual="$(sha256_file "${bundle}/source.patch")"
  [[ "$actual" == "$expected" ]] || {
    echo "repair source patch checksum mismatch" >&2
    return 1
  }
  expected="$(jq -er '.artifacts.chart_sha256' "${bundle}/repair-record.json")"
  actual="$(sha256_file "${bundle}/control-repair.tgz")"
  [[ "$actual" == "$expected" ]] || {
    echo "repair chart checksum mismatch" >&2
    return 1
  }
  expected="$(jq -er '.artifacts.render_diff_sha256' "${bundle}/repair-record.json")"
  actual="$(sha256_file "${bundle}/render.diff")"
  [[ "$actual" == "$expected" ]] || {
    echo "repair render diff checksum mismatch" >&2
    return 1
  }
  expected="$(tr -d '[:space:]' <"${bundle}/approval.sha256")"
  actual="$(sha256_file "${bundle}/repair-record.json")"
  [[ "$actual" == "$expected" ]] || {
    echo "repair approval record checksum mismatch" >&2
    return 1
  }
}

plan_repair() {
  require_absolute_file ORE_HEAPHOUND_BASE_CONTROL_CHART "$BASE_CHART"
  require_absolute_directory ORE_HEAPHOUND_REPAIR_CONTROL_CHART_DIR "$REPAIR_CHART_DIR"
  require_absolute_file ORE_HEAPHOUND_PRIVATE_VALUES "$PRIVATE_VALUES"
  [[ -z "$RELEASE_VALUES" ]] || require_absolute_file ORE_HEAPHOUND_RELEASE_VALUES "$RELEASE_VALUES"
  [[ "$BASE_CHART_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
    echo "ORE_HEAPHOUND_BASE_CONTROL_CHART_SHA256 must be the digest from the signed release manifest" >&2
    exit 2
  }
  [[ "$BASE_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "ORE_HEAPHOUND_BASE_RELEASE_TAG is invalid" >&2
    exit 2
  }
  [[ -n "$CHANGE_REF" && ${#CHANGE_REF} -le 200 ]] || {
    echo "ORE_HEAPHOUND_REPAIR_CHANGE_REF is required and must be at most 200 characters" >&2
    exit 2
  }
  [[ "$EXPECTED_CURRENT_CHART" =~ ^sddp-[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?([+_][0-9A-Za-z._-]+)?$ ]] || {
    echo "ORE_HEAPHOUND_EXPECTED_CURRENT_CONTROL_CHART must bind the plan to the current Helm chart" >&2
    exit 2
  }
  local parent_active=false parent_record_sha256=""
  if [[ -e "$ACTIVE_MARKER" ]]; then
    [[ "$STACK_ON_ACTIVE" == "true" ]] || {
      echo "an active Helm repair already exists; set ORE_HEAPHOUND_REPAIR_STACK_ON_ACTIVE=true to plan a recorded cumulative repair" >&2
      exit 1
    }
    jq -e --arg namespace "$NAMESPACE" --arg release "$CONTROL_RELEASE" \
      '.status == "active" and .target.namespace == $namespace and .target.helm_release == $release' \
      "$ACTIVE_MARKER" >/dev/null || {
      echo "active Helm repair marker is invalid or belongs to another target" >&2
      exit 1
    }
    [[ "$EXPECTED_CURRENT_CHART" == "$(jq -er '.applied_chart' "$ACTIVE_MARKER")" ]] || {
      echo "stacked repair must bind ORE_HEAPHOUND_EXPECTED_CURRENT_CONTROL_CHART to the active repair" >&2
      exit 1
    }
    [[ "$BASE_RELEASE_TAG" == "$(jq -er '.base_release' "$ACTIVE_MARKER")" ]] || {
      echo "stacked repair changed its signed base release" >&2
      exit 1
    }
    [[ "$BASE_CHART_SHA256" == "$(jq -er '.repair_chart.sha256' "$ACTIVE_MARKER")" ]] || {
      echo "stacked base chart digest does not match the active repair record" >&2
      exit 1
    }
    parent_active=true
    parent_record_sha256="$(sha256_file "$ACTIVE_MARKER")"
  fi
  [[ "$(sha256_file "$BASE_CHART")" == "$BASE_CHART_SHA256" ]] || {
    echo "base chart does not match its approved signed or active-repair digest" >&2
    exit 1
  }
  [[ -f "${REPAIR_CHART_DIR}/Chart.yaml" ]] || {
    echo "repair chart directory lacks Chart.yaml" >&2
    exit 2
  }
  if find "$REPAIR_CHART_DIR" -type l -print -quit | grep -q .; then
    echo "repair chart may not contain symbolic links" >&2
    exit 1
  fi

  umask 077
  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ore-heaphound-helm-repair.XXXXXX")"
  trap "rm -rf '$work_dir'" EXIT
  mkdir -p "${work_dir}/base" "${work_dir}/repair"
  tar -xzf "$BASE_CHART" -C "${work_dir}/base"

  local chart_name base_source
  chart_name="$(helm show chart "$BASE_CHART" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
  [[ "$chart_name" == "sddp" ]] || {
    echo "the governed repair lane accepts only the sddp control chart" >&2
    exit 1
  }
  base_source="${work_dir}/base/${chart_name}"
  [[ -d "$base_source" ]] || {
    echo "base chart archive layout is invalid" >&2
    exit 1
  }

  # A repair changes templates/defaults, not release identity or dependencies.
  # The helper supplies a distinct +repair version when it packages the chart.
  diff -u <(helm show chart "$BASE_CHART") <(helm show chart "$REPAIR_CHART_DIR") >/dev/null || {
    echo "repair must not edit Chart.yaml; the helper assigns a visible repair version" >&2
    exit 1
  }
  for protected in Chart.lock charts crds templates/migrations.yaml; do
    if [[ ! -e "${base_source}/${protected}" && ! -e "${REPAIR_CHART_DIR}/${protected}" ]]; then
      continue
    fi
    if [[ ! -e "${base_source}/${protected}" || ! -e "${REPAIR_CHART_DIR}/${protected}" ]] ||
        ! diff -qr "${base_source}/${protected}" "${REPAIR_CHART_DIR}/${protected}" >/dev/null 2>&1; then
      echo "repair changes protected chart content: ${protected}" >&2
      exit 1
    fi
  done

  cp -R "$REPAIR_CHART_DIR/." "${work_dir}/repair/${chart_name}/"
  local raw_patch="${work_dir}/source.patch"
  set +e
  diff -ruN "$base_source" "${work_dir}/repair/${chart_name}" >"$raw_patch"
  local diff_exit=$?
  set -e
  [[ $diff_exit -eq 1 && -s "$raw_patch" ]] || {
    echo "repair chart has no source change or could not be compared" >&2
    exit 1
  }

  # Rewrite temporary paths into a repository-applicable patch. The patch is
  # source-only; private values and rendered manifests remain customer-owned.
  sed \
    -e "s|${base_source}/|a/deploy/helm/sddp/|g" \
    -e "s|${work_dir}/repair/${chart_name}/|b/deploy/helm/sddp/|g" \
    "$raw_patch" >"${work_dir}/reconcile-source.patch"
  local patch_sha
  patch_sha="$(sha256_file "${work_dir}/reconcile-source.patch")"

  local base_version base_app_version repair_version
  base_version="$(helm show chart "$BASE_CHART" | sed -n 's/^version:[[:space:]]*//p' | head -n 1)"
  base_app_version="$(helm show chart "$BASE_CHART" | sed -n 's/^appVersion:[[:space:]]*//p' | head -n 1 | tr -d '"')"
  [[ -n "$base_version" && -n "$base_app_version" ]] || {
    echo "base chart metadata is incomplete" >&2
    exit 1
  }
  local signed_base_version="${BASE_RELEASE_TAG#v}" repair_id
  if [[ "$parent_active" == "true" ]]; then
    [[ "$base_version" == "${signed_base_version}+repair."* ]] || {
      echo "stacked base chart version is not derived from ORE_HEAPHOUND_BASE_RELEASE_TAG" >&2
      exit 1
    }
    repair_id="$(printf '%s:%s' "$parent_record_sha256" "$patch_sha" | sha256sum | awk '{print $1}')"
  else
    [[ "$base_version" == "$signed_base_version" ]] || {
      echo "base chart version does not match ORE_HEAPHOUND_BASE_RELEASE_TAG" >&2
      exit 1
    }
    repair_id="$patch_sha"
  fi
  repair_version="${signed_base_version}+repair.${repair_id:0:12}"

  local package_output repair_package
  package_output="$(helm package "${work_dir}/repair/${chart_name}" \
    --version "$repair_version" \
    --app-version "$base_app_version" \
    --destination "$work_dir")"
  repair_package="$(sed -n 's/^Successfully packaged chart and saved it to: //p' <<<"$package_output")"
  [[ -s "$repair_package" ]] || {
    echo "Helm did not produce the repair chart package" >&2
    exit 1
  }

  local args=()
  while IFS= read -r value; do args+=("$value"); done < <(values_args)
  helm lint "$repair_package" "${args[@]}" >/dev/null

  local base_render="${work_dir}/base-render.yaml"
  local repair_render="${work_dir}/repair-render.yaml"
  render_chart "$BASE_CHART" "$base_render"
  render_chart "$repair_package" "$repair_render"

  diff -u <(extract_images "$base_render") <(extract_images "$repair_render") >/dev/null || {
    echo "repair changes the signed runtime image inventory" >&2
    exit 1
  }
  diff -u \
    <(normalize_render "$base_render" | extract_hooks /dev/stdin) \
    <(normalize_render "$repair_render" | extract_hooks /dev/stdin) >/dev/null || {
    echo "repair changes Helm hooks or database preparation/migration behavior" >&2
    exit 1
  }

  local render_diff="${work_dir}/render.diff"
  set +e
  diff -u <(normalize_render "$base_render") <(normalize_render "$repair_render") >"$render_diff"
  diff_exit=$?
  set -e
  [[ $diff_exit -eq 1 && -s "$render_diff" ]] || {
    echo "repair produces no normalized manifest change" >&2
    exit 1
  }

  local bundle
  # A cumulative repair is identified by both its parent record and its source
  # patch. Using repair_id avoids colliding with an older bundle if the same
  # patch is ever applied on top of a different governed parent.
  bundle="${STATE_DIR}/helm-repair-${repair_id:0:12}"
  [[ ! -e "$bundle" ]] || {
    echo "repair bundle already exists: $bundle" >&2
    exit 1
  }
  mkdir "$bundle"
  cp "$repair_package" "${bundle}/control-repair.tgz"
  cp "${work_dir}/reconcile-source.patch" "${bundle}/source.patch"
  cp "$render_diff" "${bundle}/render.diff"

  jq -n \
    --arg base_release "$BASE_RELEASE_TAG" \
    --arg base_chart_sha256 "$BASE_CHART_SHA256" \
    --arg base_chart_version "$base_version" \
    --arg repair_chart_version "$repair_version" \
    --arg repair_chart_sha256 "$(sha256_file "${bundle}/control-repair.tgz")" \
    --arg source_patch_sha256 "$(sha256_file "${bundle}/source.patch")" \
    --arg base_render_sha256 "$(sha256_file "$base_render")" \
    --arg repair_render_sha256 "$(sha256_file "$repair_render")" \
    --arg render_diff_sha256 "$(sha256_file "${bundle}/render.diff")" \
    --arg change_ref "$CHANGE_REF" \
    --arg namespace "$NAMESPACE" \
    --arg helm_release "$CONTROL_RELEASE" \
    --arg expected_current_chart "$EXPECTED_CURRENT_CHART" \
    --argjson stacked_on_active "$parent_active" \
    --arg parent_active_record_sha256 "$parent_record_sha256" \
    --arg release_values_sha256 "$(if [[ -n "$RELEASE_VALUES" ]]; then sha256_file "$RELEASE_VALUES"; fi)" \
    --arg private_values_sha256 "$(sha256_file "$PRIVATE_VALUES")" \
    '{
      schema_version: 1,
      status: "planned",
      base_release: $base_release,
      base_chart: {version: $base_chart_version, sha256: $base_chart_sha256},
      repair_chart: {version: $repair_chart_version, sha256: $repair_chart_sha256},
      target: {
        namespace: $namespace,
        helm_release: $helm_release,
        expected_current_chart: $expected_current_chart
      },
      parent_repair: {
        stacked: $stacked_on_active,
        active_record_sha256: $parent_active_record_sha256
      },
      inputs: {
        release_values_sha256: $release_values_sha256,
        private_values_sha256: $private_values_sha256
      },
      change_reference: $change_ref,
      invariants: {
        exact_runtime_images_preserved: true,
        helm_hooks_preserved: true,
        chart_dependencies_preserved: true,
        migrations_preserved: true,
        admission_policy_unchanged: true,
        terraform_unchanged: true
      },
      artifacts: {
        chart_sha256: $repair_chart_sha256,
        source_patch_sha256: $source_patch_sha256,
        base_render_sha256: $base_render_sha256,
        repair_render_sha256: $repair_render_sha256,
        render_diff_sha256: $render_diff_sha256
      }
    }' >"${bundle}/repair-record.json"
  if [[ "$parent_active" == "true" ]]; then
    cp "$ACTIVE_MARKER" "${bundle}/parent-active-repair.json"
  fi
  sha256_file "${bundle}/repair-record.json" >"${bundle}/approval.sha256"
  chmod 0600 "${bundle}"/*

  rm -rf "$work_dir"
  trap - EXIT

  jq -n \
    --arg status planned \
    --arg bundle "$bundle" \
    --arg approval_sha256 "$(tr -d '[:space:]' <"${bundle}/approval.sha256")" \
    --arg repair_version "$repair_version" \
    '{status: $status, bundle: $bundle, approval_sha256: $approval_sha256, repair_chart_version: $repair_version}'
}

apply_repair() {
  command -v kubectl >/dev/null || {
    echo "required command is unavailable: kubectl" >&2
    exit 2
  }
  require_absolute_file ORE_HEAPHOUND_PRIVATE_VALUES "$PRIVATE_VALUES"
  [[ -z "$RELEASE_VALUES" ]] || require_absolute_file ORE_HEAPHOUND_RELEASE_VALUES "$RELEASE_VALUES"
  verify_bundle "$BUNDLE_DIR"
  [[ "$APPLY_APPROVED" == "true" ]] || {
    echo "apply requires ORE_HEAPHOUND_REPAIR_APPLY=true" >&2
    exit 1
  }
  [[ "$APPROVED_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
    echo "apply requires the exact ORE_HEAPHOUND_REPAIR_APPROVED_SHA256 from plan" >&2
    exit 2
  }
  [[ "$APPROVED_SHA256" == "$(tr -d '[:space:]' <"${BUNDLE_DIR}/approval.sha256")" ]] || {
    echo "repair approval digest does not match the planned bundle" >&2
    exit 1
  }
  local stacked parent_record_sha256
  stacked="$(jq -r '.parent_repair.stacked // false' "${BUNDLE_DIR}/repair-record.json")"
  parent_record_sha256="$(jq -r '.parent_repair.active_record_sha256 // ""' "${BUNDLE_DIR}/repair-record.json")"
  if [[ "$stacked" == "true" ]]; then
    [[ -s "$ACTIVE_MARKER" && -s "${BUNDLE_DIR}/parent-active-repair.json" ]] || {
      echo "stacked repair lost its active parent record" >&2
      exit 1
    }
    [[ "$(sha256_file "$ACTIVE_MARKER")" == "$parent_record_sha256" && \
        "$(sha256_file "${BUNDLE_DIR}/parent-active-repair.json")" == "$parent_record_sha256" ]] || {
      echo "active parent repair changed after the stacked plan was approved" >&2
      exit 1
    }
  else
    [[ ! -e "$ACTIVE_MARKER" ]] || {
      echo "an active Helm repair exists but this plan is not a recorded stack" >&2
      exit 1
    }
  fi

  local record_namespace record_release
  record_namespace="$(jq -er '.target.namespace' "${BUNDLE_DIR}/repair-record.json")"
  record_release="$(jq -er '.target.helm_release' "${BUNDLE_DIR}/repair-record.json")"
  [[ "$record_namespace" == "$NAMESPACE" && "$record_release" == "$CONTROL_RELEASE" ]] || {
    echo "repair bundle target differs from the configured production release" >&2
    exit 1
  }
  [[ "$(sha256_file "$PRIVATE_VALUES")" == \
      "$(jq -er '.inputs.private_values_sha256' "${BUNDLE_DIR}/repair-record.json")" ]] || {
    echo "private Helm values changed after the repair was approved" >&2
    exit 1
  }
  local planned_release_values_sha256
  planned_release_values_sha256="$(jq -er '.inputs.release_values_sha256' "${BUNDLE_DIR}/repair-record.json")"
  if [[ -n "$RELEASE_VALUES" ]]; then
    [[ "$(sha256_file "$RELEASE_VALUES")" == "$planned_release_values_sha256" ]] || {
      echo "released Helm values changed after the repair was approved" >&2
      exit 1
    }
  elif [[ -n "$planned_release_values_sha256" ]]; then
    echo "approved repair used a released Helm values file that is now absent" >&2
    exit 1
  fi

  local live_chart expected_current_chart
  live_chart="$(helm list --namespace "$NAMESPACE" --output json |
    jq -er --arg release "$CONTROL_RELEASE" \
      '[.[] | select(.name == $release) | .chart] | if length == 1 then .[0] else error("control release not found") end')"
  expected_current_chart="$(jq -er '.target.expected_current_chart' "${BUNDLE_DIR}/repair-record.json")"
  [[ "$live_chart" == "$expected_current_chart" ]] || {
    echo "live control chart changed after the repair was approved" >&2
    exit 1
  }

  local args=()
  while IFS= read -r value; do args+=("$value"); done < <(values_args)
  helm upgrade "$CONTROL_RELEASE" "${BUNDLE_DIR}/control-repair.tgz" \
    --namespace "$NAMESPACE" \
    "${args[@]}" \
    --atomic \
    --timeout "$TIMEOUT"
  wait_for_release_deployments
  if [[ -n "$HEALTH_URL" ]]; then
    command -v curl >/dev/null || {
      echo "required command is unavailable: curl" >&2
      exit 2
    }
    curl --fail --silent --show-error --max-time 15 "$HEALTH_URL" >/dev/null
  fi

  local helm_release_json helm_revision live_repair_chart repair_version
  helm_release_json="$(helm list --namespace "$NAMESPACE" --output json |
    jq -ec --arg release "$CONTROL_RELEASE" \
      '[.[] | select(.name == $release)] | if length == 1 then .[0] else error("control release not found") end')"
  helm_revision="$(jq -er '.revision' <<<"$helm_release_json")"
  live_repair_chart="$(jq -er '.chart' <<<"$helm_release_json")"
  repair_version="$(jq -er '.repair_chart.version' "${BUNDLE_DIR}/repair-record.json")"
  [[ "$live_repair_chart" == "sddp-${repair_version}" ||
      "$live_repair_chart" == "sddp-${repair_version//+/_}" ]] || {
    echo "Helm did not record the approved repair chart version" >&2
    exit 1
  }
  jq \
    --arg status active \
    --argjson helm_revision "$helm_revision" \
    --arg applied_record_sha256 "$APPROVED_SHA256" \
    --arg applied_chart "$live_repair_chart" \
    '.status = $status |
     .applied_helm_revision = $helm_revision |
     .applied_chart = $applied_chart |
     .applied_record_sha256 = $applied_record_sha256' \
    "${BUNDLE_DIR}/repair-record.json" >"$ACTIVE_MARKER"
  chmod 0600 "$ACTIVE_MARKER"
  jq '{status, base_release, repair_chart, target, change_reference, applied_helm_revision}' "$ACTIVE_MARKER"
}

close_repair() {
  command -v kubectl >/dev/null || {
    echo "required command is unavailable: kubectl" >&2
    exit 2
  }
  [[ "$CLOSE_APPROVED" == "true" ]] || {
    echo "close requires ORE_HEAPHOUND_REPAIR_CLOSE=true" >&2
    exit 1
  }
  [[ -s "$ACTIVE_MARKER" ]] || {
    echo "there is no active Helm repair to close" >&2
    exit 1
  }
  [[ "$RECONCILED_RELEASE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "ORE_HEAPHOUND_RECONCILED_RELEASE must name the new signed release" >&2
    exit 2
  }
  [[ "$RECONCILED_SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]] || {
    echo "ORE_HEAPHOUND_RECONCILED_SOURCE_COMMIT must name its exact source commit" >&2
    exit 2
  }
  require_absolute_file ORE_HEAPHOUND_RECONCILED_CONTROL_CHART "$RECONCILED_CHART"
  [[ "$RECONCILED_CHART_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
    echo "ORE_HEAPHOUND_RECONCILED_CONTROL_CHART_SHA256 must come from the signed release manifest" >&2
    exit 2
  }
  [[ "$(sha256_file "$RECONCILED_CHART")" == "$RECONCILED_CHART_SHA256" ]] || {
    echo "reconciled chart does not match the signed release-manifest digest" >&2
    exit 1
  }
  [[ "$(helm show chart "$RECONCILED_CHART" | sed -n 's/^version:[[:space:]]*//p' | head -n 1)" == \
      "${RECONCILED_RELEASE#v}" ]] || {
    echo "reconciled chart version does not match ORE_HEAPHOUND_RECONCILED_RELEASE" >&2
    exit 1
  }

  local live_chart expected_chart
  live_chart="$(helm list --namespace "$NAMESPACE" --output json |
    jq -er --arg release "$CONTROL_RELEASE" \
      '[.[] | select(.name == $release) | .chart] | if length == 1 then .[0] else error("control release not found") end')"
  expected_chart="sddp-${RECONCILED_RELEASE#v}"
  [[ "$live_chart" == "$expected_chart" && "$live_chart" != *+repair.* ]] || {
    echo "live control release is not the declared reconciled signed chart" >&2
    exit 1
  }
  wait_for_release_deployments
  if [[ -n "$HEALTH_URL" ]]; then
    curl --fail --silent --show-error --max-time 15 "$HEALTH_URL" >/dev/null
  fi

  umask 077
  local history_dir repair_id closed_record
  history_dir="${STATE_DIR}/helm-repair-history"
  mkdir -p "$history_dir"
  repair_id="$(jq -er '.repair_chart.version' "$ACTIVE_MARKER" | tr -d '\n' | tr -c 'A-Za-z0-9._+-' '_')"
  closed_record="${history_dir}/${repair_id}.json"
  [[ ! -e "$closed_record" ]] || {
    echo "closed repair record already exists: $closed_record" >&2
    exit 1
  }
  jq \
    --arg status reconciled \
    --arg release "$RECONCILED_RELEASE" \
    --arg source_commit "$RECONCILED_SOURCE_COMMIT" \
    '.status = $status |
     .reconciled_release = $release |
     .reconciled_source_commit = $source_commit' \
    "$ACTIVE_MARKER" >"$closed_record"
  chmod 0600 "$closed_record"
  mv "$ACTIVE_MARKER" "${closed_record}.active-record"
  jq '{status, repair_chart, reconciled_release, reconciled_source_commit}' "$closed_record"
}

case "$MODE" in
  plan) plan_repair ;;
  apply) apply_repair ;;
  close) close_repair ;;
esac
