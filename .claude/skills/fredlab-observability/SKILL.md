---
name: fredlab-observability
description: Inspect a live Fred deployment's scale-readiness, GDPR/data-hygiene posture, and Prometheus/Grafana KPI health, and surface concrete platform-improvement opportunities. Use when asked to check whether fredlab (or a future classified twin) is healthy or ready for load, audit for a data-hygiene/RGPD regression, review what Grafana/Prometheus does and doesn't cover, or investigate a live incident against the three-stream observability model. Targets the fredlab GKE/C1 reference cluster today; every procedure is written classification-agnostic per RFC-0001 §6 so it stays useful once a C2/C3 twin exists.
user-invocable: true
argument-hint: [optional: scale | gdpr | kpi | all — default all]
---

# Fredlab Observability

A **read-only investigative session** against a live Fred deployment (today: fredlab on GKE,
project `fredlab-playground`, namespace `fred-demo`) — you observe the cluster's own logs,
metrics, and audit trail directly, form evidence-backed findings, and either hand the operator an
exact command to fix what's safe to template or propose a `docs/BACKLOG.md` entry for what isn't.
You never mutate the cluster yourself.

**Relationship to `fred`'s `live-observability-session` skill:** that one drives a *local dev*
stack by hand (developer clicks the UI, you tail stdout) and lives in the `fred` monorepo. This
skill reads a *live, unattended GKE cluster's* own signal — no developer driving anything, no
local dev stack — and lives in `fred-deployment-factory` because platform/infra concerns (GCP log
sinks, GKE PodMonitoring, Helm chart ownership) are this repo's domain, not `fred`'s. Complementary,
not overlapping.

**No C3 twin exists yet.** The roadmap (this repo's `CLAUDE.md`) is explicit: harden the GKE/C1
reference first, generalize later. Every workstream below must phrase findings as *true today at
C1* plus *what would/wouldn't still hold at C3* (RFC-0001 §6's three knobs: secrets source, network
segmentation, hosting/sovereignty — nothing else changes by classification level) — never assume a
classified twin's specifics, never claim something is "C3-compliant" when what you actually checked
was C1.

## Preconditions

- `gcloud` authenticated, project set to `fredlab-playground`; `kubectl` context pointed at
  `fredlab-playground-gke` (`gcloud container clusters get-credentials ...`, see
  `docs/DEPLOY-CLOUD.md` §1.1 if not already done).
- **The live instance's namespace is `fred-demo`, not `default`.** Several scripts
  (`bin/fredlab-status.sh`, `bin/fredlab-gcp-log-retention.sh`) default to `default` — always pass
  `NAMESPACE=fred-demo` explicitly, and say so if you catch yourself about to run one without it.
