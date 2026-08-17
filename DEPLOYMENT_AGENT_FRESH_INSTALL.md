# Fresh customer installation agent directive

Give this complete directive to the installation agent for a brand-new
customer-owned Ore Heaphound application environment. The application may be
installed on a newly provisioned EKS cluster or on a compatible existing
customer-owned EKS cluster. It is not an upgrade, repair, reconciliation,
migration of an existing Ore Heaphound deployment, or authorization to touch
another Ore Heaphound environment.

This directive was reviewed against the public
`v0.1.0-develop.23.30` deployment kit on 2026-08-16. That release contains all
published changes through source commit
`47a6ab996a3beea531c5cfd777c903c9c3b70eec`, including 147 database
migrations ending at `0147_scan_stalled_notification_lookup.sql`.

The release manifest is authoritative for source, image, chart, archive,
signature, provenance, SBOM, detector, prerequisite, model, capability, and
migration coordinates. This directive controls how those artifacts may be
used for a fresh installation.

## Applicability and precedence

Use this directive only when all of the following are true:

- exactly one EKS installation mode is selected: `new_eks` or `existing_eks`;
- the deployment ID, application database/schema, namespace, Helm releases,
  operator/generated secrets, evidence roots, and application DNS names are
  new;
- no application data, scan, queue, migration ledger, generated Secret, or
  retained evidence exists for the target;
- the customer selected `operation: deploy` and `deployment_action: new`; and
- the release is at least `v0.1.0-develop.23.30` and contains every invariant
  listed under **Fresh-release invariants** below.

If any resource or state record for the proposed deployment already exists,
stop and classify the operation as `resume`, `upgrade`, or `collision`. Never
adopt, import, overwrite, rename, or destroy it under this directive.

An `existing_eks` cluster, its VPC, node infrastructure, shared controllers,
and customer platform services may predate this installation. They remain
customer-owned and outside Ore Heaphound lifecycle ownership. The application
namespace and every Ore Heaphound stateful identity must still be fresh.

This file takes precedence over upgrade-only instructions in
`DEPLOYMENT_AGENT_V23_4.md`, the legacy develop-rehearsal reconciliation path,
and the `.21` to `.22` automatic-reconciler bootstrap. Continue to use the
security, artifact-verification, planning, validation, evidence, and
decommission rules in `PRODUCTION_DEPLOYMENT.md`, `SELF_HOSTED.md`, and
`STAGING_QUALIFICATION.md` where they do not conflict with this fresh-only
directive.

Do not use an account ID, Region, cluster name, source, secret, DNS name,
capacity value, or approval packet from another installation as a default.

## Choose exactly one EKS lane

| Mode | Platform action | Required planning boundary |
|---|---|---|
| `new_eks` | Create a dedicated VPC/EKS platform and application prerequisites with the released `infra/aws-central` root. | Customer bootstrap plan followed by the exact AWS-central saved plan or strict post-bootstrap plan contract. |
| `existing_eks` | Install a fresh Ore Heaphound application into a compatible existing customer-owned EKS cluster. | Customer-owned application-prerequisite plan plus Kubernetes/Helm plan. Do not run `infra/aws-central`. |

The release is cumulative in both lanes. Install one exact current signed
release and let its signed migration Job apply the entire ledger to an empty
database. Do not install historical releases in sequence and do not replay
upgrade-only snapshot, pause/resume, repair, or migration procedures.

For `existing_eks`, the agent must not run `infra/aws-central`, even in plan
mode against an existing platform state. That root unconditionally creates a
VPC, EKS cluster, RDS instance, EFS file system, IAM roles, controllers, and
other dedicated resources; it is not an adoption or bring-your-own-cluster
module.

## Qualification status

As reviewed, `v0.1.0-develop.23.30` is a public prerelease. Its signed release
manifest and detector manifest both say `not_qualified`. It may be installed
in a new customer-owned environment for rehearsal, but neither the tag nor
evidence produced from it may be relabeled as a qualified stable release.

For `mode: stable_qualification`, require an immutable signed stable candidate
whose detector bundle is already promoted under the current two-person
detector policy. The target qualification record is then produced by the
fresh-install workflow below: install that exact candidate, obtain 12 passing
target-bound receipts, and complete protected finalization. If no such
candidate exists, return
`BLOCKED_NO_QUALIFICATION_ELIGIBLE_STABLE_CANDIDATE`; do not relabel a develop
prerelease or reuse develop receipts for a stable target.

