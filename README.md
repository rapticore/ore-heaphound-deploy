# Ore Heaphound self-hosted deployment

This public kit deploys Ore Heaphound entirely into customer-owned cloud
accounts and Kubernetes clusters. Rapticore publishes signed containers and
Helm charts but does not host the runtime, control plane, customer data,
credentials, or model weights.

Start with [SELF_HOSTED.md](SELF_HOSTED.md). For the customer-owned staging
walkthrough and the evidence required before a release can be called qualified,
use [STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md).
For the streamlined production endpoint, resilience, backup, observability,
DNS/ACM, and one-approval agent workflow, use
[PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md).
For a design-partner engagement on the partner's own data with governed
remediation enabled, use [DESIGN_PARTNER.md](DESIGN_PARTNER.md); it layers the
remediation infrastructure, values, walkthrough, and scope statement on top of
the production runbook.
For an LLM-operated walkthrough, give the agent that runbook. It asks the
customer a short guided set of questions, proposes collision-checked defaults,
and generates the internal execution record from
[AGENT_DEPLOYMENT_SPEC.example.yaml](AGENT_DEPLOYMENT_SPEC.example.yaml);
the customer does not complete YAML. The same runbook contains phase I, the
separately authorized LLM procedure for operational uninstall and eventual
post-retention removal.

Fresh AWS installations obtain Kyverno, External Secrets, the NVIDIA device
plugin, AWS Load Balancer Controller, seven EKS managed add-ons, and the
evaluated EKS AMI from
[prerequisites.lock.json](prerequisites.lock.json). The prerequisite bootstrap
state is the sole owner of the encrypted empty operator-secret
object; AWS central performs metadata-only lookup and creates the
least-privilege synchronization path. Secret values remain outside Terraform
and are populated with the released non-echoing helper. The exact model,
license layer, staging image, and content digests are locked in
[model.lock.json](model.lock.json); the released staging helper publishes an
atomically verified store that runtime pods mount read-only. Existing develop
rehearsals should normally use the runbook's approval-bound system-node helper
followed by a fresh saved-plan reconciliation, not decommission and recreation.

For a normal production deployment, the customer approves one reviewed
pre-install decision packet after the agent finishes read-only discovery,
artifact/model verification, planning, rendering, and cost estimation. That
single approval covers routine prerequisite creation, secret population,
locked-model staging, chart installation, temporary-resource cleanup, bounded
smoke validation, and any optional tests selected in the packet. Model license
metadata remains in the signed inventory but is not an acceptance or
installation blocker. There are no mid-install permission prompts; only a
material deviation from the approved identity, scope, plan, security controls,
or cost stops the run. Decommissioning remains a separate destructive action.
The rapid default is AWS/EKS plus S3; GCS, remote workers, interruption/fault
tests, restore/failure tests, and remediation are selected only when the
customer wants the corresponding qualification evidence.

The `main` branch contains the current deployment templates and may retain
`REPLACE_*` markers. For production, check out an immutable `vX.Y.Z` release
tag and verify its Sigstore release manifest before applying infrastructure or
installing charts.
