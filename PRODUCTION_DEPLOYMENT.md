# Production deployment agent runbook

This is the production-oriented AWS/EKS path for the next immutable Ore
HeapHound release. It is designed for an LLM deployment agent acting in a
customer-owned account. The agent asks for the few values a customer actually
knows, performs read-only discovery, presents one consolidated change packet,
and then completes the approved deployment without requesting permission for
each routine step.

The specifically authorized `v0.1.0-develop.23.4` upgrade is governed by
[`DEPLOYMENT_AGENT_V23_4.md`](DEPLOYMENT_AGENT_V23_4.md). Its explicit
no-snapshot policy and bounded multi-chart repair authority take precedence
over generic snapshot and control-chart-only language in this runbook for that
exact rollout. Because the automatic reconciler's `apply` mode creates a
snapshot, the `.23.4` directive requires an agent-managed execution.

The next `develop` prerelease is a qualification candidate, not a stable
production release. Promote it to a stable signed tag only after its exact
artifacts have all required qualification receipts. Never relabel or modify a
published tag.

## Ask the customer once

Ask only for:

1. the AWS profile or credential source and expected 12-digit account ID;
2. the target Region (default `us-west-2`);
3. the deployment name, or permission to choose an available default;
4. the exact S3 source bucket and optional source KMS key;
5. the administrator/EKS and public-web CIDRs;
6. the public hostname, if public web access is wanted; and
7. either an issued ACM certificate ARN covering that hostname or permission
   to stop while the customer obtains one.

Choose safe names automatically when invited to do so. Before choosing, query
AWS for collisions. Do not ask the customer to edit YAML, calculate digests,
select controller versions, accept a model license, or approve each phase.

## Phase A: read-only decision packet

Use a new temporary workspace and the exact signed tag. Verify the release
manifest, signatures, chart packages, image platforms, SLSA provenance, SPDX
SBOM attestations, locked prerequisites, and detector/model coordinates.

Then:

1. verify the AWS identity and target Region;
2. run `verify-aws-production-baseline.sh` to prove active CloudTrail, Config,
   GuardDuty, and Security Hub coverage without taking ownership of
   organization-level services;
3. run `ensure-spot-service-linked-role.sh check`;
4. create fresh Terraform plans and render both released charts;
5. verify the plan has no unreviewed delete or replacement;
6. verify the rendered control chart includes:
   - namespace default-deny policies and explicit flows;
   - PDBs and hostname/zone topology spreading;
   - the managed TLS NLB Service with restricted source ranges, TLS 1.2+,
     access logs, cross-zone balancing, and deletion protection;
   - HSTS enabled by the HTTPS `web.baseURL`;
   - RDS `verify-full` plus the packaged AWS root bundle;
   - namespace-qualified KEDA metrics URLs;
   - writable RAM-backed Kingfisher `HOME`/`TMPDIR`;
   - read-only model mounts; and
   - digest-bound images.
7. if public access is selected, bind the packet to the exact hostname,
   certificate ARN, public zone, source CIDRs, and released managed-Service
   name. An existing managed NLB can also bind the DNS payload digest now. On
   a fresh install the NLB hostname is not available until after apply; the
   approved packet therefore covers only the deterministic payload produced
   later by the released helper for those exact bound inputs.

Present one packet containing the Terraform plan digest, Helm package and
render digests, Spot-role outcome, DNS intent (and payload when already
available), estimated monthly cost, tests to run, and rollback/decommission
actions. Ask once:

> Do you approve this exact deployment packet, including its listed
> infrastructure, workload, DNS, validation, and cleanup actions?

Record that answer as the consolidated deployment approval. It covers only the
exact reviewed packet. A changed plan or payload needs a new packet.

## Approved execution

After approval:

1. apply the exact saved infrastructure plan. If remediation redaction is
   enabled, the infrastructure phase must complete before the control chart:
   every Karpenter `NodePool` template with
   `rapticore.io/workload=scan` must carry
   `rapticore.io/scratch-capacity-policy=aws-central-karpenter-encrypted-root-v1`,
   and its referenced `EC2NodeClass` must still provision an encrypted 100 GiB
   root volume. Verify the live templates after the apply. Do not manually
   label existing Nodes; that is neither durable nor evidence that replacement
   capacity is qualified. Before Helm, schedule a bounded canary using an
   already-admitted, digest-pinned application image with the same two node
   selectors, scan toleration, and 60 GiB ephemeral-storage request as the
   remediation executor. Require the canary's Node to become `Ready` with the
   exact capacity-policy label, then remove the canary. If the saved plan
   contains anything beyond the
   reviewed NodePool-label update for this prerequisite, stop for a new
   approval. The unattended reconciler intentionally stops on this Terraform
   difference and must not run Helm first;
