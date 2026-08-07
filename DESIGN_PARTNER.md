# Design-partner deployment

This is the shortest supported path to a working Ore Heaphound installation for
a design partner evaluating the product on their own data, **including governed
remediation**.

It does not replace [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) — that
runbook is still the authoritative install procedure and the LLM deployment
agent should follow it. This document adds the three things a design-partner
engagement needs on top of it:

1. the remediation infrastructure and values that the base runbook leaves out;
2. the end-to-end walkthrough the partner actually performs; and
3. the scope statement to put in front of the partner in writing.

---

## 1. What this deployment is, and is not

Say this to the partner before they connect anything. It is all verifiable in
the repository, and getting it wrong is worse than under-promising.

**It is:**

- a single-tenant install running entirely in the partner's own AWS account —
  Rapticore hosts nothing and receives no data, findings, or credentials;
- read-only against their sources by default, with source mutation on a
  separate identity that only exists if they enable remediation;
- evidence-producing: every scan yields an immutable manifest and a signed
  report bundle that verifies offline with `verifier-cli`, without our API.

**It is not:**

- **quality-qualified.** The shipped detector bundle is `not_qualified`
  (`release/detector-bundles/production-v1.json`). Detection is gated by a
  synthetic regression corpus, not by a measured accuracy estimate against
  real-world data. Measuring that is a large part of what the partnership is
  for; do not present finding counts as an accuracy claim.
- **a compliance determination.** The HIPAA Safe Harbor view reports which of
  the 18 identifiers were detected and remediated and what coverage remains. It
  surfaces inputs for the covered entity or their expert. It does not assert
  de-identification.
- **medical-imaging capable.** No DICOM de-identification. Do not route DICOM
  through OCR and describe the result as de-identified.
- **an unrestricted source-value browser.** Production verification is a
  dedicated source-read workload, not the ordinary control-plane API. An
  authorized admin or analyst receives a 60-second, single-use, actor-and-group
  bound grant for at most three values by default (hard ceiling ten). Responses
  are audited and `no-store`; values still exist transiently in the authorized
  browser and must be handled accordingly.

Coverage is always explicit: an asset that could not be parsed is reported as
`unsupported` or `partial`, never as clean.

---

## 2. What to collect from the partner

The base runbook's question set, plus these:

| Value | Notes |
|---|---|
| Source bucket ARNs | Exact buckets. Scan workers get versioned read only. |
| Source KMS key ARNs | Only if source objects use customer-managed keys. |
| Remediation in scope? | If no, keep `remediation_enabled = false` and omit `values/remediation-eks.yaml`. Nothing in the deployment can then write to a source. |
| Destination policy ID | Their versioned identifier for the encryption/retention/residency controls on the redacted bucket. Free-form string, bound into every approval. |
| Local-processing policy ID | Same idea, for the in-cluster model's isolation/retention posture. |
| Two approver identities | Destructive redaction needs two distinct approvers, neither of whom is the requester. Confirm two real people exist before install. |

---

## 3. Infrastructure

In `terraform.tfvars`:

```hcl
source_bucket_arns  = ["arn:aws:s3:::partner-source-bucket"]
remediation_enabled = true
remediation_rollback_retention_days = 7
```

`remediation_enabled = true` creates, in `remediation.tf`:

- `<name>-remediation-executor` — the write-scoped IRSA role, assumable only by
  the `sddp-remediation-executor` ServiceAccount in the workload namespace;
- `<name>-quarantine-<account>` — versioned, KMS-encrypted, public access
  blocked, and TLS-only. Holds the pre-change snapshot that makes rollback
  possible. Its lifecycle is an independent backstop that removes snapshots
  after `remediation_rollback_retention_days`;
- `<name>-redacted-<account>` — same posture. Holds redacted copies.

Both bucket policies reject an explicit non-KMS encryption mode or a KMS key
other than the deployment data key; omitting the header uses that same key as
the bucket default.

The executor policy is the only place in the deployment that grants
`s3:DeleteObject` or `s3:PutObject` on a source object, and it is scoped to the
exact `source_bucket_arns`. It also grants `s3:ListBucket` on only those bucket
ARNs so a post-delete `HeadObject` can distinguish an absent source (`404`)
from lost source authorization (`403`); remediation never calls `ListObjects`.
The control-plane and scan-worker policies are unchanged and remain read-only.

Take these four outputs forward:

```
terraform output -raw remediation_executor_role_arn
terraform output -raw quarantine_bucket
terraform output -raw redacted_bucket
terraform output -raw remediation_rollback_window
```