## Public trust boundary

Customer deployment trust begins at the signed public release. Do not request
access to the private source repository or use a private or dirty source
checkout as deployment input. Work from a newly extracted public release kit
and locally verified chart packages in a customer-controlled private work
area.

For the reviewed release, require at least these public coordinates before
planning:

| Coordinate | Required value |
|---|---|
| Release tag | `v0.1.0-develop.23.30` |
| Source commit bound by the manifest | `47a6ab996a3beea531c5cfd777c903c9c3b70eec` |
| Release-manifest SHA-256 | `50c12150059b485983c391cee0a7b179df47b177172dfd5616674cd926b6622f` |
| Customer-kit SHA-256 | `d4fee8adfb89b9a474180ec2f109941ca99ca43856ec3ff81ca22a848bc3a19b` |
| Application image digest | `sha256:f3c64a548bf4812af9ef13037ac251f1845497deac8b983edb0c98578005ada9` |
| Extraction image digest | `sha256:54cc906d274188e12ed117e6428d13275aaff0407cabe65f3b347aa636339da7` |
| Control chart OCI digest | `sha256:1d2d0354df5628b2701a3166beba4a8e91254403ed8018a10647a0694f302db8` |
| Admission chart OCI digest | `sha256:bdc15656725a21fed3ad4328d6d6772fc573c424265338372d921c9828865ced` |
| Execution chart OCI digest | `sha256:ef08dc436da563a0620bb4f8a974426219a2c98371c5e45ca594bb502865e74b` |
| Detector-manifest SHA-256 | `7656ae355ee024ce1d382c036ede51469120c27b7e311e62f1311c33917a0c8c` |

Verify the release-manifest bundle, customer-kit checksum and bundle, image
signatures, OCI chart signatures, pulled chart package checksums, parent-index
SLSA/SPDX attestations, detector manifest, model lock, prerequisite lock,
capability catalog, migration inventory, and withdrawal list exactly as phase
C of `STAGING_QUALIFICATION.md` requires. Registry, DNS, authorization, or
transparency-service failures are verification-access failures, not proof that
an artifact is unsigned or absent.

Before using a release newer than the reviewed release, create a new immutable
artifact record and prove that it preserves or deliberately supersedes every
fresh-release invariant below. A newer tag is a new decision packet; never
silently substitute it after approval.

## Fresh-release invariants

The effective installation configuration must provide all of the following:

- all 147 `.23.30` migrations are present, contiguous, checksum-bearing, and
  applied by the signed migration Job to the empty database;
- new scans pin `controlPlane.occurrenceStorageVersion: 2` from their creation;
- format-range sharding v2 remains enabled for large newline-oriented data;
- the native v12, Kingfisher 1.106.0, Presidio 2.2.362, and signed contextual
  Qwen/PHI prompt identities are taken from the detector manifest and model
  lock rather than typed from this document;
- extraction, Presidio, contextual inference, worker-pool, fair-share
  capacity, stalled-scan diagnosis, bounded cancellation, notification, and
  quarantine-finalization behavior come from one coordinated release;
- the production dashboard refresh remains disabled until its estate-sized
  refresh is separately qualified for the new target;
- lifecycle remains disabled in preview posture, occurrence deletion remains
  false, and no purge credential or deletion authority is created;
- remediation and source-write identities remain disabled unless the customer
  selected them in the approved packet; and
- raw-value verification, if selected, uses the dedicated verification-preview
  workload and read identity, not the ordinary API identity.

The packaged `.23.30` `values/central-eks.yaml` does not select occurrence
storage v2. For this fresh installation only, the private customer overlay
applied after `values/central-eks.yaml` must contain this release-bound block:

```yaml
controlPlane:
  occurrenceStorageVersion: 2
  cancellationBatch: 1000
  dashboardRefresh:
    enabled: false
  readinessProbe:
    timeoutSeconds: 5
    failureThreshold: 5

lifecycle:
  enabled: false
  mode: preview
  purgeAcknowledged: false
  categories:
    occurrences: false
    analysisReceipts: true
    workUnits: true
    heartbeats: false
    notifications: false
    outbox: false
  batchRowsByCategory:
    analysisReceipts: 25000
    workUnits: 50000
  maxBatches: 100
```