2. run the Spot helper in `apply` mode with
   `ORE_HEAPHOUND_DEPLOYMENT_APPROVED=true`;
3. populate the empty operator secret with the released non-echoing helper;
4. stage the exact model only when the selected detector profile uses it;
5. install the admission chart atomically, then prove a signed image is
   admitted and unsigned/wrong-identity images are denied;
6. install the control chart atomically;
7. wait for deployments, PDBs, policies, ExternalSecret, RDS, EFS, add-ons,
   controllers, the locked CloudWatch Observability agents, and NLB targets to
   become healthy;
8. obtain the NLB hostname from the released managed Service, run
   `reconcile-public-dns.sh check`, and verify that the result names only the
   approved account, Region, hostname, certificate, public zone, and that
   active managed NLB. Set `ORE_HEAPHOUND_APPROVED_DNS_SHA256` to the helper's
   resulting digest and run `reconcile-public-dns.sh apply` under the
   consolidated approval; do not ask again for this deterministic approved
   step;
9. validate strict TLS through the public hostname and confirm HSTS, source
   allow-list denial, access-log delivery, application health, MFA, and any
   configured SSO;
10. execute the released AWS S3 smoke against an exact object `VersionId`;
11. run scale-from-zero and Spot interruption tests; and
12. run RDS and EFS restore drills in isolated restore targets, recording
    recovery time and integrity evidence.

Do not treat license acceptance as a deployment gate. Model identity, digest,
source, and license metadata belong in release provenance and customer
documentation, not in a runtime permission ceremony.

## Automatic release reconciliation

Do not install an in-container updater, Watchtower, a floating image tag, or an
`imagePullPolicy: Always` substitute for release management. A HeapHound
release is one coordinated unit: Terraform, admission policy, charts, database
migrations, application and extraction images, detector manifest, and model
identity must advance together. Pulling only a newer container can create an
unsupported mixed release and bypass the saved-plan safety boundary.

An external customer-owned GitOps or installation agent may monitor the
requested signed release channel and reconcile automatically up to the approval
boundary. It must:

1. resolve a new immutable annotated tag from public release metadata and
   verify the release signature, checksums, provenance, chart digests, image
   digests, detector manifest, and model lock;
2. fetch the complete release kit and build a fresh full Terraform plan and
   Helm render using the persistent private values overlay;
3. preserve stateful/network controls and stop for a new approval if the plan
   contains any delete, replacement, qualification downgrade, source-access
   expansion, cost-class change, or other action outside the standing policy;
4. take and verify the required database backup, apply admission policy first,
   run the released migrations, and perform the Helm upgrade with `--atomic`;
5. wait for readiness and execute the release smoke tests before marking the
   reconciliation successful; and
6. retain the prior signed release coordinates and use the documented rollback
   procedure if health checks fail.

Kubernetes then refreshes each Deployment automatically because the verified
digest changes its pod template. Release availability alone must never mutate a
running production workload.

The released implementation is
`scripts/reconcile-signed-release.sh`; its standing policy, required
customer-owned configuration, snapshot behavior, bounded two-tag admission
overlap, and scheduler setup are documented in
`AUTOMATIC_RELEASES.md`. Bootstrap it only after `.21` is healthy and the
rollback worker hold has been cleared. Its unattended lane requires a
zero-change Terraform plan and unchanged detector, model, capability,
prerequisite, third-party image, database migration inventory, and normalized
control-plane posture. Every wider change stops for the installation agent
instead of partially refreshing API, web, or workers.

The `.21` to `.22` bootstrap is deliberately agent-managed and documented
there: zero-change Terraform plan, pre-upgrade snapshot, dual `.21`/`.22`
admission identities, atomic `.22` control rollout, then installation of the
customer-owned scheduler. Later compatible application-only releases can use
the unattended lane.

## Governed production Helm repair

The installation agent is allowed to correct the **control Helm chart** when a
released manifest prevents an otherwise verified application from becoming
healthy. Typical repairs include a missing private NetworkPolicy flow, an
incorrect probe, a resource or scheduling constraint, a Service selector, a
PDB, or other workload wiring. This is an emergency, approval-bound production
repair—not a modification of the signed release and not an unattended update.