---

## 4. Values

Add `values/remediation-eks.yaml` after the base `values/central-eks.yaml`.
Keeping remediation in a separate overlay makes the default production install
genuinely read-only. Substitute:

| Placeholder | Source |
|---|---|
| `REPLACE_REMEDIATION_EXECUTOR_ROLE_ARN` | `remediation_executor_role_arn` |
| `REPLACE_QUARANTINE_BUCKET` | `quarantine_bucket` |
| `REPLACE_REDACTED_BUCKET` | `redacted_bucket` |
| `REPLACE_DATA_KMS_KEY_ARN` | `data_kms_key_arn` |
| `REPLACE_REMEDIATION_ROLLBACK_WINDOW` | `remediation_rollback_window` |
| `REPLACE_AWS_REGION` | Terraform `region` output |
| `REPLACE_MODEL` | pinned local model name from the release inventory |
| `REPLACE_MODEL_DIGEST` | verified local model digest |
| `REPLACE_DESTINATION_POLICY_ID` | partner-supplied |
| `REPLACE_LOCAL_PROCESSING_POLICY_ID` | partner-supplied |
| `REPLACE_REDACTION_VALIDATOR_VERSION` | `<model>@<digest>\|redaction-validator:v3` |

The chart **refuses to render** if the executor role ARN equals the
control-plane or scan-worker role. That check is deliberate: reusing the read
identity for writes silently breaks the read-only-discovery guarantee, and it is
the exact mistake a fast install makes. If you hit it, you pasted the wrong ARN —
do not work around it.

The executor also runs under its own database role, `sddp_executor`. It is
created and granted by the pre-install/pre-upgrade `db-prepare` Job from
`SDDP_EXECUTOR_ROLE_PASSWORD` / `SDDP_EXECUTOR_DATABASE_URL`, both generated by
`scripts/populate-operator-secret.sh` for a fresh installation. If the operator
secret predates this release, use the add-only
`scripts/upgrade-operator-secret-for-remediation.sh` command below. It preserves
all existing fields, uses an exact-version Secrets Manager promotion, and keeps
the previous secret version available for recovery. The executor verifies its
exact privilege set at startup and fails closed on drift — it cannot mutate
findings or evidence, and cannot read connector credentials.

```bash
scripts/upgrade-operator-secret-for-remediation.sh \
  "$(terraform -chdir=infra/aws-central output -raw region)" \
  "$(terraform -chdir=infra/aws-central output -raw database_endpoint)" \
  "$(terraform -chdir=infra/aws-central output -raw database_name)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_arn)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_kms_key_arn)"
```

The deployment principal running this one-time upgrade needs
`secretsmanager:GetSecretValue`, `secretsmanager:PutSecretValue`, and
`secretsmanager:UpdateSecretVersionStage` on the exact operator secret plus
decrypt/encrypt use of its exact KMS key. These permissions do not belong on any
application ServiceAccount.

Force an External Secrets reconciliation, then wait for both new keys to exist
in the Kubernetes Secret before running Helm. `Ready=True` alone is not enough:
it may describe the previously synchronized version during the normal one-hour
refresh interval.

```bash
kubectl -n sddp annotate externalsecret ore-heaphound-operator \
  force-sync="$(date +%s)" --overwrite
OPERATOR_KUBERNETES_SECRET="$(
  terraform -chdir=infra/aws-central output -raw operator_kubernetes_secret_name
)"
kubectl -n sddp wait \
  --for=jsonpath='{.data.SDDP_EXECUTOR_DATABASE_URL}' \
  "secret/${OPERATOR_KUBERNETES_SECRET}" --timeout=2m
kubectl -n sddp wait \
  --for=jsonpath='{.data.SDDP_EXECUTOR_ROLE_PASSWORD}' \
  "secret/${OPERATOR_KUBERNETES_SECRET}" --timeout=2m
unset OPERATOR_KUBERNETES_SECRET
```

These checks inspect only key presence, not secret values. Do not rerun the
one-time population helper against a populated secret.

Install order is unchanged: `db-prepare` → `sddp-admission` → `sddp`.
Render and install the control chart with both values files, in this order:

```bash
helm upgrade --install ore-heaphound "charts/sddp-${RELEASE_VERSION}.tgz" \
  --namespace sddp \
  -f values/central-eks.yaml \
  -f values/remediation-eks.yaml \
  --atomic --timeout 20m
```

---

## 5. Verify remediation is actually live

Before the partner touches it:

