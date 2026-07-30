# Production capacity experiment feedback

Date: 2026-07-30 UTC

This is a sanitized operational record for deployment developers. It contains
no credentials, source paths, findings, object names, or secret values.

## Objective

1. Prefer current-generation AMD compute instances for scan workloads.
2. Reject scan nodes with fewer than 16 vCPU.
3. Increase private Tika extraction capacity because workers were restarting
   while waiting for the saturated extraction service.
4. Preserve the signed v0.1.0-develop.22 application, chart, detector, model,
   Presidio, and Tika image identities.

## Baseline

Captured before the experiment:

- RDS: PostgreSQL 16.13 on `db.m8g.4xlarge`, Single-AZ.
- RDS 15-minute average/maximum CPU: 18.2% / 23.4%.
- RDS 15-minute average/maximum AAS: 4.17 / 5.8.
- RDS average connections: 75; maximum 82.
- RDS freeable memory: approximately 42.9 GiB.
- RDS average write latency: 36.9 ms.
- RDS average disk queue depth: 4.84.
- Scan nodes: 18, with 82.5 allocatable vCPU and 140.2 GiB allocatable
  memory.
- Aggregate scan-node utilization: 39% CPU and 47% memory, but individual
  xlarge nodes reached 102% CPU and 94% memory.
- Instance mix: seventeen xlarge scan nodes and one `c5.4xlarge`.
- Extraction: 20/20 replicas; most Tika containers were consuming their
  complete 2-vCPU limit.
- Scan workers: 51 pods, 43 Ready, 312 aggregate historical restarts.
- The repeated worker exit signature was:
  `rich-format extraction readiness: Tika extraction probe: context deadline
  exceeded`.

The database had headroom. Tika saturation and small-node packing were the
immediate constraints.

## Repository change

The AWS deployment module now exposes:

```hcl
scan_instance_families       = ["c8a"]
scan_min_instance_generation = 8
scan_min_instance_vcpu       = 16
```

The default values preserve the prior category-diversified behavior:

```hcl
scan_instance_families       = []
scan_min_instance_generation = 5
scan_min_instance_vcpu       = 2
```

When an exact family list is supplied it takes precedence over
`scan_instance_categories`. Both Spot and optional CPU on-demand fallback
NodePools receive the same family, generation, and vCPU constraints.

The implementation uses the Karpenter requirements:

```yaml
- key: karpenter.k8s.aws/instance-family
  operator: In
  values: [c8a]
- key: karpenter.k8s.aws/instance-generation
  operator: Gt
  values: ["7"]
- key: karpenter.k8s.aws/instance-cpu
  operator: Gt
  values: ["15"]
```

Terraform validation and mocked plan tests cover both the backward-compatible
defaults and the high-throughput c8a profile.

`values/high-throughput-extraction-eks.yaml` records the reusable Helm portion
of the experiment: 24 minimum Tika replicas and a stage ceiling of 32. It is an
optional additive overlay rather than a new global production default.

`values/high-throughput-workers-eks.yaml` records the follow-up bounded worker
experiment: 120 small, 8 standard, and 15 large minimum replicas, for 143
worker pods and 542 worker processes.

An attempted same-process-count rebalance to 96 small, 32 standard, and 15
large was rejected by the signed v0.1.0-develop.22 chart's production
validation. The chart permits at most eight Standard replicas until the
scan-first claim path is re-qualified. The live configuration was immediately
returned to 120 small, 8 standard, and 15 large; the repository does not weaken
or bypass that release control.

## Production experiment

The live NodePools were changed to the exact high-throughput requirements
above. This is temporary Terraform drift until the repository change is
reviewed, released, and applied from the production backend.

The persistent private Helm overlay was changed from:

```yaml
extraction.autoscaling.minReplicas: 2
capacityAdvisor.stageMaxReplicas.tika: 20
capacityAdvisor.catalog.profiles[tika].max_replicas: 20
capacityAdvisor.catalog.version: builtin-conservative-v1-healthtap-cost-cap
```