Never edit a signed chart package in place or describe the result as that
signed release. Unpack the exact verified chart package into a customer-owned
temporary workspace, edit that copy, and use
`scripts/reconcile-helm-repair.sh plan` to derive a chart with a visible
`+repair.<digest>` version. The helper refuses changes to `Chart.yaml`, chart
dependencies, CRDs, the migration template, any rendered Helm hook, or the
signed runtime image inventory. Admission policy, Terraform, application code,
database migrations, and image contents therefore remain outside this repair
lane. A repair that needs any of them must be implemented as a new signed
release instead.

The installation agent may author permanent fixes to any chart under
`deploy/helm/` on the reviewed source branch. The control-chart helper is the
only local live-repair lane because it can mechanically preserve admission,
images, and migration behavior. Admission-chart, execution-plane, CRD,
dependency, or application-binary changes must pass exact-source CI and ship in
the replacement signed release before they are applied to production.

When a second chart-only defect is discovered after a governed repair is
active, the helper may plan a cumulative repair from the exact active repair
package by setting `ORE_HEAPHOUND_REPAIR_STACK_ON_ACTIVE=true`. The planned
bundle binds and retains the parent active record; the agent must not use that
flag with a different release, chart checksum, Helm target, or live chart. The
helper verifies each selected Deployment individually because `kubectl rollout
status` does not support a selector argument.

Use a permission-restricted customer configuration outside the checkout:

```sh
ORE_HEAPHOUND_BASE_CONTROL_CHART=/secure/releases/sddp-BASE_VERSION.tgz
ORE_HEAPHOUND_BASE_CONTROL_CHART_SHA256=REPLACE_FROM_SIGNED_RELEASE_MANIFEST
ORE_HEAPHOUND_BASE_RELEASE_TAG=vX.Y.Z-develop.N
ORE_HEAPHOUND_REPAIR_CONTROL_CHART_DIR=/secure/work/control-chart-repair
ORE_HEAPHOUND_RELEASE_VALUES=/secure/releases/values/central-eks.yaml
ORE_HEAPHOUND_PRIVATE_VALUES=/secure/ore-heaphound/values/production.yaml
ORE_HEAPHOUND_RECONCILER_STATE_DIR=/var/lib/ore-heaphound-release
ORE_HEAPHOUND_REPAIR_CHANGE_REF=REPLACE_APPROVED_CHANGE_REFERENCE
ORE_HEAPHOUND_NAMESPACE=sddp
ORE_HEAPHOUND_CONTROL_RELEASE=ore-heaphound
ORE_HEAPHOUND_EXPECTED_CURRENT_CONTROL_CHART=sddp-REPLACE_RUNNING_VERSION
# Set only when the base package and expected live chart are the exact active
# repair recorded in the state directory.
ORE_HEAPHOUND_REPAIR_STACK_ON_ACTIVE=false
ORE_HEAPHOUND_ROLLOUT_TIMEOUT=30m
ORE_HEAPHOUND_HEALTH_URL=https://heaphound.example.com/healthz
```

Plan first:

```sh
customer-deploy/scripts/reconcile-helm-repair.sh plan \
  /secure/ore-heaphound/helm-repair.env
```

The plan produces a private bundle containing the distinct chart package,
repository-applicable `source.patch`, a rendered diff, an invariant record, and
one approval SHA-256. The rendered files can contain customer identifiers and
must remain in the customer evidence store. Review the source and rendered
diffs, verify the change is the minimum healthy repair, create and verify the
normal pre-change database snapshot, and obtain approval for that exact digest.
Changes that expand RBAC, source access, public ingress/egress, TLS scope, or
cost class are material deviations and require those effects to be explicit in
the new approval packet even when the helper can render them.

Add the following values to the same private configuration only after approval:

```sh
ORE_HEAPHOUND_REPAIR_BUNDLE=/var/lib/ore-heaphound-release/helm-repair-REPLACE
ORE_HEAPHOUND_REPAIR_APPLY=true
ORE_HEAPHOUND_REPAIR_APPROVED_SHA256=REPLACE_EXACT_PLAN_DIGEST
```

