# Ore Heaphound self-hosted deployment

This public kit deploys Ore Heaphound entirely into customer-owned cloud
accounts and Kubernetes clusters. Rapticore publishes signed containers and
Helm charts but does not host the runtime, control plane, customer data,
credentials, or model weights.

Start with [SELF_HOSTED.md](SELF_HOSTED.md). For the customer-owned staging
walkthrough and the evidence required before a release can be called qualified,
use [STAGING_QUALIFICATION.md](STAGING_QUALIFICATION.md).
For an LLM-operated walkthrough, give the agent that runbook. It asks the
customer a short guided set of questions, proposes collision-checked defaults,
and generates the internal execution record from
[AGENT_DEPLOYMENT_SPEC.example.yaml](AGENT_DEPLOYMENT_SPEC.example.yaml);
the customer does not complete YAML. The same runbook contains phase I, the
separately authorized LLM procedure for operational uninstall and eventual
post-retention removal.

Fresh AWS installations obtain Kyverno, External Secrets, the NVIDIA device
plugin, and the evaluated EKS AMI from
[prerequisites.lock.json](prerequisites.lock.json). Terraform creates the
encrypted operator-secret metadata and least-privilege synchronization path;
secret values remain outside Terraform and are populated with the released
non-echoing helper. Existing develop rehearsals should normally use the
runbook's saved-plan reconciliation path, not decommission and recreation.

The `main` branch contains the current deployment templates and may retain
`REPLACE_*` markers. For production, check out an immutable `vX.Y.Z` release
tag and verify its Sigstore release manifest before applying infrastructure or
installing charts.
