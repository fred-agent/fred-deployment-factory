# KPI / Prometheus health and innovation workstream

**Ground truth for metric names/labels — never invent or recall from memory:**
`fred-website`'s `static/docs/observability-and-kpis.html` (public doc, generated from the same
code) and this repo's `docs/DEPLOYMENT-GUIDE.md` §5–6. Both already document exactly which metrics
exist, their Prometheus type, and — critically — which labels *survive* to `/metrics` (many are
sent by the app but silently dropped before export; a panel built against a label that doesn't
survive returns nothing, silently, same failure shape as an outright wrong metric name). Read the
relevant section before building or diagnosing any panel; don't guess.

## Step 1 — confirm what's actually being scraped

```bash
kubectl -n fred-demo get podmonitoring
```
As of this writing: `control-plane-backend`, `fred-agents`, `knowledge-flow-backend`,
`knowledge-flow-worker`, `kube-state-metrics` — five total, all defined in
`gcp-c1/argocd/fred-apps/templates/app-podmonitoring.yaml` (the four app ones) and
`gcp-c1/helm/templates/kube-state-metrics.yaml`. **Chart-ownership rule, worth knowing before
proposing a fix:** app-level `PodMonitoring` CRs only ever go in the chart that actually deploys
those pods — the four app ones are Apps-chart-only (`gcp-c1/argocd/fred-apps`) because the
Foundation chart's copies of those same apps stay `enabled: false`; conversely, anything that lives
in the *Foundation* chart (OpenFGA, Keycloak, Postgres, OpenSearch) would need its own
`PodMonitoring` *in `gcp-c1/helm`*, never in `fred-apps` — no exceptions either direction.

Then confirm each target is actually reporting `up == 1` (a `PodMonitoring` existing doesn't prove
it's successfully scraping):
```bash
# via knowledge-flow's PrometheusOpsController if reachable, or a port-forward to gmp-frontend:
curl 'http://gmp-frontend:9090/api/v1/query?query=up'
```
(`/api/v1/targets` is not implemented by GMP's frontend — use `up{...}` series presence instead of
looking for a targets list.)

## Step 2 — diff "who's scraped" against "who exposes /metrics"

Known live gaps as of this writing (re-verify, don't assume they're still true):

- **OpenFGA already exposes `/metrics`** — `OPENFGA_METRICS_ENABLED`, dedicated port `2112`
  (`.Values.openfga.service.metricsPort`, `gcp-c1/helm/values.yaml`, wired in
  `gcp-c1/helm/templates/openfga.yaml`) — but has **no `PodMonitoring`** consuming it. Pure "add one
  CR" gap, safe to template — see `remediation-snippets.md`.
- **Keycloak has metrics disabled entirely** — no `KC_METRICS_ENABLED` env var, no `metrics` field
  under `keycloak:` in `gcp-c1/helm/values.yaml`. Needs a real templated config change (env var +
  values field), not just a scrape target — flag as bigger than OpenFGA's gap, don't undersell it.
- **`control-plane-backend` has zero DB-pool telemetry** and, even where the metric exists
  (knowledge-flow, fred-agents), **`process.*`-prefixed metrics never reach Prometheus at all**
  (`prometheus_kpi_store.py` explicitly skips them) — this is *documented* behavior
  (`observability-and-kpis.html`'s "Defined, but not on /metrics" section), not a bug to fix in
  `fred`'s code, but it is a real dashboard blind spot worth flagging under scale-readiness too.
- **No alerting anywhere** — no `PrometheusRule`/GMP `Rules`/`GlobalRules` CRD, no Alertmanager
  config, anywhere in `gcp-c1/`. Dashboards exist, nothing pages. Don't template this — GMP's
  managed-rules CRD is its own design surface, not a drop-in `PrometheusRule`; propose it as a
  `docs/BACKLOG.md` line (an `OPS-` item, was through `OPS-3` as of this writing).

## Step 3 — read what's already there before assuming a gap

Two real dashboards exist (Grafana `Fredlab` folder, confirmed via `/api/search` and
`/api/dashboards/uid/<uid>`):

- **`Fredlab — Application KPIs`**: agent/tool execution (p95 tool latency by tool, tool failure
  rate, turn completion/error rate by template, token throughput), API & LLM calls (p95 latency by
  route, error rate by route, request rate by route, LLM call latency p95 by model), retrieval &
  ingestion (RAG search hit ratio, search rate, document created/deleted rate, ingestion duration
  p95, Temporal ingestion workflow rate).
- **`Fredlab — Resources & FinOps`**: capacity & headroom (CPU/memory requested vs. allocatable,
  overprovisioning ratios), Autopilot/FinOps budget (pods pending, node count, absolute CPU/memory
  requested, both current and over time), pod restarts by namespace, data volume (Postgres size per
  database, OpenSearch size per index, GCS bucket size).

This is already a solid baseline — don't propose rebuilding either dashboard from scratch; propose
*additions* that close a confirmed gap (§ above) or genuinely extend coverage.

## Documented pitfalls (from `docs/DEPLOYMENT-GUIDE.md` §6 — don't re-diagnose these as new bugs)

- **Loopback-bind trap**: every app's Prometheus exporter config defaults `address` to `127.0.0.1`
  (fred-core's `KpiPrometheusSinkConfig` default) — "enabled" does not mean "reachable"; it must be
  explicitly set to `0.0.0.0`.
- **ConfigMap changes don't restart pods** — a fixed exporter config sits unused in a running pod
  until the next rollout/`kubectl rollout restart`. Check pod age/restart count against when the
  ConfigMap actually changed before concluding a fix didn't work.
- **Counters reset to zero on pod restart** — a panel showing "No data" right after a routine
  deploy is expected, not a regression; re-exercise the code path once against the new pod before
  calling it broken.

## Closing this workstream — the standing "innovate" requirement

Every run of this workstream must end with **at least one concrete, buildable new KPI or dashboard
panel proposal** — not a vague "we should monitor more." Use the confirmed gaps above as the
natural source (e.g. "a `PodMonitoring` for OpenFGA plus a p95-latency panel on the auth path" is a
complete, buildable proposal; "monitor auth better" is not). For *implementing* a new KPI in Fred's
own code (a new `KPIWriter` call site, a new Grafana panel JSON), point at `fred`'s own
`~/Fred/fred/.claude/skills/add-kpi-to-dashboard/SKILL.md` by name/path rather than restating its
steps here — that skill owns the actual `fred-core`/dashboard-JSON mechanics, this one owns
diagnosing what's missing and why it matters for fredlab specifically.