```bash
kubectl -n sddp get deploy ore-heaphound-sddp-remediation-executor
kubectl -n sddp logs deploy/ore-heaphound-sddp-remediation-executor | head -20
```

A healthy executor logs its verified privilege set. If it CrashLoops on the
database role, stop the rollout. Confirm the operator secret has both executor
keys, the ExternalSecret has synchronized the current version, and the
`db-prepare` Job completed. For a pre-existing secret, run the add-only upgrade
helper above; never overwrite the secret with the one-time population helper.

In the UI, `#/remediations` shows the executor as configured rather than the
"remediation is not configured" block.

---

## 6. The partner walkthrough

Roughly half a day. Each step produces evidence worth reviewing together.

1. **Connect a source** — `#/sources` → new S3 connector: bucket, region,
   optional key prefix, and a data category. Start with a prefix holding a few
   hundred objects, not the whole bucket.
2. **Scan** — `#/scans` → create and start. Watch coverage, not just findings:
   the split between processed / partial / unprocessed is the honest picture.
3. **Finalize the scan explicitly.** Scans do not auto-finalize. Finalizing
   freezes the immutable manifest — reports need it.
4. **Triage** — `#/triage`. Findings are grouped cross-scan by keyed evidence
   HMAC, so the same value in 200 objects is one row. Confirm or reject. Bulk
   disposition handles up to 200 groups per action, and it is explicitly not
   atomic — the UI warns and returns per-group failure codes.
5. **Remediate** — from a confirmed group, request remediation:
   - `redacted_copy` — writes a redacted copy, source untouched. **1 approval.**
   - `redacted_quarantine` — writes the copy *and* removes the original to
     quarantine. The recommended default. **2 approvals.**
   - `in_place` — overwrites the source, byte-faithful text only, snapshot
     first. **2 approvals.**
   - `quarantine` — moves the object out, no redaction. **1 approval.**

   The flow is always request → dry run → approve → execute. Approval is bound
   to the dry-run digest; if the object changes, approval is void and the
   request returns to `dry_run_pending`. The requester can never approve.

6. **Independently verify the redaction.** Re-scan the same scope. The
   executor's own success report is not proof; a fresh scan is. This is the
   single most valuable step for a design partner.
7. **Roll back one item.** Confirm the original is restored and the exact
   versioned redacted copy is removed. Rollback is available for the Terraform-
   bound `rollbackWindow` (seven days by default).
8. **Generate and verify a signed report** — `#/reports`, then verify offline:
   ```bash
   verifier-cli verify --bundle <downloaded>.tar --key <public-key>
   ```
   It re-checks signatures, hashes, the Merkle chain, coverage, and the HIPAA
   artifact from the bundle bytes and public key alone. Have the partner run it
   themselves — offline verifiability is much more convincing when they do.

---

## 7. Day-2 for the customer DevOps resource

This release ships telemetry but no alerting rules and no on-call automation.
Operating it during the engagement is a light manual duty:

- **Metrics**: `GET /metrics` on the API (reader token) exposes queue depth and
  age, dead letters, scan and work-unit states, remediation stage ages, and
  discovery retry backlog. CloudWatch Container Insights is installed by the
  add-on and collects pod metrics and logs.
- **Optional alert rules**: the chart carries a `PrometheusRule` covering dead
  letters, stuck remediation, overdue residual verification, and overdue
  discovery retry. It is off by default and needs a Prometheus Operator:
  `--set monitoring.prometheusRule.enabled=true`.
- **What to eyeball daily**: `sddp_queue_dead_letter` (should be 0),
  `sddp_remediation_oldest_active_age_seconds` (a stuck stage means an executor
  lease or provider problem), and the notification centre in the UI.
- **Backups**: RDS automated backups run at 35-day retention and the AWS Backup
  plan covers RDS and EFS. Restore has not been rehearsed in this account —
  do a restore drill into an isolated target during the engagement rather than
  discovering the gap later.
- **Rollback**: `helm rollback` for the control chart. Migrations run in the
  pre-install `db-prepare` Job; if it fails the release does not proceed, and
  the previous revision keeps running.

---

## 8. Closing out

At the end of the engagement, if the partner used a real source bucket:

- delete the quarantine and redacted buckets (they are versioned — remove
  noncurrent versions and delete markers, or deletion fails);
- destroy with `remediation_enabled = false` first if you want to prove the
  write identity is gone before tearing the rest down;
- remove the approver accounts or reset their passwords.

Quarantine holds real copies of the partner's sensitive originals. Treat those
buckets as in-scope data for whatever agreement covers the engagement.