Bind the complete private overlay and its SHA-256 to the decision packet. Do
not apply this fresh-only activation block to an older running installation;
that requires its own compatibility rollout.

## Authority and stop conditions

Starting the task authorizes non-mutating preparation only: guided intake,
read-only cloud and Kubernetes discovery, release verification, collision
checks, configuration generation, Terraform planning, Helm rendering, policy
validation, and cost estimation.

Present one exact pre-install decision packet. One explicit approval of that
packet may authorize the exact bootstrap plan, central saved plan or strict
post-bootstrap plan contract, prerequisite installation, one-time empty-secret
population, locked-model staging, signed chart installation, bounded synthetic
smoke, selected optional tests, deterministic DNS reconciliation, and cleanup
of named temporary test resources. It does not authorize decommissioning,
production-source remediation, unplanned writes, adoption of existing
resources, or a different account, Region, identity, release, plan, values
digest, source scope, or cost ceiling.

Stop and produce a new packet when identity, scope, plan actions, security
controls, release coordinates, customer overlay, source authority, or maximum
cost changes. Refreshing an expired session to the same verified identity,
bounded waiting, and retrying transient reads do not require a new approval.

Never print, store in evidence, or place in Terraform/Helm configuration any
secret value, token, private key, database URL, raw finding, customer object
name, source path, or customer content.

## Rapid interaction and guided intake

Build the private resolved specification from
`AGENT_DEPLOYMENT_SPEC.example.yaml`; do not ask the customer to edit YAML.
Run authenticated read-only discovery before asking questions. Derive the
active identity, account, Region, existing-cluster coordinates and ownership,
compatible versions, quotas, name availability, signed artifact coordinates,
model inventory, cost proposal, and change reference whenever customer policy
allows it.

Use this customer interaction budget:

1. Ask zero configuration questions when the request and read-only discovery
   resolve every material choice. Otherwise ask at most one compact
   configuration question containing only the unresolved choices: `new_eks`
   or `existing_eks`, source/connectors, endpoint exposure, qualification
   mode, and exceptions to the recommended cost/retention defaults.
2. Apply rapid defaults to everything else: AWS plus S3, generated
   collision-checked names, local port-forward access, synthetic data only,
   remediation and lifecycle off, remote workers and disruptive tests off,
   bounded synthetic smoke on, and a cost ceiling proposed from the plans.
3. Present one complete digest-bound decision packet and ask exactly one final
   approval question. Do not create routine mid-run questions or a field-by-
   field questionnaire.

Do not infer the EKS lane if neither the request nor discovery establishes it;
include that single choice in the compact configuration question. For an
existing cluster, discover its exact ARN/name, Region, kube context, platform
owner, and shared-workload status instead of asking the customer to retype
them. Never ask for credentials, secret values, YAML edits, versions, names,
digests, model files, or values that can be discovered or safely generated.

For `develop_rehearsal`, resolve qualification intent to `rehearsal_only`. For
`stable_qualification`, resolve it to `qualify_when_eligible` and include the
entire receipt and protected-finalization sequence in the final packet. The
fixed profile overrides the rehearsal defaults: automatically select every
required keyless GCS identity, restore, interruption, migration-recovery, and
synthetic-remediation test, and show their scope and cost in the packet. Do not
ask a second qualification-finalization question. The two independent detector
approvals and GitHub protected-environment review remain mandatory governance
controls and are not replaced by the customer's deployment approval.

When Google sources are selected, prefer keyless AWS-to-Google workload
federation and exact service-account impersonation; do not create a service-
account key. When Slack is selected as a source, use a dedicated bot with only
the documented read scopes. Slack notification delivery uses an independent
webhook secret and is not implied by Slack source access. Keep all credential
values in the approved secret manager.

## Prove the target is new

Before generating a mutating plan:

1. verify the live installer identity, account, role, Region, and session;
2. verify the selected EKS mode and exact target cluster identity/context;
3. query every proposed application Terraform backend, workspace, and state
   key;
