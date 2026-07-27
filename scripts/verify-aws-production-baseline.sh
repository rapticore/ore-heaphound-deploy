#!/usr/bin/env bash
set -euo pipefail

readonly REGION="${1:-}"
readonly EXPECTED_ACCOUNT_ID="${2:-}"
if [[ ! "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
  [[ ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "usage: $0 AWS_REGION EXPECTED_ACCOUNT_ID" >&2
  exit 2
fi

for command_name in aws jq; do
  command -v "$command_name" >/dev/null ||
    { echo "$command_name is required" >&2; exit 1; }
done

actual_account="$(
  aws sts get-caller-identity --region "$REGION" --query Account --output text
)"
[[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]] ||
  { echo "AWS account does not match the reviewed deployment account" >&2; exit 1; }

trails="$(aws cloudtrail describe-trails --region "$REGION" --include-shadow-trails --output json)"
cloudtrail=false
while IFS= read -r trail_arn; do
  [[ -n "$trail_arn" ]] || continue
  if [[ "$(aws cloudtrail get-trail-status --region "$REGION" --name "$trail_arn" --query IsLogging --output text)" == "True" ]]; then
    cloudtrail=true
    break
  fi
done < <(jq -r '.trailList[]?.TrailARN' <<<"$trails")

config=false
if aws configservice describe-configuration-recorder-status \
  --region "$REGION" --output json |
  jq -e 'any(.ConfigurationRecordersStatus[]?; .recording == true)' >/dev/null; then
  config=true
fi

guardduty=false
if aws guardduty list-detectors --region "$REGION" --output json |
  jq -e '.DetectorIds | length > 0' >/dev/null; then
  guardduty=true
fi

security_hub=false
if aws securityhub describe-hub --region "$REGION" --output json >/dev/null 2>&1; then
  security_hub=true
fi

jq -n \
  --argjson cloudtrail "$cloudtrail" \
  --argjson config "$config" \
  --argjson guardduty "$guardduty" \
  --argjson security_hub "$security_hub" \
  '{
    status: (if ($cloudtrail and $config and $guardduty and $security_hub) then "ready" else "incomplete" end),
    coverage: {
      cloudtrail_logging: $cloudtrail,
      config_recording: $config,
      guardduty_enabled: $guardduty,
      security_hub_enabled: $security_hub
    }
  }'

[[ "$cloudtrail" == true && "$config" == true && "$guardduty" == true && "$security_hub" == true ]]