- **Strict read-only stance, no exceptions:** you may run `gcloud logging read`, `gcloud logging
  sinks/buckets describe`, any `kubectl get|describe|logs|top`, `kubectl exec -- psql -c "SELECT
  ..."` / `curl` against in-cluster services, and existing `bin/fredlab-*.sh` scripts **in their
  default preview mode only**. You never run `--apply`, `kubectl apply/edit/delete/annotate`,
  `helm upgrade`, `argocd app sync`, or any write query. This matches this repo's `CLAUDE.md` rule
  ("platform mutations go through `bin/fredlab-*.sh`, one step at a time, never ad-hoc
  kubectl/helm/argocd") applied to its logical conclusion for an investigative session: you hand
  the operator the exact command; he runs it.
- Re-run `bin/fredlab-status.sh` (with the namespace above) once at the start of any session as a
  baseline sanity check before doing anything workstream-specific — don't investigate a "problem"
  that's actually just a mid-rollout pod restart.

## Reaching each stream

| Stream | How | Notes |
|---|---|---|
| App logs (stdout) | `kubectl -n fred-demo logs deploy/<name> [--since=Xm\|--tail=N]` | Every app's console handler; `fred.security.audit` events are also stdout-only JSON lines, `propagate=False` — they must never also appear in a generic log store. |
| GCP Cloud Logging | `gcloud logging read 'resource.type="k8s_container" AND resource.labels.namespace_name="fred-demo" AND ...' --freshness=Xh` | GKE ships every container's stdout/stderr here automatically, independent of Fred's own `log_store` config — confirmed live, this is where durable INFO+ logs actually are today (see `references/gdpr-data-hygiene.md` for why the intended cost-control exclusion isn't active). |
| OpenSearch (KPI store, `kpi-index`) | `kubectl -n fred-demo exec deploy/<any-app> -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://opensearch:9200/<path>').read())"` (or `curl` if present in the pod) | **No authentication today** — any in-cluster pod can read/write/delete this unrestricted. Never treat that as a convenience; it's finding #1 in `references/gdpr-data-hygiene.md`. |
| Prometheus (GMP) | Prefer knowledge-flow-backend's own authenticated ops surface (`PrometheusOpsController`, MCP tools `prometheus_query`/`_query_range`/`_series`/`_labels`/`_label_values`, wired to `gmp-frontend:9090` per `OPS-3` in `docs/BACKLOG.md`) over a raw port-forward when you have a route to it; otherwise `kubectl -n fred-demo port-forward svc/gmp-frontend 9090:9090` + `curl localhost:9090/api/v1/query?query=...`. `/api/v1/targets` and `/api/v1/metadata` are NOT implemented by GMP's frontend (a stateless Cloud Monitoring proxy, not a real Prometheus server) — don't read an empty result there as "nothing is scraped." |
| Grafana | `kubectl -n fred-demo port-forward svc/grafana 3001:3000`, admin creds in secret `fredlab-infra-secrets` key `GRAFANA_ADMIN_PASSWORD` | Two dashboards exist today: `Fredlab — Application KPIs`, `Fredlab — Resources & FinOps`. Read what's already there before assuming a gap — `curl -u admin:<pw> localhost:3001/api/search` then `/api/dashboards/uid/<uid>` for panel lists. |
| Postgres (direct, for what Prometheus can't answer yet) | `kubectl -n fred-demo exec -i statefulset/postgres -- psql -U <db-user> -d <db> -tAc "SELECT ..."` | `SELECT` only. Database/user names: `fred` (control-plane, fred-agents, knowledge-flow share it), `evaluation` (fred-agent-evaluator). Each app's own `alembic_version_<app>` table is the migration-head source of truth (see the deployment-factory's own `OPERATING-CONVENTIONS.md` C2.3). |
| GitHub/CI (image provenance) | `gh api repos/<org>/<repo>/actions/runs`, `gh api .../git/refs/tags/...`, ghcr.io manifest checks via `curl https://ghcr.io/token?scope=...` | Not a live-cluster stream, but part of the same "trust nothing, verify live" discipline — e.g. confirming a tag's CI actually succeeded and its images actually exist before trusting a deploy. |

## The four workstreams

Run whichever subset the `argument-hint` (or the operator's actual question) calls for; default to
all four for a general "is fredlab healthy" ask. Each workstream's detailed procedure, what "good"
looks like, and the specific known gaps to check for live in its own reference file — read the
relevant one before starting, don't rely on memory of a prior session (facts here rot fast: a gap
found today may be fixed next week, and a new one may appear).

1. **Scale/capacity readiness** — `references/scale-readiness.md`. What "would this hold up at
   ~1000 concurrent users" actually means to check today (headroom, connection pools, queue depth,
   autoscaling behavior), including the direct-query workarounds needed because several relevant
   metrics don't reach Prometheus yet. Explicitly a **reconnaissance pass on the C1 playground**,
   not empirical proof — real load-test validation belongs on the future C3 twin.
2. **GDPR / data-hygiene audit** — `references/gdpr-data-hygiene.md`. The closed checklist: is the
   log-retention exclusion active and in the right namespace, is OpenSearch's auth gap still open,
   any new PII-in-logs regression, has `log_level` drifted off its safe INFO default anywhere, is
   the security audit trail's downstream durability decided (today: no, anywhere).
3. **KPI/Prometheus health and innovation** — `references/kpi-health-and-gaps.md`. Confirm existing
   dashboards/scrape targets are actually healthy, diff "who's scraped" against "who exposes
   `/metrics`", and — the "innovative" priority — always close this workstream by proposing at
   least one concrete, buildable new KPI or panel.
4. **Remediation handoff** — `references/remediation-snippets.md`. For every finding across the
   three workstreams above, decide: is this safe to hand over as an exact ready-to-run command
   (config one-liners, namespace fixes, a new scrape target), or is it a real security/architecture
   decision that only gets a `docs/BACKLOG.md` entry proposal? Never blur the two.

## Reporting shape

Every finding needs all four parts, same discipline as `live-observability-session`'s protocol,
adapted for an unattended cluster (no "developer just did X" step to anchor on — anchor on the
query instead):

- **Evidence** — the actual command you ran and its real output, quoted, not paraphrased.
- **Channel** — which of stdout / Cloud Logging / OpenSearch / Prometheus-Grafana / audit trail.
- **Classification** — confirmed regression, config gap, already-tracked (cite the existing
  `docs/BACKLOG.md` ID if one exists), or new improvement opportunity.
- **Next step** — one of: "ready-to-run command below" (§ remediation-snippets.md pattern), "propose
  a new `docs/BACKLOG.md` entry" (state the theme + next available ID — re-grep the file for the
  actual current max, IDs listed anywhere in this skill's reference files rot within weeks), or
  "needs the operator's judgment call, here are the options."

A finding missing any of these four isn't ready to report yet — don't report "OpenSearch has no
auth" without also stating what stream it affects, whether it's new since the last check, and
what the concrete next step is.

## Ending the session

Nothing to stop (no background processes started, unlike `live-observability-session` — this skill
never launches long-running local backends). Close out by: listing every command you handed the
operator that's still pending his approval/run, and confirming which workstreams you actually ran
vs. skipped (so a "quick GDPR check" doesn't get silently reported as if it were a full audit).