4. query exact proposed names for the database/schema, EFS/PVCs, S3, KMS,
   Secrets Manager, IAM/workload identities, load balancers, DNS, backup
   resources, log groups, namespace, Helm releases, and cluster-scoped
   admission policy;
5. confirm the exact cluster contains no Ore Heaphound installation in any
   namespace and that the proposed `sddp` namespace does not exist;
6. for `new_eks`, also prove the proposed VPC, EKS, RDS, EFS, controller, and
   AWS-central state identities are unused; and
7. retain only sanitized collision results and metadata.

An occupied state key, matching deployment tag, matching secret with a version,
matching Helm release, migration ledger, or retained generated Secret proves
that this is not a new install. Return `BLOCKED_TARGET_NOT_EMPTY` with the
non-secret collision inventory. Do not solve a collision with Terraform
import, `state rm`, `helm uninstall`, secret overwrite, or resource deletion.

An existing EKS cluster is not itself a collision in `existing_eks` mode. A
pre-existing Ore Heaphound namespace, Helm release, cluster-scoped admission
policy name, generated Secret, application database/schema, migration ledger,
or application prerequisite state is a collision.

## Existing EKS compatibility gate

For `existing_eks`, complete this read-only gate before planning any
application prerequisite or Kubernetes mutation:

1. require the cluster to be `ACTIVE`, bind its exact ARN/name/Region/context,
   and require the Kubernetes minor version supported by the signed
   `prerequisites.lock.json` (1.34 for `.23.30`);
2. inventory EKS add-ons, CNI/network-policy enforcement, Pod Identity or IRSA,
   DNS, metrics API, admission webhooks, storage drivers, load-balancer
   controller, observability, and cluster/node autoscaling;
3. require healthy compatible KEDA, metrics-server, Kyverno with
   `policies.kyverno.io/v1`, External Secrets when selected, EBS/EFS CSI,
   NVIDIA device plugin for the signed GPU model profile, and AWS Load Balancer
   Controller when an AWS-managed endpoint is selected;
4. compare every prerequisite and EKS add-on with the signed lock. An existing
   different version needs explicit target compatibility evidence and its own
   reviewed change; do not silently upgrade, downgrade, reinstall, or adopt a
   shared controller;
5. prove enough multi-AZ system, scan, and GPU capacity, compatible labels and
   taints, encrypted node roots, ephemeral storage, quotas, and a node
   autoscaler capable of satisfying the approved pod ceilings;
6. require a new encrypted PostgreSQL 16 database/schema on Amazon RDS or
   Aurora PostgreSQL, with a hostname verified by the checksum-pinned AWS RDS
   CA bundle, backups/PITR, monitoring, and no Ore Heaphound migration ledger;
7. require a new durable Object Lock evidence bucket, exact read-only source
   identities, an encrypted RWX model volume/claim, and the approved secret
   delivery mechanism;
8. require a new dedicated namespace labeled for the locked Kubernetes Pod
   Security `restricted` version, plus explicit ResourceQuota/LimitRange when
   customer policy requires them;
9. render and server-dry-run every namespaced and cluster-scoped object,
   including the exact namespace-constrained `ImageValidatingPolicy`, and
   prove it does not collide with or broaden another tenant's policy; and
10. record every existing shared prerequisite as customer-owned, with its
    owner, version, health evidence, allowed changes, and exclusion from Ore
    Heaphound rollback/decommission.

Return `BLOCKED_EXISTING_EKS_INCOMPATIBLE` if a mandatory capability is absent,
unsupported, unhealthy, unowned, ambiguous, or cannot be validated without a
shared-platform mutation that is not in an approved plan. A shared cluster is
allowed only when namespace, identity, admission, capacity, network, storage,
and cost isolation meet this gate.

The current production chart contract is AWS-specific at the database TLS
boundary: `production.enabled: true` requires
`/etc/ssl/certs/aws-rds-global-bundle.pem`. A non-RDS PostgreSQL service needs
a separately implemented and qualified release/profile; the agent must not
work around this check or weaken `verify-full` TLS.

## Customer prerequisite/bootstrap boundary

