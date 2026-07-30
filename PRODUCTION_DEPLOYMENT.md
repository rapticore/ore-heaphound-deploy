# Production deployment agent runbook

This is the production-oriented AWS/EKS path for the next immutable Ore
HeapHound release. It is designed for an LLM deployment agent acting in a
customer-owned account. The agent asks for the few values a customer actually
knows, performs read-only discovery, presents one consolidated change packet,
and then completes the approved deployment without requesting permission for
each routine step.

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

1. apply the exact saved infrastructure plan;
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

## Upgrade develop.19 to develop.20

Use this sequence only after `v0.1.0-develop.20` has a successful release
workflow and the complete signed deployment kit is available. Do not deploy a
branch image or advance one container independently.

1. Preserve the current private values overlay and record the exact running
   chart/image/detector coordinates. If RDS was resized through AWS before this
   release, record the exact resulting `db.m8g.<size>` class and set
   `database_instance_class` to that exact value in the persistent private
   Terraform variables overlay before planning. Do not rely on the module's
   bootstrap default. Keep the temporary production standard worker ceiling at
   8 while the upgrade is evaluated.
2. Verify the `.20` release manifest, archive, images, charts, detector
   manifest, provenance, and SBOMs as described above. Confirm that the
   contextual detector identity is unchanged and Presidio is enabled with its
   pinned image/NLP identity and signed `not_qualified` quality status.
3. Use Terraform `1.15.8` to create a new full saved plan. The existing
   `aws_vpc_endpoint.s3` gateway endpoint must remain at the same state address;
   stop if the plan deletes or replaces it. Stop if the plan changes the
   approved post-resize RDS class away from the exact pinned `db.m8g.<size>`
   value, replaces the database, reduces backup/monitoring settings, or reports
   an unexpected pending modification. The plan may add the dedicated
   `verification_preview` source-read role. It must retain one fixed on-demand
   GPU baseline node; elastic GPU replicas 2 through 8 use Spot capacity with
   the released fallback policy.
4. Put `verification_preview_role_arn` into the persistent private values
   overlay, then run
   `upgrade-operator-secret-for-verification.sh` and force the ExternalSecret
   synchronization using the value-free commands in the preceding section.
   Prove both verification database keys are present before Helm.
5. Apply the exact saved Terraform plan, upgrade the signed admission chart
   first, and then run the control-chart upgrade with `--atomic`. The released
   migrations `0067` through `0070` are required; never skip or edit them.
6. Wait for three API replicas, three web replicas, two verification-preview
   replicas, extraction, Presidio, scan-worker pools, and Ollama to be ready.
   Production must retain Ollama `minReplicaCount: 1`, allow at most 8 Qwen
   replicas, and cap the standard scan-worker pool at 8. The scan-worker and
   verification database pools must each have at most two connections per pod.
7. Verify an admin and an analyst can each use the Triage **Verify** action.
   The browser must call the private BFF route, the grant must expire after 60
   seconds and fail on replay, responses must be `no-store`, and the ordinary
   control-plane API must not return source values.
8. Start concurrent scans only on different registered sources. Attempting a
   second active scan on the same source must return a conflict. Cancel a test
   scan and wait through `cancelling` to `cancelled`; confirm leases stop
   renewing, no second worker continues that source, and the bounded reconciler
   leaves no pending or leased work for the scan.
9. Confirm the Dashboard distinguishes current-estate posture from lifetime
   classified work, labels historical backfill as incomplete until finished,
   records immutable prospective predictions and cost observations, and shows
   egress as `not_attested` unless a future signed manifest actually attests it.
   Full, Partial, and Not analyzed must sum to Discovered; Finding-bearing is a
   deliberately overlapping physical-object footprint and may exceed Full
   while partially analyzed objects contain findings. Stop if either posture or
   value snapshot is marked stale after the first successful refresh.
10. Compare claim SQL AAS, RDS CPU, connections, no-work claims, and completed
    units per minute with the `.19` diagnostic. Do not raise the standard
    worker ceiling above 8 until the scan-first batch claim path has shown
    stable database headroom under concurrent-source load.

For an unresponsive pre-upgrade scan, do not delete queue rows or launch a
second scan against the source. Complete the `.20` upgrade, request
cancellation once, and let the restart-safe reconciler revoke leases and
finish coverage accounting. Escalate only if it does not reach `cancelled`;
retain its scan ID, worker heartbeats, pending/leased counts, and API logs.

Do not install an in-container release watcher. The external installation
agent may detect a newer signed release and prepare a plan, but it may reconcile
only the entire verified release unit through the approval boundary described
under **Automatic release reconciliation**.

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
`STAGING_QUALIFICATION.md`.
