# Scale-readiness workstream

**Framing, stated up front every time you report on this workstream:** this is a *reconnaissance*
pass on the C1 playground cluster — it tells you whether the architecture has obvious headroom
problems or blind spots, not whether it would actually survive 1000 concurrent users. No
load-testing tool exists anywhere in this repo or `fred` today (checked: no k6/locust/vegeta
config). Real empirical proof belongs on the future C3 twin, once it exists. If asked "will 1000
users be fine," the honest answer today is "here's what I can check, here's what I can't, and
here's the gap that would need closing before anyone could actually answer that with confidence" —
never a bare yes.

## What "good" looks like, and how to check it today

| Signal | How to check today | What's missing / a red flag |
|---|---|---|
| Node/pod headroom | Grafana `Fredlab — Resources & FinOps` dashboard ("Capacity & headroom" row: CPU/memory requested vs. allocatable, overprovisioning ratios) or `kubectl top nodes/pods -n fred-demo` | A sustained (not brief-rollout-spike) plateau of Pods Pending is the real "can't schedule right now" signal, per `docs/DEPLOYMENT-GUIDE.md` §5 — GKE Autopilot scaling nodes is normal and shows as a node-count step, not a problem by itself. |
| Postgres connection saturation (the `fred` DB is shared by control-plane, fred-agents, knowledge-flow) | `kubectl -n fred-demo exec -i statefulset/postgres -- psql -U fred -d fred -tAc "SELECT count(*), state FROM pg_stat_activity WHERE datname='fred' GROUP BY state;"` and compare against `SHOW max_connections;` | **No Prometheus/Grafana panel exists for this at all** — you must psql it directly every time. `control-plane-backend` has *zero* pool telemetry anywhere (not logs, not KPI, not Prometheus) — `emit_sql_pool_kpis()` (`fred_core/kpi/kpi_process.py`) is wired in knowledge-flow-backend and fred-agents (via fred-runtime) but never called in control-plane's own `context.py`. And even where it *is* emitted, `process.db_pool.*` is explicitly excluded from the Prometheus sink by name-prefix (`prometheus_kpi_store.py`) — it only ever lands in OpenSearch/logs. This is the single most concrete scale-readiness blind spot found; propose it as a `docs/BACKLOG.md` `OPS-` item (control-plane pool telemetry) if it's still true when you check. |
| API latency under current load | Grafana `Fredlab — Application KPIs`: "API p95 latency, by route" | Real signal, already instrumented (`api.request_latency_ms`, all three apps). Remember: Prometheus counters/histograms reset on pod restart — a panel showing "No data" right after a deploy isn't a regression, check the pod's age first (`docs/DEPLOYMENT-GUIDE.md` §6). |
| Temporal backlog (control-plane lifecycle, knowledge-flow ingestion, fred-evaluation campaigns) | No live queue-depth gauge exists anywhere. Closest proxy: `temporal.system.activity_queue_wait_ms` (knowledge-flow's two scheduler activities only) in Grafana's "Temporal ingestion workflows" panel; for anything else, there is currently no in-cluster way to see backlog depth without the `temporal` CLI/`tctl` (not confirmed present in this cluster — check before assuming) | This is a real, currently-unfilled gap for *any* of the three Temporal task queues (`control-plane-lifecycle`, `ingestion`, `evaluation`) except the two specific activities already covered. Worth flagging as an improvement opportunity, not just a caveat. |
| Auth-path latency (Keycloak, OpenFGA) — a likely bottleneck under real concurrent load, since every authenticated request touches both | OpenFGA already exposes `/metrics` (port 2112, `OPENFGA_METRICS_ENABLED`, `gcp-c1/helm/templates/openfga.yaml`) but **has no `PodMonitoring` scraping it** — confirm live with `kubectl -n fred-demo get podmonitoring` (only `control-plane-backend`, `fred-agents`, `knowledge-flow-backend`, `knowledge-flow-worker`, `kube-state-metrics` exist as of this writing). Keycloak has metrics **disabled entirely** (no `KC_METRICS_ENABLED` anywhere in the chart) — bigger gap, needs a real config change, not just a scrape target. | Neither is visible on any dashboard today. This is exactly the kind of thing that looks fine at low traffic and becomes the actual bottleneck at 1000 concurrent users — flag both explicitly whenever this workstream runs, don't let it get lost as a minor footnote. |
| Alerting / early warning | `kubectl -n fred-demo get podmonitoring` (what's scraped) vs. any PrometheusRule/GMP `Rules`/`GlobalRules` CRD — **none exist anywhere in this repo**, confirmed by grep. | Today, nothing pages or notifies on any of the above — someone has to be staring at Grafana when load hits. This is worth its own improvement proposal, independent of any single metric gap. |

## Rollout mechanics that matter under load (already-known operational facts, don't re-discover)

- All fred-apps Deployments use `maxSurge: 0 / maxUnavailable: 1` deliberately (small-cluster
  rollout note, `gcp-c1/argocd/README.md`) — a rolling deploy replaces pods in place rather than
  surging, trading brief per-app unavailability for not exhausting node memory on a small cluster.
  This is a *design choice* for the C1 playground's size, not necessarily right at 1000-user scale
  on a bigger cluster — worth re-evaluating explicitly if/when capacity requirements change, rather
  than carrying it forward unexamined onto a C3 twin.
- GKE Autopilot scales nodes automatically but has real limits (GCE quota) — a burst of pods
  scheduling at once (e.g. all four apps surging simultaneously without the above guard) can wedge
  new pods in `Pending` if node auto-provisioning hits a quota wall. Seen and documented already;
  don't re-diagnose it as new if it recurs, but do check whether the same guard is present on any
  new workload before assuming it's covered.

## Closing this workstream

State plainly which of the six signals above you actually checked this run, which showed a real
gap vs. which were already green, and whether the "no load-testing tool exists" fact is still true
(a quick grep for k6/locust/vegeta config is cheap — don't assume it's still absent without
checking, tooling can appear between sessions).