The public deployment kit does not ship a generic executable customer
bootstrap Terraform root. The source repository's
`infra/release-state-bootstrap` is exclusively for Rapticore-owned release
publishing and explicitly forbids customer deployment state. Never use it for
a customer installation.

In `new_eks` mode, before `infra/aws-central` can plan, require either an
existing compliant customer-owned bootstrap set or a separately reviewed
customer bootstrap plan. That ownership boundary must provide:

- a private, versioned, TLS-only, KMS-encrypted Terraform state bucket and an
  approved locking mechanism/key;
- distinct customer KMS keys required by policy;
- the exact empty KMS-encrypted Secrets Manager object at
  `/<deployment-name>/operator`, with zero secret versions;
- a versioned, KMS-encrypted synthetic source bucket containing no production
  data; and
- qualification/evidence buckets with Object Lock and retention where the
  selected evidence policy requires them.

The bootstrap state remains the sole Terraform owner of the operator-secret
metadata. It must not create a secret value. AWS central may look up metadata
only and must never import, own, re-key, delete, or read that value.

If neither approved existing prerequisites nor an exact reviewed bootstrap
plan is available, return `BLOCKED_CUSTOMER_BOOTSTRAP_PLAN_MISSING`. Do not
improvise these durable resources with ad hoc CLI calls or local Terraform
state. If generated prerequisites are selected, include the bootstrap saved
plan and its digest in the single decision packet. Because central planning
depends on those resources, also bind a strict central-plan contract, resource
bounds, and cost ceiling; after bootstrap apply, continue only if the fresh
central plan matches that contract exactly.

In `existing_eks` mode, do not use AWS central. Require one or more exact
customer-owned application-prerequisite plans or verified existing shared
services that provide the following fresh application dependencies:

- the new RDS/Aurora PostgreSQL 16 database/schema and
  migration/runtime/web/verification privilege bootstrap path;
- the empty operator secret and its encryption/delivery path, or a customer-
  approved non-echoing creation mechanism for the Kubernetes `existingSecret`;
- rotation-aware migration component delivery through that Secret, including
  `SDDP_MIGRATION_DATABASE_HOST`, `SDDP_MIGRATION_DATABASE_PORT`,
  `SDDP_MIGRATION_DATABASE_USERNAME`, `SDDP_MIGRATION_DATABASE_PASSWORD`, and
  the separate runtime/web/verification role credentials required by the
  selected production features;
- application-specific control-plane, scan-worker, verification-preview, and
  optional remediation workload identities with exact source/evidence scope;
- the Object Lock anchor/evidence bucket, access-log destination when needed,
  model RWX volume/claim, backup/restore controls, and selected endpoint/DNS
  resources;
- the new restricted namespace and any application-specific SecretStore,
  ExternalSecret, Pod Identity/IRSA associations, and storage objects; and
- only those missing shared-cluster prerequisites the platform owner explicitly
  approved the installer to create or change.

Every prerequisite plan must state what it owns and what remains shared. The
Ore Heaphound plan must never take Terraform or Helm ownership of an existing
shared controller, add-on, VPC, cluster, node group, storage class, ingress
class, DNS zone, KMS key, or secret object merely because the chart can use it.
If these prerequisite plans or ownership records are missing, return
`BLOCKED_EXISTING_EKS_PREREQUISITE_PLAN_MISSING`.

## Prepare the private configuration

Use Terraform exactly `1.15.8` for every released or customer Terraform plan,
the matching provider locks, Helm 3, `kubectl`, AWS CLI v2.7.0 or newer, `jq`,
and Cosign. Keep the public kit unchanged.

For `new_eks`, create private copies of:

- `infra/aws-central/terraform.tfvars.example`;
- `values/central-eks.yaml`; and
- the fresh-only values block above plus the customer-specific overlay.

Add an empty `backend "s3" {}` block only to the private Terraform working
copy and initialize it with exact customer-owned backend coordinates. Never
use local state. Resolve all applicable `auto`, null, example, and `REPLACE_*`
markers. Configuration may contain non-secret resource references but not
credentials or secret values.