to:

```yaml
extraction.autoscaling.minReplicas: 24
capacityAdvisor.stageMaxReplicas.tika: 32
capacityAdvisor.catalog.profiles[tika].max_replicas: 32
capacityAdvisor.catalog.version: builtin-conservative-v1-healthtap-cost-cap-tika32
```

The catalog identity changed because changing a profile ceiling without
changing the catalog version would make audit records ambiguous.

Helm lint and render validation passed. The existing signed
v0.1.0-develop.22 chart was applied atomically. Helm release revision 8 is
`deployed`. Application and detector image digests did not change.

## Observed result

First stable sample after rollout:

- Tika: 32/32 Ready, zero restarts.
- Scan workers: 90/90 Ready, 11 restarts on the new pod set, with no increase
  during the stable observation window.
- After HPA scale-down, worker processes settled at 280 registered and all 280
  busy. The advisor requested 67 small and 8 standard replicas.
- A short-lived 20-replica large allocation scaled cleanly to zero after the
  HPA stabilization window.
- Scan nodes had fully transitioned to c8a and every node had at least 16
  vCPU.
- Final observation instance mix: fourteen `c8a.16xlarge` Spot, one
  `c8a.8xlarge` Spot, three `c8a.4xlarge` Spot, and seven `c8a.4xlarge`
  on-demand nodes.
- Karpenter was actively consolidating the transition fleet under the existing
  10% disruption budget.

Ten-minute RDS sample under the increased concurrency:

- CPU average/maximum: 19.3% / 21.2%.
- AAS average/maximum: 3.97 / 5.0.
- Connections average/maximum: 174 / 201.
- Write latency average/maximum: 29.3 ms / 45.7 ms.
- Disk queue depth average/maximum: 2.94 / 5.11.
- Dominant waits: CPU 2.64 AAS, relation lock 0.68, WALWrite LWLock 0.29.

The database remained healthy. Connections increased materially, but CPU,
latency, queue depth, and AAS remained within the observed headroom.

The largest existing scan increased from approximately 155 completed
units/minute before the change to approximately 195 completed units/minute in
the final observation window, an early improvement of about 26%. The other
active sources had different work shapes and did not show the same rate.
Longer stage-specific measurement is still required before treating 26% as a
general throughput expectation.

## Cost and packing feedback

Observed Spot price ranges:

- `c8a.4xlarge`: USD 0.3273-0.4132/hour.
- `c8a.8xlarge`: USD 0.7862-0.8446/hour.
- `c8a.16xlarge`: USD 1.0663-1.6689/hour.

`c8a.4xlarge` on-demand was USD 0.86216/hour.

The peak transitional scan fleet was approximately USD 35/hour. The final
observed scan fleet was approximately USD 23-32/hour at the observed Spot
range. The complete cluster remained below the approved USD 100/hour ceiling,
but the exact-family constraint caused Karpenter to select many
`c8a.16xlarge` Spot nodes while old nodes drained and new HPA demand arrived.
Developers should consider exposing an optional maximum vCPU or allowed-size
list in addition to the minimum.

Recommended follow-up controls:

1. Add `scan_max_instance_vcpu` or `scan_instance_sizes` so a customer can
   choose `4xlarge` and `8xlarge` while retaining family selection.
2. Support a higher-weight preferred c8a NodePool plus a lower-weight,
   generation-8 diversified Spot fallback. An exact-family-only Spot pool
   reduces capacity diversity.
3. Keep Tika minimum and maximum customer-configurable and require the catalog
   identity to change with capacity-profile changes.
4. Investigate why worker process startup exits when a healthy but saturated
   Tika endpoint exceeds 30 seconds. A remote dependency timeout should not
   create repeated worker crash loops.
5. Measure completed units by pipeline stage. More Tika removes extraction
   pressure, but contextual detection or source-specific work can still govern
   end-to-end throughput.

## Follow-up GPU, RDS I/O, and node-packing correction

