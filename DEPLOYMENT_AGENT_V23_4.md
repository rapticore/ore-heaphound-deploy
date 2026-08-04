# Deployment agent directive: v0.1.0-develop.23.4

Give this complete directive to the production deployment agent. It governs
the replacement of the active `v0.1.0-develop.23.3+repair.f8ae279c3aed`
control release with the immutable signed `v0.1.0-develop.23.4` release.

The release manifest, not this document, is authoritative for source, image,
chart, archive, signature, provenance, SBOM, detector, and model digests.

## Required outcome

- Keep the application available while advancing the database from migration
  `0096_usage_diagnostics.sql` through
  `0098_scan_cancellation_pending_index.sql`.
- Replace the local `.23.3` repair with the exact signed `.23.4` chart, which
  incorporates its fixed-capacity rollout, label, dashboard, and Presidio
  changes.
- Cancel the known quadratic `.23.3` dashboard refresh before the migration
  hook needs the materialized-view lock.
- Restore a bounded, fresh dashboard and prove that the browser does not
  flicker, reload, or overlap refresh requests.
- Keep usage metering, licence reporting, and entitlement enforcement optional.
  Their absence or unavailability must not affect login, readiness, API,
  dashboards, scans, workers, or remediation.
- Close the active repair record and re-enable automatic reconciliation only
  after the exact signed replacement is healthy.

## Explicit authority and boundaries

The agent may perform read-only discovery, pause/resume scans through the API,
cancel the exactly identified application-owned dashboard refresh backend with
`pg_cancel_backend`, run the signed migration Job, install the signed charts,
and apply a minimum governed Helm repair if an unforeseen chart-only defect
prevents operation.

Do not create a pre-rollout snapshot. Preserve RDS automated backups and point-
in-time recovery, but do not call any RDS, EBS, EFS, or Kubernetes-volume
snapshot API.

Do not modify application or extraction images, migration SQL or checksums,
Terraform-managed infrastructure, RDS configuration, IAM, RBAC, public
exposure, NetworkPolicy default deny, customer-source scope, or secret values.
Never print Secret data, generated token material, database URLs, customer
identifiers, source paths, object names, findings, or evidence values.

Never terminate a database backend. Cancellation is authorized only for a
session positively identified by database, runtime role, active state, query
identity, age, and `refresh_dashboard_rollup` execution.

## Immutable preflight

1. Resolve `v0.1.0-develop.23.4` from the public release metadata and require an
   annotated signed tag whose commit is reachable from protected `develop`.
2. Verify the release manifest and archive signatures/checksums, both immutable
   application images, all three OCI charts, chart package checksums,
   per-platform provenance and SPDX attestations, detector manifest, model
   lock, prerequisites, capabilities, withdrawal metadata, and exact tagged
   workflow identity.
3. Require a contiguous migration inventory ending at
   `0098_scan_cancellation_pending_index.sql`. Migration `0098` must be the one-
   statement, restart-safe, non-transactional concurrent partial-index path.
   Its `(scan_id, id)` key must provide the cancellation batch's ID order while
   the predicate restricts it to `pending` and `leased` work; do not put `state`
   between those key columns and reintroduce a per-batch sort.
4. Record the live account, Region, cluster, namespace, Helm releases and
   revisions, image digests, migration ledger, active repair marker, scans,
   autoscaler holds, pod readiness/restarts, RDS state, and S3 gateway endpoint.
5. Produce a fresh Terraform 1.15.8 saved plan. It must contain zero changes;
   do not apply it.
6. Do not create or wait for a new snapshot.

## Render and upgrade trap

Render with the released production values and persistent private overlays
before mutation. The `.23.3` repair used `dashboardRefresh.enabled` only to
control whether interval/timeout overrides were rendered. `.23.4` uses it as a
real on/off switch. Prevent the old `24h/24h` workaround from surviving the
upgrade.

The effective values for the signed replacement must contain:

```yaml
controlPlane:
  rollout:
    maxUnavailable: 1
    maxSurge: 0
  dashboardRefresh:
    enabled: true
    interval: ""
    timeout: ""
web:
  rollout:
    maxUnavailable: 1
    maxSurge: 0
presidio:
  workers: "2"
  gunicornArgs: "--timeout 300 --graceful-timeout 300"
```

Blank dashboard durations select the application defaults: a one-minute quiet
interval and a ten-minute cycle budget. The chart must reject an explicit
timeout equal to the interval, and the application must reject any explicit
timeout equal to or below the interval. Do not carry `24h/24h` forward and do
not set `enabled: false` merely to conceal a failed query.