For `existing_eks`, do not copy, initialize, plan, or apply
`infra/aws-central`. Create the private application values from
`values/central-eks.yaml`, the fresh-only block, and an existing-cluster
overlay that binds the exact customer-provided database, secret delivery,
anchor bucket, service-account identities, model claim/storage class, node
placement, endpoint, and source scopes. The production overlay must keep
`database.migrationJob.credentialMode: components`, set the exact fresh
database name, and use the default component-key contract listed above. URL
credential mode is forbidden when `production.enabled: true`; it is not a
fallback for an incomplete customer Secret. The operator Secret must also
provide `SDDP_DATABASE_URL`, `SDDP_RUNTIME_ROLE_PASSWORD`, and the distinct
web/verification or selected optional-role credentials required by the
rendered features. Never weaken the separate migration, runtime, web,
verification, and optional remediation database-role boundary.

Render from the locally verified chart package in this order:

1. released `values/central-eks.yaml`;
2. the fresh-only block above;
3. selected released functional overlays, such as remediation or bounded
   high-throughput capacity, only when explicitly selected; and
4. the customer-private overlay.

Helm's last value wins. Record every input SHA-256 and the final sanitized
render SHA-256. Reject mutable images, unresolved markers, disabled default-
deny policy, missing PodDisruptionBudgets, weakened TLS, broad source ranges,
secret-shaped render values, or a render where the effective occurrence
storage version is not `2`, dashboard refresh is enabled, lifecycle is enabled,
or occurrence purge is true.

## Pre-install decision packet

The packet must contain:

- resolved specification digest and sanitized guided answers;
- exact release, manifest, kit, image, chart, detector, model, prerequisite,
  capability, and migration identities;
- selected `new_eks` or `existing_eks` lane, live cloud/cluster identities, and
  collision-proof target inventory;
- bootstrap and application-prerequisite plan digests or verified shared-
  prerequisite evidence, with an explicit ownership matrix;
- for `new_eks`, the central saved-plan digest or strict post-bootstrap plan
  contract;
- for `existing_eks`, an explicit statement that `infra/aws-central` will not
  run, plus all customer prerequisite plan and Kubernetes action digests;
- sanitized Terraform/Kubernetes action counts with every create, update,
  delete, replace, cluster-scoped object, and shared-platform exclusion;
- Helm input and render digests plus effective safety-critical values;
- source/read identity scopes and explicit statement that remediation is off,
  unless selected;
- endpoint/DNS intent and exact CIDRs;
- capacity assumptions, service quotas, estimated monthly cost, and ceiling;
- bounded synthetic smoke and every optional test selected;
- qualification intent and exact profile, detector-promotion evidence, all 12
  target checks, receipt destination, protected-finalizer inputs, and the
  mandatory independent reviewer gates when stable qualification is selected;
- rollback boundary, deletion-protection implications, retained resources,
  and the separate decommission requirement; and
- exact approver, change reference, approval text, timestamp, and packet
  SHA-256.

Ask one question: whether the customer approves that exact packet. Do not
mutate the target without an unambiguous approval bound to its SHA-256.

## Execution after exact approval

Perform these common steps first:

1. reverify the same identity, Region, release withdrawal status, kit bytes,
   private input digests, EKS mode/identity, state keys, collisions, shared-
   ownership inventory, and cost ceiling; and
2. apply only the exact customer bootstrap/application-prerequisite saved
   plans approved for the selected lane, then verify outputs without reading
   secret values.

For `new_eks`, continue in this order:

1. initialize the private AWS-central copy against the approved remote state,
   create a fresh saved plan, and require exact conformance to the approved
   plan or strict post-bootstrap contract;
2. run `ensure-spot-service-linked-role.sh check`, and its digest-bound `apply`
   only when the packet included that exact creation;
3. apply the exact AWS-central saved plan, then verify EKS, RDS, EFS, KMS, S3,
   IAM, backups, logging, add-ons, controllers, namespace, SecretStore, and
   ExternalSecret identities; and
4. set and reverify the exact newly created kubeconfig context.

For `existing_eks`, instead continue in this order:

1. rerun the compatibility gate and require unchanged cluster ARN/version,
   shared-controller versions/ownership, add-ons, capacity, storage, network,
   and admission posture;
2. apply only approved application-specific prerequisite plans and named
   shared-platform changes; do not apply AWS central or modify any unlisted
   shared resource;
3. create the new restricted namespace and application-specific secret,
   workload-identity, storage, and endpoint bindings through their approved
   owners; and
