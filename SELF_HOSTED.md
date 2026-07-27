# Ore Heaphound self-hosted deployment

This repository contains the versioned customer deployment kit. Rapticore
publishes signed containers and OCI Helm charts; the application, database,
workers, model weights, credentials, evidence, and cloud resources run only in
customer-owned accounts.

## Supported v1 topology

- Central control plane: Amazon EKS in three availability zones.
- Remote execution: GKE and AKS reference stacks.
- Other clouds: any conformant Kubernetes cluster that can provide KEDA,
  outbound TLS 1.3 connectivity, a ReadWriteMany model volume, and the common
  node labels described below.
- Stable services use on-demand nodes. Scan workers and Ollama GPU pods prefer
  Spot and scale to zero. An on-demand elastic fallback can be disabled when
  jobs should wait for Spot capacity.

Remote workers have no inbound Service and no PostgreSQL credentials. They open
an outbound mTLS stream to the customer-owned EKS gateway.

## Data-path decision

Each central pool policy must explicitly set `allow_brokered_reads`.

- `false`: only deployment-managed cloud identity may read source content in
  the remote cloud.
- `true`: UI-managed access profiles may stream version-bound source bytes
  through the central EKS gateway. The gateway does not persist these bytes,
  but they cross cloud boundaries and may incur egress or residency impact.

Do not claim that all source content remains local when brokered reads are
enabled.

## Public release versus private customer configuration

The public repository contains signed, immutable release coordinates and
reusable infrastructure templates. Keep every customer-specific value in a
separate private overlay delivered through the customer's approved secure
channel:

- `infra/*/terraform.tfvars` for account, project, subscription, network, and
  source-storage identifiers;
- `values/<customer>-customer.yaml` for domains, role identities, pool policy,
  storage classes, and sizing; and
- the customer's secret manager for credentials, private keys, tokens, and
  database connection material.

Both `terraform.tfvars` and `values/*-customer.yaml` are ignored by this
repository. Do not commit customer overlays, Terraform state, kubeconfigs, or
credentials to either `main` or a release tag. Start an overlay by copying the
matching released values file, then store and review that copy in the
customer's private configuration repository.

## 1. Select and verify a release

Check out an immutable release tag, not `main`:

```sh
git clone https://github.com/rapticore/ore-heaphound-deploy.git
cd ore-heaphound-deploy
git checkout vX.Y.Z
. ./release.env
```

Verify the signed release manifest:

```sh
cosign verify-blob \
  --bundle release-manifest.sigstore.json \
  --certificate-identity \
    "https://github.com/rapticore/ore_heaphound/.github/workflows/release.yml@refs/tags/vX.Y.Z" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  release-manifest.json
```

Confirm that the convenience environment file did not diverge from that signed
manifest:

```sh
test "$APPLICATION_IMAGE" = \
  "$(jq -r '.images[] | select(.component=="application") | .reference+"@"+.digest' release-manifest.json)"
test "$EXTRACTION_IMAGE" = \
  "$(jq -r '.images[] | select(.component=="extraction") | .reference+"@"+.digest' release-manifest.json)"
```

Verify both signed top-level image indexes before use:

```sh
for image in "$APPLICATION_IMAGE" "$EXTRACTION_IMAGE"; do
  cosign verify \
    --certificate-identity \
      "https://github.com/rapticore/ore_heaphound/.github/workflows/release.yml@refs/tags/vX.Y.Z" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "$image"
done
```

Then verify the per-platform BuildKit provenance and SPDX SBOMs using the
parent-index algorithm in phase C of
[STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md). BuildKit represents these
as `unknown/unknown` attestation-manifest siblings in the signed
multi-platform index, associated to child platform digests by
`vnd.docker.reference.digest`. A child-digest referrers lookup or
`cosign verify-attestation` alone can return no results and must not be used to
declare these attestations absent. Registry throttling, authorization errors,
timeouts, and DNS failures are access failures, not missing-artifact evidence.

Verify every OCI chart digest, then pull the versioned packages and compare
their bytes with the signed release manifest:

