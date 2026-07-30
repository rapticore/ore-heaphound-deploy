# Automatic signed-release reconciliation

Ore HeapHound can update API, web, central scan workers, extraction, and other
control-chart workloads without an operator pushing each Deployment. The
released reconciler is deliberately external to the product namespace: it runs
under a customer-owned installation identity and advances the complete signed
release unit. No runtime container watches mutable tags or grants itself cloud
administration.

## Standing policy

`scripts/reconcile-signed-release.sh` has three modes:

- `check` discovers the newest release in the selected channel and verifies the
  annotated public tag, signed deployment archive, signed manifest, image
  signatures, withdrawal list, detector bundle, and release identity.
- `plan` additionally verifies the signed OCI charts, creates a fresh full
  Terraform plan, and renders both the current and candidate control releases.
- `apply` is suitable for a customer-owned scheduled runner only after the
  customer records `ORE_HEAPHOUND_AUTOMATIC_APPLY=true`.

Automatic apply is intentionally narrower than an installation-agent upgrade.
It proceeds only when Terraform reports **zero changes** and the candidate
retains the same detector bundle, qualification posture, capability catalog,
model lock, prerequisite lock, third-party admission images, database migration
inventory, and normalized control-plane render. Only signed
application/extraction digests and release labels may differ. Any
infrastructure, access, detector/model, capacity, network, schema, or maturity
change stops and produces an installation-agent handoff. It never applies a
partial release.

Before Helm changes, apply verifies the approved RDS instance is available,
Single-AZ, and has no pending modifications, then creates and waits for a manual
snapshot. Admission is upgraded first with exactly two allowed release
identities: the running release and the candidate. This permits the control
chart's atomic rollback to recreate the prior image. The next successful
reconciliation replaces that overlap; branch and wildcard identities remain
invalid.

## Customer configuration

Copy this example to a customer-owned, permission-restricted path outside the
release checkout. Do not store credentials in it:

```sh
ORE_HEAPHOUND_RELEASE_CHANNEL=develop
ORE_HEAPHOUND_NAMESPACE=sddp
ORE_HEAPHOUND_CONTROL_RELEASE=ore-heaphound
ORE_HEAPHOUND_ADMISSION_RELEASE=ore-heaphound-admission

ORE_HEAPHOUND_PRIVATE_VALUES=/secure/ore-heaphound/values/production.yaml
ORE_HEAPHOUND_PRIVATE_ADMISSION_VALUES=/secure/ore-heaphound/values/admission.yaml
ORE_HEAPHOUND_TERRAFORM_VARS=/secure/ore-heaphound/terraform/production.tfvars
ORE_HEAPHOUND_TERRAFORM_BACKEND_CONFIG=/secure/ore-heaphound/terraform/backend.hcl

ORE_HEAPHOUND_RDS_INSTANCE_ID=ore-heaphound-1e2a4e73
ORE_HEAPHOUND_EXPECTED_DB_CLASS=db.m8g.4xlarge
ORE_HEAPHOUND_RECONCILER_STATE_DIR=/var/lib/ore-heaphound-release
ORE_HEAPHOUND_HEALTH_URL=https://heaphound.example.com/healthz
ORE_HEAPHOUND_AUTOMATIC_APPLY=true
ORE_HEAPHOUND_REMOTE_EXECUTION_PLANES=false
ORE_HEAPHOUND_ROLLOUT_TIMEOUT=30m
```

The runner needs short-lived customer credentials for read/write access to the
existing Terraform state, RDS snapshot creation, EKS authentication, and the
existing Helm releases. Prefer customer CI OIDC or an instance role. It also
needs pinned `aws`, `cosign`, `curl`, `git`, `helm`, `jq`, `kubectl`,
`sha256sum`, `tar`, and Terraform `1.15.8`.

## Bootstrap from develop.21

Bootstrap the reconciler only after the installation agent has successfully
installed `v0.1.0-develop.21`, cleared the former rollback KEDA pause, and
validated the paused-scan resume fix. The first reconciler-bearing release is
`v0.1.0-develop.22`; install it as one final agent-managed upgrade:

1. Verify the `.22` annotated tag, signed manifest and archive, image and chart
   signatures, checksums, provenance/SBOMs, unchanged detector/model/capability
   posture, and migration inventory. Do not use a locally copied script from
   `develop`.
2. Create a fresh full Terraform plan with the persistent production backend
   and variables. It must report zero changes and preserve the current
   Single-AZ RDS instance and S3 gateway endpoint. Stop otherwise.
3. Create and wait for the required pre-upgrade RDS snapshot.
4. Upgrade the signed `.22` admission chart first. Use its released
   `values/admission.yaml` and add exactly the `.21` release workflow identity
   as `policy.signerSubjects[0]`; the released singular `signerSubject` already
   names `.22`. Prove both `.21` and `.22` signed application images pass a
   server-side dry-run.
5. Upgrade the signed `.22` control chart with the persistent private values,
   exact `.22` image digests, `--atomic`, and the production timeout. The
   database migration inventory remains at `0074`; any new migration is a stop
   condition. Wait for all Deployments and confirm API, web, workers,
   extraction, Presidio, Ollama, remediation, verification preview, Settings
   worker status, and the resumed scan remain healthy.
6. Copy the verified `.22` reconciler and example systemd units into the
   customer-owned installation host, create the restricted service identity,
   and populate the non-secret configuration below. Do not run it inside an
   application container or grant the product ServiceAccounts Terraform/RDS
   administration.

First run read-only modes:

```sh
customer-deploy/scripts/reconcile-signed-release.sh check \
  /secure/ore-heaphound/automatic-release.env
customer-deploy/scripts/reconcile-signed-release.sh plan \
  /secure/ore-heaphound/automatic-release.env
```

Then schedule `apply` every 15 minutes under a runner-level singleton/concurrency
lock:

```sh
customer-deploy/scripts/reconcile-signed-release.sh apply \
  /secure/ore-heaphound/automatic-release.env
```

For a dedicated customer installation host, the release kit includes hardened
example units under `systemd/`. The installation agent copies the verified
reconciler to `/opt/ore-heaphound-release/`, creates the unprivileged
`ore-heaphound-reconciler` service identity, restricts the configuration and
state directories to that identity, installs both units in `/etc/systemd/system`,
and enables `ore-heaphound-release-reconciler.timer`. If the customer instead
uses CI, configure the equivalent 15-minute schedule and a concurrency group
that cancels neither an active plan nor an active apply.

The script also takes an atomic lock in its persistent state directory. A lock
is never stolen automatically. If the runner dies, the installation agent must
prove no reconciliation is active before removing that exact stale directory.
Successful runs leave `last-success.json`; logs and Terraform plan summaries
must be retained in the customer's normal deployment evidence store.

Remote GKE/AKS execution releases are not silently advanced by this central EKS
reconciler. If they are installed, keep automatic apply disabled until a
customer-owned orchestrator plans and upgrades every registered execution plane
as the same release unit.