4. set and reverify the exact pre-existing kubeconfig context before every
   Kubernetes mutation.

Then complete the common application installation:

1. use `populate-operator-secret.sh` once only when the selected AWS/RDS
   secret path satisfies its exact rotation-aware component contract;
   otherwise use the packet-bound customer non-echoing secret creation
   process to provide every rendered component and role key. Stop on any
   existing secret value/version;
2. force/wait for External Secrets synchronization when selected, or verify
   the customer-provisioned `existingSecret`, without displaying Secret data;
3. stage the exact locked model with `stage-model-eks.sh` when the signed
   detector profile requires contextual inference, and require its exact
   verification marker and temporary-resource cleanup;
4. render again from unchanged approved inputs and install the signed
    admission chart atomically;
5. prove exact signed image identities are admitted and mutable, unsigned,
    wrong-digest, and wrong-workflow identities are denied;
6. install the signed control chart atomically and let its signed migration
    Job initialize the empty database; never execute migration SQL manually;
7. wait for every desired stable component, dependency, ExternalSecret, PDB,
    policy, KEDA object, target, and migration hook to converge;
8. reconcile public DNS only when selected, using the released helper's
    deterministic digest-bound check/apply path; and
9. run only the approved validation set, remove its exact temporary resources,
   and create fresh no-change plans for every installation-owned prerequisite
   state. For `new_eks`, this includes AWS central. For `existing_eks`, it
   excludes the customer-owned cluster and shared-platform states.

Do not run scan pause/resume, old-secret upgrade, system-node legacy
reconciliation, database-backend cancellation, repair closure, old migration
replay, or `.21`/`.22` transition steps. A fresh target has none of that state.

An `existing_eks` rollback may act only on application-owned resources named
in the approved rollback manifest. Never uninstall, downgrade, delete, or take
ownership of a shared controller, CRD, add-on, node group, storage class,
ingress class, cluster role, VPC, cluster, database service, or customer
evidence resource. Preserve the newly initialized database and retained
generated Secret unless a separate destructive plan explicitly covers them.

Install automatic signed-release reconciliation only after the initial
release is healthy, evidence is retained, and the customer explicitly selected
that operational policy. Do not enable a floating tag, in-container updater,
or mixed component release.

## Required validation

Use only the approved synthetic corpus until the installation reaches the
customer's selected readiness status. At minimum prove:

- the application, web, API, migration, database, extraction, Presidio,
  contextual model, verification-preview, worker, KEDA, and admission paths are
  healthy with stable restart counts;
- the migration ledger has exactly the signed release inventory—147 entries
  ending at `0147_scan_stalled_notification_lookup.sql` for `.23.30`—with the
  expected checksums;
- the effective API environment selects occurrence storage v2, and a new
  synthetic scan records v2 without creating legacy-only occurrence rows;
- lifecycle is absent/disabled, occurrence purge is false, remediation writes
  are absent unless selected, and dashboard refresh is disabled;
- the hardened extraction content probe uses `PUT /tika/text`; the old
  `PUT /tika` prose in `STAGING_QUALIFICATION.md` is not valid for this
  gateway. Health/metadata GET endpoints may still use their documented paths;
- `verify-private-service-flows.sh` proves the permitted private path and a
  forbidden component remains denied;
- one bounded synthetic scan discovers, extracts, detects, finalizes, reports,
  and leaves no compatible ready work unclaimed;
- worker heartbeats, database demand, KEDA targets, live replicas, processes,
  and busy slots agree; positive compatible demand with all slots idle is a
  failed capacity gate, not a successful scale-to-zero state;
- the scan worker can use native secrets, Presidio, and the exact contextual
  model identities recorded by the signed detector bundle;
- no raw values, tokens, object names, or customer content appear in logs,
  events, reports, or evidence;
- database encryption/PITR/deletion protection, model/source/evidence storage
  encryption, Object Lock, backups, EKS control-plane and workload telemetry,
  TLS, HSTS when public, MFA, and network policies match the packet;
- in `existing_eks`, every shared prerequisite is still healthy, customer-
  owned, and unchanged unless its exact mutation was approved; the application
  remained inside its namespace, identity, admission, network, storage, and
  capacity boundaries; and