When Ollama requested eight replicas, Spot supplied four GPUs and left three
replicas Pending after the fixed on-demand baseline. A lower-priority
`llm-on-demand-burst` NodePool supplied exactly three additional single-GPU
on-demand nodes. The resulting placement was four on-demand GPUs (one fixed
baseline plus three burst) and four Spot GPUs, with Ollama 8/8 Ready. The
NodePool uses `WhenEmpty` consolidation and a three-GPU limit so idle burst
nodes terminate without routine model-pod churn.

The database gp3 volume was the closest throughput constraint. AWS rejected a
direct 3,000-to-12,000 IOPS change while the PostgreSQL volume remained below
400 GiB. The approved online modification therefore preserves gp3, encryption,
Single-AZ, the `db.m8g.4xlarge` class, and the 2,000-GiB autoscaling maximum
while changing:

- allocated storage: 100 to 400 GiB;
- provisioned IOPS: 3,000 to 12,000;
- provisioned throughput: 125 to 500 MiB/s.

Allocated storage cannot be reduced. The change enters RDS storage
optimization and must be monitored through completion.

The scan fleet was then constrained to exact 16-vCPU `c8a` instances. This
marks existing `c8a.8xlarge` and `c8a.16xlarge` NodeClaims drifted and lets
Karpenter replace them gradually under the existing 10% disruption budget.
The target packing is approximately 15-17 `c8a.4xlarge` nodes for the current
143 scan-worker and 32 Tika pod requests, rather than 25 mixed scan nodes.
Terraform now supports an exact `scan_instance_vcpus` list so this correction
does not depend on an out-of-band live patch.

After right-sizing, Karpenter could not pack the replacement nodes because the
customer overlay rendered both extraction topology constraints with
`whenUnsatisfiable: DoNotSchedule`. With 32 Tika replicas, the hostname
constraint retained nearly one Tika pod per node. The live correction keeps
the availability-zone constraint strict but changes only the hostname
constraint to `ScheduleAnyway`, allowing Karpenter to pack replicas while
still preferring host diversity.

The current chart exposes one global `whenUnsatisfiable` value for both zone
and hostname constraints. A follow-up release should expose separate zone and
hostname settings so the production overlay can persist strict zone spreading
and soft hostname spreading without a post-Helm Deployment patch.

Karpenter 1.6.3 was then upgraded in place with only
`SpotToSpotConsolidation=true`; the immutable chart digest was
`sha256:5e16fd290be2d950f6a54465adb39709eddf7e95383a292010dccad2a64a7284`.
Both controller replicas remained Ready. The fleet settled at 24
`c8a.4xlarge` scan nodes (13 on-demand and 11 Spot), down from 25 mixed nodes
and approximately 976 allocatable vCPU to approximately 381 allocatable vCPU.
All 143 scan workers, 32 Tika replicas, and 20 Presidio replicas were Ready.

The RDS modification completed at `2026-07-30T19:58:35Z`. The first
nine-minute post-change sample showed:

- write latency average 5.7 ms, down from 32.0 ms before the change;
- latest disk queue depth 1.52;
- average AAS 3.44;
- average `LWLock:WALWrite` 0.16 AAS;
- average relation-lock wait 0.80 AAS.

The storage change materially reduced the I/O and WAL-write portion of the
bottleneck. Relation-lock contention remains a separate query-level issue.

## Rollback

If error rates, dead letters, DB load, or cost become unacceptable:

1. Restore the private Tika minimum, stage ceiling, catalog ceiling, and
   catalog version to the baseline values.
2. Run the same signed v0.1.0-develop.22 Helm chart atomically.
3. Restore scan NodePool requirements to generation 5+, categories
   `c`, `m`, and `r`, with no exact family or vCPU requirement.
4. Wait for Karpenter's normal disruption budget and consolidation. Do not
   delete queue rows or manually terminate healthy worker pods.

No source-access, S3 endpoint, application image, detector, model, admission,
or secret change was part of these capacity experiments.