```sh
for spec in \
  "${CONTROL_PLANE_CHART#oci://}@${SDDP_DIGEST}" \
  "${EXECUTION_PLANE_CHART#oci://}@${SDDP_EXECUTION_PLANE_DIGEST}" \
  "${ADMISSION_CHART#oci://}@${SDDP_ADMISSION_DIGEST}"; do
  cosign verify \
    --certificate-identity \
      "https://github.com/rapticore/ore_heaphound/.github/workflows/release.yml@refs/tags/vX.Y.Z" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "$spec"
done
mkdir -p charts
helm pull "$CONTROL_PLANE_CHART" --version "$RELEASE_VERSION" --destination charts
helm pull "$EXECUTION_PLANE_CHART" --version "$RELEASE_VERSION" --destination charts
helm pull "$ADMISSION_CHART" --version "$RELEASE_VERSION" --destination charts
jq -r '.artifacts.helm_charts[] | "\(.sha256)  charts/\(.name)"' \
  release-manifest.json | sha256sum -c -
```

Use these locally verified chart packages in every install below. The values in
this release tag use immutable image digests. `latest` is only a discovery
alias and must not be placed in production values.

## 2. Build the central AWS infrastructure

Authenticate to the customer AWS account, copy the example variables, and use
an encrypted remote state backend. Use Terraform exactly `1.15.8` and AWS CLI
v2.7.0 or newer; the exec credential plugins obtain a fresh EKS token only
after the cluster is ready.

Before planning AWS central, complete the separately reviewed prerequisite
bootstrap procedure in [STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md).
That state must own the exact empty KMS-encrypted operator secret selected by
`operator_secret_name`. AWS central intentionally fails planning when the
object is absent and never imports it. Verify only its metadata and keep its
value out of Terraform and command output.