Prove the rendered API/web rollout values are Kubernetes integers, the
`helm.sh/chart` label is valid, Presidio has both process settings, verification
preview has extraction egress on TCP 9998, extraction admits it, default deny
remains enabled, and usage/licence resources remain absent when disabled.

## Required execution sequence

1. Pause automatic release reconciliation and establish exclusive deployment
   control. Preserve the active repair marker.
2. Pause each running scan once through the supported API and record only its
   opaque identifier and previous state. Hold only release-owned autoscalers.
3. Identify the active `.23.3` `refresh_dashboard_rollup` backend using the
   bounded predicate above. Cancel it with `pg_cancel_backend`; do not terminate
   it. Wait for the dashboard lock to clear and temporary space to stabilize.
4. Immediately before Helm starts the pre-upgrade Job, repeat the read-only
   check and cancel another exact refresh if one appeared. The old application
   cannot honor `.23.4`'s disable flag before the migration hook.
5. Upgrade admission first with separate exact `.23.3` rollback and `.23.4`
   candidate attestors. Positive dry-runs for both exact image sets must pass;
   mutable, unsigned, unlisted, wrong-digest, and wrong-workflow images must
   fail.
6. Upgrade the control release atomically using the exact signed `.23.4` chart,
   immutable image digests, released values, persistent private overlays, and
   the signed migration Job. Do not run migration SQL manually.
7. Require the migration ledger to contain 98 checksum-bearing entries ending
   at `0098`. Confirm the cancellation index is valid and the dashboard view no
   longer contains the correlated `nodes child` subplan.
8. Wait for every desired API, web, verification-preview, extraction,
   Presidio, Ollama, remediation, and worker replica to become Ready. Do not
   require a fixed total pod count when KEDA demand changes.
9. Clear only holds created for this maintenance window and resume each scan
   exactly once. Do not edit queue or scan rows.

## Qualification gates

Require all of the following before closing the repair:

- portal `/` returns `303` to `/login`, `/login` returns `200`, and internal
  `/livez` and `/healthz` return `200`;
- authenticated dashboard, source, and scan requests return successful status
  codes with bounded latency;
- at least two consecutive complete dashboard cycles advance `refreshed_at`,
  report `stale=false`, and finish well below their per-view and cycle budgets;
- no active refresh, dashboard lock, unbounded temporary-space growth, or
  persistent cleanup load remains after each cycle;
- an actual browser trace shows no document reload loop, redirect loop,
  progressive blanking, overlapping dashboard reads, or background polling in
  a hidden tab;
- Presidio remains Ready under worker startup demand with two analyzer
  processes and no probe thundering herd;
- verification preview reaches extraction on TCP 9998 while an unpermitted
  probe remains denied;
- scan cancellation uses bounded batches and completes without the prior
  full-table cancellation scan;
- API, web, scans, workers, and remediation remain healthy with the usage and
  licence services absent or deliberately unreachable; and
- RDS CPU, load, connections, locks, write latency, disk queue, memory, storage,
  and temporary bytes remain stable.

If dashboard refresh fails, use `controlPlane.dashboardRefresh.enabled=false`
as an explicit, truthful emergency mode: serve the last good snapshot with its
real age and `stale=true`. Do not replace this with an enormous interval. A
dashboard disabled in this way is operationally degraded and not qualified.

## Repair reconciliation and final report

If the exact signed chart is healthy, close the active `.23.3` repair using the
released repair helper, binding the `.23.4` chart checksum and exact source
commit. Confirm the marker is archived before re-enabling automatic release
reconciliation.

If another chart-only repair is required, use the governed repair helper. It
may stack on the exact active repair only with
`ORE_HEAPHOUND_REPAIR_STACK_ON_ACTIVE=true`, must retain the parent record, and
must produce a distinct chart version, source/render diffs, package and record
hashes, invariant proof, and an active marker. Leave automatic reconciliation
disabled and do not call that state release-qualified.

Return one sanitized report in durable, access-controlled evidence storage (not
only under `/tmp`) with exact identities, revisions, migration ledger,
no-snapshot and zero-Terraform-change statements, the bounded refresh
cancellation result, effective dashboard/rollout/Presidio values, readiness,
browser trace, dashboard cycle timings/freshness, scan outcome, RDS comparison,
repair closure or new repair evidence, and every deviation. Include no secret
or customer value.