Then run `reconcile-helm-repair.sh apply`. It performs an atomic Helm upgrade,
waits for every Deployment, runs the configured health probe, and writes
`active-helm-repair.json` in the reconciler state directory. The scheduled
signed-release reconciler refuses to overwrite an active repair. Run the full
release smoke tests after apply. Do not use `kubectl edit`, an unrecorded
post-renderer, or a second untracked patch.

An active repair is operational recovery, not a qualified immutable release.
Reconcile it back immediately:

1. copy only the sanitized `source.patch` to a reviewed source branch; never
   copy the private values, rendered diff, live manifests, or customer evidence;
2. generalize customer-specific constants into validated Helm values;
3. add a render regression test for the failure and run exact-source CI;
4. publish a new immutable signed release containing the source fix;
5. verify that release's render preserves or deliberately supersedes the live
   repair, then install it atomically and complete live qualification; and
6. set `ORE_HEAPHOUND_REPAIR_CLOSE=true`,
   `ORE_HEAPHOUND_RECONCILED_RELEASE`, and its exact
   `ORE_HEAPHOUND_RECONCILED_SOURCE_COMMIT`; point
   `ORE_HEAPHOUND_RECONCILED_CONTROL_CHART` at the verified signed package and
   set `ORE_HEAPHOUND_RECONCILED_CONTROL_CHART_SHA256` to its digest from the
   signed release manifest; then run
   `reconcile-helm-repair.sh close`.

Close verifies that the live chart is the declared non-repair version, waits
for readiness, archives the repair record, and removes only the active marker.
Do not close a repair merely because a pull request or tag exists—the signed
replacement must be running and healthy first.

## Live verification on a release upgrade

Production verification uses its own two-replica source-reading Deployment,
database role, and IRSA role. The API only issues a 60-second single-use grant;
it does not receive the evidence key or source-read authority. Populate
`REPLACE_VERIFICATION_PREVIEW_ROLE_ARN` from Terraform output
`verification_preview_role_arn`.

A fresh operator secret populated by this release already contains
`SDDP_VERIFICATION_DATABASE_URL` and
`SDDP_VERIFICATION_ROLE_PASSWORD`. When upgrading an existing installation,
run the released add-only helper before Helm:

```sh
scripts/upgrade-operator-secret-for-verification.sh \
  "$(terraform -chdir=infra/aws-central output -raw region)" \
  "$(terraform -chdir=infra/aws-central output -raw database_endpoint)" \
  "$(terraform -chdir=infra/aws-central output -raw database_name)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_arn)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_kms_key_arn)"
kubectl -n sddp annotate externalsecret ore-heaphound-operator \
  force-sync="$(date +%s)" --overwrite
kubectl -n sddp wait \
  --for=jsonpath='{.data.SDDP_VERIFICATION_DATABASE_URL}' \
  secret/sddp-production-operator-secrets --timeout=5m
kubectl -n sddp wait \
  --for=jsonpath='{.data.SDDP_VERIFICATION_ROLE_PASSWORD}' \
  secret/sddp-production-operator-secrets --timeout=5m
```

The helper preserves every existing field, promotes only if the secret version
it read is still current, and leaves the former value as `AWSPREVIOUS`.
Installation must stop if either exact key, the dedicated IRSA output, the
private Service, or both ready preview replicas are absent. Do not enable the
legacy API-owned sampling path to work around a failed preview rollout.

## Upgrade develop.19 to develop.21

`v0.1.0-develop.20` is withdrawn. Its signed migration runner wraps migration
`0067` in a transaction while that migration contains
`CREATE INDEX CONCURRENTLY`, so an upgrade fails deterministically with
SQLSTATE `25001`. Do not install `.20`, run its SQL manually, edit its signed
archive, or advance an individual container from it. Use
`v0.1.0-develop.21` only after its complete signed deployment kit and successful
exact-source CI are available.

1. Preserve the current private Helm and Terraform overlays and record the
   exact running `.19` chart, image, detector, and model coordinates. Production
   currently uses `db.m8g.4xlarge`, PostgreSQL `16.13`, **Single-AZ**, encrypted
   `gp3` with 100 GiB allocated and 2,000 GiB autoscaling maximum. Pin
   `database_instance_class = "db.m8g.4xlarge"` in the persistent private
   Terraform variables. The `.21` plan must retain Single-AZ and must not modify,
   replace, reboot, resize, or change the Availability Zone of this database.
   Keep the standard scan-worker maximum at 8 while the queue correction is
   evaluated.