- every installation-owned Terraform plan is no-change, the live Helm release
  matches the approved render and values digests, and all exact temporary test
  resources are gone.

When a connector was selected, create only its synthetic test scope, configure
its read profile, run **Save, test and activate**, and prove one version-bound
read. Do not add production sources or write/remediation credentials merely to
complete platform installation. Google identity must remain keyless when that
was the approved mode; Slack source and notification credentials remain
separate.

Restore, interruption, fault-injection, migration-failure, remote-worker, and
synthetic-remediation tests run only when selected in the approved packet.

## Complete governed qualification

For `stable_qualification`, continue after installation readiness without a
new customer permission prompt because the exact sequence and its destinations
were bound into the approved decision packet:

1. require the target to match `aws-eks-single-tenant-v1` exactly. A shared
   existing EKS cluster is eligible for fresh installation readiness but not
   this single-tenant qualification; return
   `BLOCKED_QUALIFICATION_PROFILE_MISMATCH`. A dedicated compatible existing
   customer EKS cluster or the dedicated `new_eks` lane may proceed;
2. reverify that the unchanged release is an immutable stable tag and that its
   detector bundle has a signed promotion record with approvals from at least
   two distinct authorized people, including one quality reviewer and one
   release reviewer;
3. run every check in `release/qualification/aws-eks-v1.json` against the exact
   release, target ID, Region, workload identities, and approved synthetic
   corpus; never omit or weaken a check because an optional product feature is
   disabled;
4. generate exactly 12 create-only canonical passing receipts in the
   customer-approved CI jobs, bound to the common release-manifest digest,
   source commit, image and detector digests, target, workflow identity, and
   value-free evidence hashes;
5. fail closed as `BLOCKED_QUALIFICATION_CHECK_FAILED` if any check fails, any
   assertion or evidence kind is absent, the receipts disagree, the target or
   release changes, or sensitive values appear in retained evidence;
6. copy the already verified manifest, signature bundle, and exactly 12
   receipts to the packet-bound qualification input prefix, then dispatch
   `.github/workflows/eks-qualification.yml` from `main` with the exact
   finalizer inputs recorded in the packet;
7. wait for the mandatory `production-qualification` protected-environment
   reviewer decision without turning that governance gate into repeated chat
   questions or bypassing, self-approving, or weakening it;
8. independently verify the resulting Sigstore-signed qualification index,
   rebuild it offline from the manifest and receipts, require a byte-for-byte
   match with zero failures, and verify the S3 Object Lock COMPLIANCE custody
   receipt, object versions, hashes, encryption, and retain-until dates; and
9. report `QUALIFIED` only for that named release, profile, target, and Region.
   Any other target or material release/configuration change requires new live
   evidence and a new protected qualification package.

A stable candidate that is healthy but has not completed all steps remains
`READY_FOR_QUALIFICATION`. A develop prerelease remains
`READY_FOR_REHEARSAL`; no receipt or approval can convert its tag into stable.

## Result and report

Return exactly one of these statuses:

- `READY_FOR_REHEARSAL`: a develop prerelease is healthy on the selected new
  application target (`new_eks` or `existing_eks`) and the bounded synthetic
  gates passed;
- `READY_FOR_QUALIFICATION`: the exact stable candidate is healthy and awaits
  independent qualification/finalization;
- `QUALIFIED`: reported as `QUALIFIED_FOR_NAMED_TARGET` in prose, and only when
  the signed stable release, promoted detector bundle, 12 passing target-bound
  receipts, protected signed index, and Object Lock custody record all verify;
- `ROLLED_BACK`: the approved deployment did not converge and only documented,
  installation-owned reversible actions were undone; or
- `BLOCKED_*`: a named fail-closed condition prevented safe completion.

Store one sanitized, access-controlled report outside `/tmp` containing the
decision-packet digest, exact identities and artifact digests, plans/renders,
effective critical values, migration ledger, validation outcomes, cost
comparison, resource inventory, retained/deletion-protected resources,
automatic-reconciliation state, every deviation, and final status. Do not
include secret or customer data.

Deployment approval does not authorize removal. Decommissioning requires a
later exact destructive plan and separate approval under phase I of
`STAGING_QUALIFICATION.md`.
