# Ore Heaphound self-hosted deployment

This public kit deploys Ore Heaphound entirely into customer-owned cloud
accounts and Kubernetes clusters. Rapticore publishes signed containers and
Helm charts but does not host the runtime, control plane, customer data,
credentials, or model weights.

Start with [SELF_HOSTED.md](SELF_HOSTED.md).

The `main` branch contains the current deployment templates and may retain
`REPLACE_*` markers. For production, check out an immutable `vX.Y.Z` release
tag and verify its Sigstore release manifest before applying infrastructure or
installing charts.