For a fresh installation, continue directly to Terraform planning below. For
an existing healthy develop.7 rehearsal with a `2/2/6` system node group, do
not apply a plan that represents `3/2/6`. The pinned EKS module intentionally
ignores post-creation desired-size drift. Follow the two separately approved
steps in
[Reconcile an existing develop rehearsal](STAGING_QUALIFICATION.md#reconcile-an-existing-develop-rehearsal):

1. run the released `reconcile-system-node-capacity.sh check` mode and obtain
   approval for its exact canonical request digest;
2. run its approval-bound `apply` mode to reach `2/3/6`; and
3. only then create a fresh Terraform plan whose sole resource change reaches
   `3/3/6`.

The helper does not authorize Terraform apply, model staging, or workload
installation.

```sh
test "$(terraform version -json | jq -r .terraform_version)" = "1.15.8"

cd infra/aws-central
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform show -json tfplan >private-tfplan.json

# Do not print matching values. Any match makes the plan unsafe to apply.
jq -e \
  '[.. | strings | select(startswith("k8s-aws-v1."))] | length == 0' \
  private-tfplan.json >/dev/null
jq -e \
  '[.. | objects | .address? | strings |
    select(startswith("data.aws_eks_cluster_auth."))] | length == 0' \
  private-tfplan.json >/dev/null

terraform apply tfplan
aws eks update-kubeconfig \
  --region "$(terraform output -raw region 2>/dev/null || echo us-west-2)" \
  --name "$(terraform output -raw cluster_name)"
cd ../..
```

Keep the binary and JSON plans private until apply completes, then remove them.
Neither file is qualification evidence; retain a sanitized plan summary and
its SHA-256 digest instead.

The stack creates:

- private EKS worker subnets and a stable three-node system pool sized for a
  concurrent application rollout;
- Karpenter CPU and GPU Spot pools plus optional on-demand fallback pools;
- encrypted Multi-AZ PostgreSQL with 35-day PITR and deletion protection;
- a KMS-encrypted S3 Object Lock bucket;
- encrypted EFS model storage; and
- separate IRSA roles for inventory/anchor writes and source-object reads; and
- KEDA, metrics-server, and the required CSI drivers;
- pinned Kyverno, External Secrets, and NVIDIA device-plugin releases;
- six EKS managed add-ons pinned to `prerequisites.lock.json`;
- an immutable evaluated Karpenter AL2023 AMI selector;
- a metadata-only reference to the bootstrap-owned encrypted operator
  Secrets Manager object and exact-resource Pod Identity; and
- the `sddp` namespace, SecretStore, and ExternalSecret binding.

Set the EKS API allowlist to administrator/CI addresses only. The GKE reference
uses private nodes and therefore requires Private Google Access plus Cloud NAT
on its supplied subnet; its public control-plane endpoint is likewise CIDR
allowlisted. AKS uses a private control plane, so run Terraform and Helm from a
network with private DNS and routing to that cluster.

Review NAT, database, EFS/Filestore, GPU, and fallback-node costs before apply.
The infrastructure modules deliberately use deletion protection and
`prevent_destroy` for evidence storage.

## 3. Populate the operator secret and stage the model

The prerequisite/bootstrap state is the sole owner of the empty encrypted
operator object. AWS central references its metadata but never imports,
re-keys, deletes, or reads its value. It creates the namespace and
external-secret binding. Populate the object without exposing values to the
terminal or Terraform.

```sh
customer-deploy/scripts/populate-operator-secret.sh \
  "$(terraform -chdir=infra/aws-central output -raw region)" \
  "$(terraform -chdir=infra/aws-central output -raw database_endpoint)" \
  "$(terraform -chdir=infra/aws-central output -raw database_name)" \
  "$(terraform -chdir=infra/aws-central output -raw database_master_secret_arn)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_arn)" \
  "$(terraform -chdir=infra/aws-central output -raw operator_secret_kms_key_arn)"

kubectl -n sddp wait \
  --for=condition=Ready externalsecret/ore-heaphound-operator \
  --timeout=5m

```

After the customer explicitly accepts the exact license in `model.lock.json`,
resolve the EFS identifier into a private temporary manifest and run the
released helper:

```sh
sed "s/REPLACE_EFS_FILE_SYSTEM_ID/$(terraform -chdir=infra/aws-central output -raw model_efs_id)/" \
  manifests/model-pvc-eks.yaml > /secure/customer-config/model-pvc.resolved.yaml

export ORE_HEAPHOUND_MODEL_LICENSE_ACCEPTED=true
export ORE_HEAPHOUND_EXPECTED_CONTEXT="$(kubectl config current-context)"
scripts/stage-model-eks.sh \
  /secure/customer-config/model-pvc.resolved.yaml
unset ORE_HEAPHOUND_MODEL_LICENSE_ACCEPTED ORE_HEAPHOUND_EXPECTED_CONTEXT
```

The helper refuses unresolved manifests, a context mismatch, or a non-empty
claim. Its temporary, credentialless Job verifies the registry manifest, model
layer, license layer, and exact sizes before atomically publishing `store/`.
Failure removes the partial staging directory; success or failure removes the
temporary Job, NetworkPolicy, and ServiceAccount. Runtime pods mount only
`store/`, with `readOnly: true` enforced on both the container mount and PVC
volume source, and have no model-download egress. Rapticore does not distribute
model weights.

Keep `acceptModelLicenses: false` in the released values file. Only the
customer-approved private values overlay may set it to true.

The synchronized `sddp-production-operator-secrets` contains at least:

- `SDDP_DATABASE_URL`, built from the RDS endpoint and the AWS-managed master
  secret, using TLS verification;
- any cloud/source credentials that cannot use workload identity; and
- notification or SSO secrets enabled in the selected values.

Central GCS enumeration is optional. When enabled from EKS, create the
keyless AWS-to-Google workload-federation credential configuration described in
the source chart's EKS deployment guide and set
`config.gcs.credentialsConfigSecret`; remote GKE execution does not require the
central EKS pods to hold GCS read authority.

The chart's retained bootstrap Job creates application encryption/signing keys,
role tokens, and `SDDP_KEDA_TOKEN` once. Back up the retained generated Secret
using the customer's approved encrypted secret-backup process.

## 4. Install the central charts

Replace the remaining `REPLACE_*` deployment coordinates in
`values/central-eks.yaml`, then render before applying:

```sh
helm template ore-heaphound "charts/sddp-admission-${RELEASE_VERSION}.tgz" \
  --namespace sddp \
  -f values/admission.yaml \
  >/tmp/admission.yaml
helm template ore-heaphound "charts/sddp-${RELEASE_VERSION}.tgz" \
  --namespace sddp \
  -f values/central-eks.yaml >/tmp/control-plane.yaml

helm upgrade --install ore-heaphound-admission \
  "charts/sddp-admission-${RELEASE_VERSION}.tgz" \
  --namespace sddp --create-namespace \
  -f values/admission.yaml
helm upgrade --install ore-heaphound "charts/sddp-${RELEASE_VERSION}.tgz" \
  --namespace sddp \
  -f values/central-eks.yaml \
  --atomic --timeout 20m
```

Expose the web/API endpoint through the customer's ingress and expose the
worker gateway through a TLS pass-through NLB. The gateway certificate Secret
contains `tls.crt`, `tls.key`, and a dedicated client `ca.crt`.

## 5. Add GKE or AKS remote execution

Apply `infra/gke-execution` or `infra/aks-execution`. Both create:

- a stable system pool for the remote scaler bridge;
- CPU and GPU Spot pools that scale from zero;
- optional on-demand fallback pools;
- workload identity scoped to approved source storage; and
- KEDA and network-policy support.

Create a client certificate with:

- a maximum 90-day lifetime;
- a subject exactly matching one central pool policy;
- client-auth extended key usage; and
- a chain to the gateway's dedicated client CA.

Create the remote Secret with `tls.crt`, `tls.key`, `ca.crt`, and an independent
32-byte-or-longer `SDDP_KEDA_TOKEN`. Alert on
`sddp_remote_client_certificate_expiry_timestamp_seconds` at 14 days remaining.
Rotate by replacing the Secret with an overlapping certificate and performing a
rolling restart; the pool subject remains unchanged.

Example central policy:

```yaml
remoteGateway:
  enabled: true
  tlsSecret: sddp-worker-gateway-tls
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: nlb
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  pools:
    - id: gcp-prod
      certificate_subject: sddp-gcp-prod
      placements: [gcp]
      kinds: [detect]
      build_digest: sha256:REPLACE
      detector_bundle: REPLACE_WITH_RELEASE_BUNDLE_AND_MANIFEST
      allow_brokered_reads: false
      enabled: true
```

When remote egress addresses are stable, also set
`remoteGateway.service.loadBalancerSourceRanges` to those exact CIDRs. mTLS and
the certificate-to-pool mapping remain mandatory even with an IP allowlist.

Install the remote chart:

```sh
helm upgrade --install ore-heaphound-gcp \
  "charts/sddp-execution-plane-${RELEASE_VERSION}.tgz" \
  --namespace sddp --create-namespace \
  -f values/execution-gke.yaml \
  --atomic --timeout 20m
```

Use `execution-aks.yaml` for AKS. `execution-kubernetes.yaml` is the generic
profile. If that cluster has no deployment-owned cloud identity for the source,
its matching central pool must set `allow_brokered_reads: true`; source bytes
then traverse the central gateway as disclosed above. Its nodes must carry:

- `rapticore.io/workload=system|scan|llm`
- `rapticore.io/capacity=spot|on-demand`
- matching `rapticore.io/workload` `NoSchedule` taints on elastic nodes.

## Scaling behavior

KEDA selects the largest replica recommendation from queue count, estimated
ready bytes, and oldest-ready age:

- workers: 50 units or 1 GiB per replica, 0–20 replicas;
- LLM: 40 units or 4 GiB per replica, 0–4 replicas; and
- ready age: five minutes.

Unknown-size work still scales on count and age. Cloud node autoscalers then
provision nodes for the requested pods. Spot is expressed as preferred
affinity; when fallback is enabled, on-demand pools can satisfy pods after Spot
capacity fails.

## Operations

- Monitor queue count, ready bytes, age, dead letters, KEDA errors, pending
  pods, Spot interruptions, model cold-start time, gateway connectivity, and
  certificate expiry.
- Test an RDS point-in-time restore and retained Secret restore before go-live.
- Upgrade one SemVer release at a time with `--atomic`; migrations run in the
  chart's bounded pre-upgrade Job. Roll back application workloads only to a
  release compatible with the applied database migration.
- Never delete or recreate the Object Lock bucket as part of an application
  uninstall. Use phase I of
  [STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md) for the independently
  authorized operational teardown and later post-retention purge.
- Before enabling production, run a 100 GB synthetic scan and interrupt worker,
  GPU, gateway, and network capacity. Work must be reclaimed without lost or
  duplicate findings.

No Rapticore-hosted API, database, worker, telemetry endpoint, or customer data
path is required by this deployment.

For a representative customer-owned staging install, live failure testing, and
the signed 12-receipt qualification process, continue with
[STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md). To have an approved
terminal-capable LLM agent operate that walkthrough, give it the runbook and
let it conduct the guided intake. The agent uses
[AGENT_DEPLOYMENT_SPEC.example.yaml](AGENT_DEPLOYMENT_SPEC.example.yaml) as an
internal schema and generates collision-checked defaults; the customer does
not edit YAML. Decommission remains a separate, explicitly approved interview
and phase I operation.
