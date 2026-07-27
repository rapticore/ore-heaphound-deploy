#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-}"
readonly REGION="${2:-}"
readonly EXPECTED_ACCOUNT_ID="${3:-}"
readonly CERTIFICATE_ARN="${4:-}"
readonly HOSTNAME="${5%.}"
readonly NLB_DNS_NAME="${6%.}"

if [[ "$MODE" != "check" && "$MODE" != "apply" ]] ||
  [[ ! "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
  [[ ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] ||
  [[ ! "$CERTIFICATE_ARN" =~ ^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/[0-9a-f-]+$ ]] ||
  [[ ! "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] ||
  [[ "$NLB_DNS_NAME" != *".elb.${REGION}.amazonaws.com" ]]; then
  echo "usage: $0 check|apply AWS_REGION EXPECTED_ACCOUNT_ID ACM_CERTIFICATE_ARN HOSTNAME NLB_DNS_NAME" >&2
  exit 2
fi

for command_name in aws jq; do
  command -v "$command_name" >/dev/null ||
    { echo "$command_name is required" >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_command=(shasum -a 256)
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

actual_account="$(
  aws sts get-caller-identity --region "$REGION" --query Account --output text
)"
[[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]] ||
  { echo "AWS account does not match the reviewed deployment account" >&2; exit 1; }

IFS=: read -r _ _ _ certificate_region certificate_account _ <<<"$CERTIFICATE_ARN"
if [[ "$certificate_region" != "$REGION" || "$certificate_account" != "$EXPECTED_ACCOUNT_ID" ]]; then
  echo "the ACM certificate does not belong to the reviewed account and Region" >&2
  exit 1
fi

load_balancers="$(
  aws elbv2 describe-load-balancers --region "$REGION" --output json
)"
if ! jq -e --arg dns "$NLB_DNS_NAME" '
  any(
    .LoadBalancers[];
    .DNSName == $dns and
    .Type == "network" and
    .Scheme == "internet-facing" and
    .State.Code == "active"
  )
' <<<"$load_balancers" >/dev/null; then
  echo "the requested DNS target is not an active internet-facing NLB in the reviewed account and Region" >&2
  exit 1
fi

certificate="$(
  aws acm describe-certificate \
    --region "$REGION" \
    --certificate-arn "$CERTIFICATE_ARN" \
    --output json
)"
if ! jq -e --arg host "$HOSTNAME" '
  .Certificate.Status == "ISSUED" and
  any(
    ([.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // []))[];
    . as $domain |
    $domain == $host or
    (
      ($domain | startswith("*.")) and
      (($domain | ltrimstr("*.")) as $suffix |
        ($host | endswith("." + $suffix)) and
        (($host | rtrimstr("." + $suffix) | contains(".")) | not)
      )
    )
  )
' <<<"$certificate" >/dev/null; then
  echo "the ACM certificate is not issued for the requested hostname" >&2
  exit 1
fi

validation_record="$(
  jq -cer --arg host "$HOSTNAME" '
    def covers($domain; $requested):
      $domain == $requested or
      (
        ($domain | startswith("*.")) and
        (($domain | ltrimstr("*.")) as $suffix |
          ($requested | endswith("." + $suffix)) and
          (($requested | rtrimstr("." + $suffix) | contains(".")) | not)
        )
      );
    [
      .Certificate.DomainValidationOptions[]
      | select(covers(.DomainName; $host))
      | .ResourceRecord
      | select(.Name != null and .Value != null and .Type == "CNAME")
    ]
    | first
  ' <<<"$certificate"
)"
validation_name="$(jq -er '.Name' <<<"$validation_record")"
validation_value="$(jq -er '.Value' <<<"$validation_record")"
[[ "$validation_name" == _* && "$validation_value" == _*".acm-validations.aws." ]] ||
  { echo "the ACM certificate has no usable DNS validation record" >&2; exit 1; }

zone="$(
  aws route53 list-hosted-zones --output json |
    jq -er --arg host "$HOSTNAME" '
      [
        .HostedZones[]
        | select(.Config.PrivateZone == false)
        | . + {dns_name: (.Name | rtrimstr("."))}
        | .dns_name as $zone_name
        | select($host == $zone_name or ($host | endswith("." + $zone_name)))
      ]
      | sort_by(.dns_name | length)
      | last
    '
)"
zone_id="$(jq -er '.Id' <<<"$zone")"
zone_name="$(jq -er '.dns_name' <<<"$zone")"
if [[ "$HOSTNAME" == "$zone_name" ]]; then
  echo "the public application hostname must not be the Route 53 zone apex because this helper creates a CNAME" >&2
  exit 1
fi

change_batch="$(
  jq -cn \
    --arg host "${HOSTNAME}." \
    --arg nlb "${NLB_DNS_NAME}." \
    --arg validation_name "$validation_name" \
    --arg validation_value "$validation_value" '
      {
        Comment: "Ore HeapHound released TLS endpoint and ACM renewal validation",
        Changes: [
          {
            Action: "UPSERT",
            ResourceRecordSet: {
              Name: $host,
              Type: "CNAME",
              TTL: 300,
              ResourceRecords: [{Value: $nlb}]
            }
          },
          {
            Action: "UPSERT",
            ResourceRecordSet: {
              Name: $validation_name,
              Type: "CNAME",
              TTL: 300,
              ResourceRecords: [{Value: $validation_value}]
            }
          }
        ]
      }
    '
)"
payload_sha256="sha256:$(printf '%s' "$change_batch" | "${sha256_command[@]}" | awk '{print $1}')"

if [[ "$MODE" == "check" ]]; then
  jq -n \
    --arg status ready-for-approval \
    --arg zone_id "$zone_id" \
    --arg hostname "$HOSTNAME" \
    --arg nlb_dns_name "$NLB_DNS_NAME" \
    --arg certificate_arn "$CERTIFICATE_ARN" \
    --arg payload_sha256 "$payload_sha256" \
    --argjson changes "$change_batch" \
    '{
      status: $status,
      zone_id: $zone_id,
      hostname: $hostname,
      nlb_dns_name: $nlb_dns_name,
      certificate_arn: $certificate_arn,
      payload_sha256: $payload_sha256,
      change_batch: $changes
    }'
  exit 0
fi

if [[ "${ORE_HEAPHOUND_DEPLOYMENT_APPROVED:-}" != "true" ]] ||
  [[ "${ORE_HEAPHOUND_APPROVED_DNS_SHA256:-}" != "$payload_sha256" ]]; then
  echo "apply requires the consolidated deployment approval and exact reviewed DNS payload digest" >&2
  exit 1
fi

change_id="$(
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "$change_batch" \
    --query ChangeInfo.Id \
    --output text
)"
aws route53 wait resource-record-sets-changed --id "$change_id"

jq -n \
  --arg status ready \
  --arg hostname "$HOSTNAME" \
  --arg payload_sha256 "$payload_sha256" \
  '{status: $status, hostname: $hostname, payload_sha256: $payload_sha256}'