2. Verify the `.21` release manifest, archive, images, charts, detector
   manifest, provenance, SBOMs, source commit, and migration inventory. Confirm
   that the contextual detector identity is unchanged and Presidio remains
   enabled with its pinned image/NLP identity and signed `not_qualified` quality
   status. Confirm the withdrawal metadata names `.20` and this exact
   replacement.
3. Prove the release migration Job against a disposable PostgreSQL 17 database
   before touching production. Migrations `0067` through `0074` are required:
   `0067` is transactional; each of `0068` through `0071` is a separate,
   single-statement non-transactional `CREATE INDEX CONCURRENTLY`; `0072`
   through `0074` are transactional. Stop if the runner inventory, transaction
   mode, or final migration differs. Never skip, combine, or edit them.
4. Use Terraform `1.15.8` to create a fresh full saved plan. The existing
   `aws_vpc_endpoint.s3` gateway endpoint must remain at the same state address
   and attached to all three approved private route tables. Stop on any RDS
   action, any delete or replacement, any S3 endpoint change, reduced
   backup/monitoring settings, or unexpected pending modification. The already
   created dedicated verification-preview IAM role may remain unchanged. Retain
   one fixed on-demand GPU baseline node; elastic GPU replicas 2 through 8 use
   Spot capacity with the released fallback policy.
5. Ensure `verification_preview_role_arn` remains in the persistent private
   values overlay. Prove both verification database keys are present in the
   synchronized operator Secret without reading their values. Do not recreate
   the role or secret fields if the `.20` attempt already added them.
6. Take and verify the required database backup. Upgrade the signed admission
   chart first, then the signed control chart with `--atomic`. Do not resume the
   held scan until migrations, API, web, and worker-autoscaling configuration
   have all passed validation.
7. The rollback procedure temporarily held all scan-worker pools at zero.
   Restore the signed private Helm values first: the standard maximum stays 8
   and every intended pool must have a maximum above zero. Then inspect only
   release-owned worker ScaledObjects:

   ```sh
   customer-deploy/scripts/reconcile-worker-autoscaling-pause.sh \
     check sddp ore-heaphound
   ```

   If the output reports either KEDA administrative pause annotation, clear
   only those annotations under the approved rollout:

   ```sh
   ORE_HEAPHOUND_DEPLOYMENT_APPROVED=true \
     customer-deploy/scripts/reconcile-worker-autoscaling-pause.sh \
       clear sddp ore-heaphound
   ```

   Substitute the actual namespace and Helm release. The helper must refuse to
   clear a pool whose signed `maxReplicaCount` is still zero. Do not patch a
   Deployment replica count or delete queue rows.
8. Wait for three API replicas, three web replicas, two verification-preview
   replicas, extraction, Presidio, Ollama, and demanded scan-worker pools.
   Production retains Ollama `minReplicaCount: 1`, permits at most 8 Qwen
   replicas, and caps standard workers at 8. The Settings worker card must show
   each configured pool, signed maximum, managed demand, and live processes.
   A running scan with ready/leased work or a positive allocation and no
   heartbeat is `stalled`, not normal `scaled_to_zero`; inspect KEDA pause
   annotations, KEDA status, scheduler events, and node capacity.
9. Resume the existing paused scan once. `.21` must immediately renew its exact
   approved advisory capacity allocation, and the periodic refresher must keep
   that allocation alive while the scan remains running. Within the KEDA poll
   and scheduling window, confirm a worker heartbeat, a falling ready queue,
   and increasing completed units. The scan-first batch claim must work for an
   unfiltered standard worker; any `could not determine data type of parameter`
   error is a stop condition.
10. Verify an admin and an analyst can each use the Triage **Verify** action.
    The browser must call the private BFF route, the grant must expire after 60
    seconds and fail on replay, responses must be `no-store`, and the ordinary
    control-plane API must not return source values.
11. Start concurrent scans only on different registered sources. Attempting a
    second active scan on the same source must return a conflict. Cancel a test
    scan and wait through `cancelling` to `cancelled`; confirm leases stop
    renewing, no second worker continues that source, and the bounded reconciler
    leaves no pending or leased work for the scan.
12. Confirm the Dashboard distinguishes current-estate posture from lifetime
    classified work, creates its first value snapshot even when the posture
    cache is already warm, and keeps byte counters correct when discovery
    refines an estimated object size. Full, Partial, and Not analyzed must sum
    to Discovered. Finding-bearing is a deliberately overlapping physical-object
    footprint and comes from current non-dismissed occurrences, not a stale
    `finding_count`. Stop if posture or value snapshots remain stale after a
    successful refresh.
