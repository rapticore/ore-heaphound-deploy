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