13. Compare claim SQL AAS, RDS CPU, connections, no-work claims, and completed
    units per minute with the `.19` diagnostic. Do not raise the standard worker
    ceiling above 8 until the scan-first batch claim path has shown stable
    database headroom under concurrent-source load.

For an unresponsive scan, do not delete queue rows or launch a second scan
against the source. Capture its scan state, discovery checkpoint, capacity
allocation expiry, ready/leased counts by pool, current worker heartbeats, KEDA
pause annotations/status, scheduler events, and API logs. If it must be
stopped, request cancellation once and let the restart-safe reconciler revoke
leases and finish coverage accounting.

Do not install an in-container release watcher. The external installation
agent may detect a newer signed release and prepare a plan, but it may reconcile
only the entire verified release unit through the approval boundary described
under **Automatic release reconciliation**.

## Upgrade develop.22 to develop.23.2

`v0.1.0-develop.23.1` is withdrawn. Its admission chart placed the candidate
and rollback workflow subjects in one keyless attestor, which the locked
Kyverno verifier rejects. Do not patch, rebuild, or reuse any `.23.1` artifact.
Use only the complete immutable `.23.2` release after exact-source CI and
signature verification succeed.

This is a schema-changing agent-managed upgrade; the automatic reconciler must
stop on the migration inventory change and must not apply it unattended.

1. Verify the `.23.2` annotated source tag, release/archive signatures,
   checksums, images, charts, provenance/SBOMs, detector and model locks,
   capability posture, and withdrawal metadata. The production contextual
   model remains the approved `qwen2.5:7b-instruct` artifact; Presidio and all
   native/secret scanners remain enabled.
2. Pause active scans through the supported API and hold only release-owned
   autoscalers. Establish the documented idle database baseline, then create
   and wait for a fresh encrypted pre-upgrade snapshot. A snapshot from an
   earlier attempt is evidence only after workload has resumed.
3. Produce and review a fresh saved Terraform plan from customer-owned state
   and variables. Apply only the explicitly approved infrastructure actions;
   stop on an unreviewed database, network, identity, delete, replacement, or
   customer-boundary change.
4. Prove the signed migration runner on a disposable PostgreSQL database. The
   candidate inventory advances from `0074` through
   `0089_restore_dashboard_refresh_rollback_compatibility.sql`. Migrations
   `0076` through `0083` are separate non-transactional concurrent index
   operations; `0075` and `0084` through `0089` are transactional. Never edit,
   combine, skip, or run these files manually.
5. Install the exact signed `.23.2` admission chart first with two separate
   single-identity attestors: candidate `.23.2` and current `.22`. Before the
   control upgrade, server-side dry-run both exact signed image digests and
   require both to pass. Continue to deny mutable, unsigned, unlisted,
   wrong-digest, and wrong-identity images.
6. Install the signed control chart with the customer overlays, immutable image
   digests, migration Job, `--atomic`, and the approved timeout. Require the
   migration ledger to end at `0089` before workloads roll and do not use SQL or
   queue-row edits to force progress.
7. Validate API, web, extraction, Presidio, Ollama, remediation, verification
   preview, and every demanded scan-worker pool. Confirm the UI distinguishes
   discovery completion from processing completion and does not issue
   overlapping background refreshes.
8. Clear only the approved release-owned autoscaler holds and resume each scan
   exactly once through the supported API. Confirm ready work is claimed and
   terminal counts advance.
9. Compare RDS CPU, AAS, connections, lock/WAL waits, claim calls, heartbeat
   updates, and completed units per minute with the pre-upgrade baseline. The
   release batches claims per pod, backs off empty polls, and aggregates worker
   presence to one 20-second row update per pod; stop on a material regression
   rather than increasing worker ceilings to hide it.

If application rollback is required, keep the forward migration ledger and
roll Helm back only to the exact signed `.22` artifacts admitted above. Migration
`0089` preserves the `.22` dashboard refresh entry point for that bounded
rollback. Do not reverse SQL. Restoring the pre-upgrade snapshot is a separate
destructive recovery decision requiring explicit approval and a full outage
plan.

## Governed remediation

Remediation is off unless it is explicitly requested. When it is in scope, the
same consolidated packet must additionally cover:

1. `remediation_enabled = true` in Terraform, which creates the write-scoped
   executor IRSA role and the versioned, KMS-encrypted quarantine and redacted
   buckets. This is the only identity in the deployment permitted to write or
   delete a source object; the control-plane and scan-worker roles stay
   read-only.
2. The explicit `values/remediation-eks.yaml` overlay, populated from the
   `remediation_executor_role_arn`,
   `quarantine_bucket`, `redacted_bucket`, and `data_kms_key_arn` outputs.
3. The `sddp_executor` database role, created and granted by the `db-prepare`
   Job from the operator secret. A fresh secret populated by this release
   already has the executor credential. For an existing secret, run the
   add-only `upgrade-operator-secret-for-remediation.sh` helper before Helm; the
   one-time `populate-operator-secret.sh` intentionally refuses to overwrite an
   existing version.

The upgrade helper preserves every existing secret field, stages the augmented
value under a private Secrets Manager label, and moves `AWSCURRENT` only if the
version it read is still current. The old value remains `AWSPREVIOUS`. Wait for
the ExternalSecret to synchronize the new version before starting the Helm
upgrade: annotate `externalsecret/ore-heaphound-operator` with a changed
`force-sync` value, then use `kubectl wait --for=jsonpath=...` to prove both
executor keys exist as shown in
[DESIGN_PARTNER.md](DESIGN_PARTNER.md). `Ready=True` by itself may still refer
to the old synchronized version. The pre-upgrade `db-prepare` Job then creates
or rotates the `sddp_executor` login before the executor Deployment rolls.

The chart refuses to render when the executor role ARN matches the control-plane
or scan-worker role. Do not work around that check by widening a role; correct
the ARN.

After install, prove the executor is healthy and prove dual control end to end:
a redaction request, a dry run, an approval by a principal other than the
requester, execution, an independent re-scan showing the content gone, and a
verified rollback. See [DESIGN_PARTNER.md](DESIGN_PARTNER.md) for the full
walkthrough.

## Existing develop rehearsal

The current develop rehearsal may contain the test-only Service
`ore-heaphound-sddp-web-public`. The released Service uses
`ore-heaphound-sddp-web-public-managed`, so it can be created and validated
without an outage or Helm ownership conflict.

For a reconciliation:

1. preserve all sealed reports;
2. plan from a clean checkout and current remote state;
3. create the managed endpoint and prove all its targets healthy;
4. move DNS with the released helper;
5. validate strict TLS, HSTS, allow-list enforcement, and log delivery; then
6. remove the manual Service/NLB and every other test-only resource included
   in the approved cleanup list.

Do not import the manual NLB into the chart, patch an old immutable tag, or
delete the working endpoint before the managed replacement passes.

## DNS and ACM

`reconcile-public-dns.sh` locates the longest matching public Route 53 zone,
verifies the expected account, verifies that the certificate is issued for the
hostname, and prepares exactly two CNAME UPSERTs:

- the application hostname to the managed NLB; and
- the ACM validation record required for renewal.

The helper refuses to apply without the consolidated approval and exact payload
digest. If the authoritative zone is not in the expected account, stop and
hand the two records to the authoritative DNS owner. Never use unrelated
root-organization credentials without explicit authorization.

## Production completion

Report production ready only when:

- Terraform is no-change after apply;
- DNS, ACM renewal eligibility, TLS, HSTS, targets, and access logs pass;
- signed-image admission positive and negative tests pass;
- the customer administrator can authenticate, MFA is proven, and any
  configured SSO is proven;
- NetworkPolicy, PDB, topology, metrics, logs, alarms, VPC flow logs, EKS
  control-plane logs, CloudTrail, Config, GuardDuty, and Security Hub are
  evidenced;
- RDS and EFS backup plus isolated restore drills pass;
- exact-version S3 analysis, scale-from-zero, and Spot interruption tests pass;
- the qualified detector/model bundle and all stable-release receipts bind the
  exact artifacts; and
- no manual or test-only resource remains.

If a required test fails, preserve evidence, roll back only the actions listed
in the approved packet, and report the exact blocker. Never bypass admission,
weaken TLS, widen a source CIDR, disable deletion protection during deployment
or operation, or fall back to a different release. Deletion protection may be
disabled only by the separately approved, exact decommission procedure in
`STAGING_QUALIFICATION.md`. Production with an active `+repair` chart may be
reported as operationally recovered, but not release-qualified or reconciled.
