# Fred deployment guide — replicating this pattern on a new platform

Who this is for: someone standing up a Fred instance on a **different platform**
from the reference here (GKE/GCP) — e.g. **S3NS** (also GKE Autopilot) or a
**Thales-managed AKS** cluster (not Autopilot, object storage on **SeaweedFS**
instead of GCS). This is a practical checklist + a record of what actually broke
building the GKE reference, so you don't re-discover the same things the hard way.

---

## 1. The pattern, in one paragraph

Two layers. A **Foundation** — the stateful backbone (Postgres, OpenSearch,
Keycloak, OpenFGA, Temporal, plus the shared Ingress/TLS/secrets) — deployed
**imperatively** (a reviewed `helm upgrade`), changed rarely. And an **Apps**
layer — the stateless Fred apps (control-plane, fred-agents, frontend,
knowledge-flow backend+worker) — deployed by a **GitOps controller** (ArgoCD
today) that reconciles the cluster to git. Apps reference the Foundation **by
name** (a DNS hostname, a Secret name) and never create it. This split, and the
rule that Apps never create Foundation resources, is the part that must survive
unchanged on any platform — everything else (which cluster, which object store,
which git host) is a knob.

---

## 2. What any platform must provide (checklist)

Go through this before writing a single line of platform-specific config.

- [ ] **Kubernetes with elastic node capacity.** Doesn't have to be
      "Autopilot" specifically — just something that adds capacity without you
      hand-sizing every node pool. On plain AKS this means turning on and sizing
      the **cluster autoscaler** explicitly; there's no zero-config equivalent.
- [ ] **Pod-level cloud credentials with no static keys.** GCP calls this
      Workload Identity; Azure calls it Azure AD Workload Identity (OIDC
      federation). Different plumbing, same shape: a pod gets a scoped,
      short-lived credential without a JSON key or an access key sitting in a
      Secret.
- [ ] **Object storage that can mint time-limited signed/presigned URLs.**
      knowledge-flow's tabular (Parquet) reads need this. GCS does it via IAM
      `signBlob`; an S3-compatible store (SeaweedFS, MinIO, real S3) does it via
      standard SigV4 presigned URLs — different mechanism, same requirement.
- [ ] **A Prometheus-compatible metrics source, and somewhere to run Grafana.**
      Needed for the capacity/cost dashboard (§5). GKE gives you this for free
      (Google Managed Prometheus); most other platforms don't — budget an
      explicit enable step or a self-hosted `kube-prometheus-stack`.
- [ ] **A secrets injection path outside git.** The simplest version (what this
      repo does today) is a git-ignored local values file fed to Helm. Fine for
      a playground; harden it (Vault, sealed-secrets, CI-injected) as the
      classification of the target goes up.
- [ ] **Ingress + automatic TLS**, and **a git host + GitOps controller** for
      the Apps layer (this repo: GitHub + ArgoCD).

---

## 3. How GKE/GCP does each of these (the reference)

| Requirement | GKE/GCP implementation |
| --- | --- |
| Elastic capacity | GKE **Autopilot** — nodes provisioned automatically, no node pool sizing |
| Pod-level credentials | **Workload Identity**: one Google Service Account (GSA) per concern, bound to the Kubernetes ServiceAccount that needs it, via `bin/fredlab-gcp-gcs-prereqs.sh` / `bin/fredlab-gcp-monitoring-prereqs.sh` |
| Signed URLs | GCS + a dedicated `signing_service_account_email` — the GSA signs its own blobs (IAM `signBlob`, granted by the prereq script) |
| Metrics + Grafana | Google Managed Prometheus (GMP) query frontend (in-cluster, stateless) + a self-deployed `kube-state-metrics` + Grafana, all as Foundation components |
| Secrets | Local git-ignored `gcp-c1/helm/fredlab-secrets.values.yaml` |
| Ingress/TLS | GKE `gce` Ingress + one `ManagedCertificate` per public hostname |
| Git host + GitOps | GitHub + ArgoCD |

Two GCP-specific values that have **no safe default** and will crash
`knowledge-flow-backend` at startup if left empty:

- `knowledgeFlow.config.storage.signingServiceAccountEmail`
- `knowledgeFlow.config.models.project` (Vertex AI project id)

On a new platform these become whatever the equivalent required field is for
your object store's signing mechanism and your model provider — same failure
mode (a hard crash with no fallback) if you leave them blank, so check for them
explicitly rather than assuming "empty means use the default."

---

## 4. Gotchas we actually hit (read before you build the same thing)

**Two charts writing the same object name will fight over it, silently.**
This repo currently has two Helm chart trees — one for the imperative
Foundation deploy, one for the GitOps Apps layer — that, today, both render a
ConfigMap under the same name in the same namespace for a couple of apps. A
routine Foundation deploy can overwrite the GitOps-managed ConfigMap with its
own (possibly incomplete) values, with no warning. This actually happened and
took a service down for two hours. **Before trusting any deploy on a new
platform:** render both chart trees (`helm template`) and diff the object names
they produce — anything that collides is a landmine. This is being fixed
upstream (converging on one shared chart), but until it's fixed, check for it
by hand on every chart change.

**Grafana's Cloud Monitoring datasource needs the project set on every panel,
explicitly.** If you point Grafana at Google Cloud Monitoring, don't rely on
the datasource's default-project setting alone — Grafana's frontend query
editor (as of Grafana 11.1.x) doesn't reliably fall back to it. A panel built
without an explicit `projectName` inside its query silently never fires: no
error, no network request, just a permanently empty panel that looks like a
data problem when it's actually a missing field. If you hit "panel shows no
data but the exact same query works fine when you run it directly against the
API," check this first. (This specific plugin bug is GCP/Grafana-specific and
won't apply to Azure Monitor's Grafana datasource — but the debugging method
generalizes: bypass the browser, replay the exact query against the backend
directly, to tell a real backend problem from a frontend one.)

**On GKE Autopilot, "% of capacity requested" is not a growth signal.**
Autopilot adds nodes on demand, so a CPU/memory-requested-vs-allocatable ratio
self-corrects every time it scales up — it can sit near 100% forever without
anything being wrong, and it hides real usage growth because the denominator
keeps expanding to match. Track actual growth with **absolute** requested
cores/memory against a fixed budget instead, not a percentage. This still
applies conceptually on a non-Autopilot cluster, just less dramatically, since
capacity there doesn't expand automatically.

**GKE's *managed* Prometheus collection is a curated allowlist, not "every
metric."** Confirming a scrape target shows `up=1` does not mean its full
metric catalog reaches your queries — `kube-state-metrics`' resource-request/
allocatable/restart metrics were silently excluded from the managed collection
and needed a self-deployed, least-privilege `kube-state-metrics` feeding the
same pipeline to actually show up. Verify by querying for the specific metric
you need, not by checking scrape-target health.

**An app image can ship a *second* config file that hardcodes `localhost` —
not just the main `configuration.yaml`.** fred-agents bundles its own
`config/mcp_catalog.yaml`, listing every MCP tool server it connects to. Every
knowledge-flow-backed entry (tabular, opensearch-ops, fs, corpus,
prometheus-ops) hardcoded `http://localhost:8111/...` — correct for a
docker-compose stack sharing one host, wrong the moment fred-agents and
knowledge-flow-backend are separate pods. This stayed invisible until the day
someone asked a question that actually routed to one of those tools (testing
the SQL/tabular path) — a plain chat question never touches this file at all,
so a basic smoke test won't catch it. **Before calling a new platform done,
grep every app's bundled `config/` directory for `localhost` — not just the
one file you already override.** The fix pattern generalizes: fred-runtime
supports an env-var override for this exact file (`FRED_MCP_CATALOG_FILE`,
same shape as `CONFIG_FILE`/`ENV_FILE`) — embed a corrected copy rather than
assuming the bundled default is deployment-ready.

**The knowledge-flow worker's Docling thread count must be sized against the pod's CPU
*limit*, not the node's core count.** `processing.profiles.<medium|rich>.pdf.docling_num_threads`
multiplied by `scheduler.temporal.ingestion_max_concurrent_activities` is the worker's peak OMP
thread count — size it against `resources.limits.cpu` on the worker pod. Get this wrong and PDF
ingestion doesn't error, it silently CPU-thrashes and looks like a hung pipeline. Full sizing
formula, a threads×concurrency safe/caution/danger table with measured numbers, and a diagnostic
checklist are in [Sizing the PDF Ingestion Worker (Docling)](https://fredk8.dev/docs/docling-ingestion-sizing.html)
on fred-website — don't duplicate that content here, just size the pod's CPU limit accordingly
when you set `resources.limits.cpu` for the worker.

**When you rewrite a `localhost:PORT` reference to the in-cluster DNS name,
match it to the Service's port, not the pod's raw `containerPort`.** Made
this exact mistake fixing the `mcp_catalog.yaml` above: rewrote
`localhost:8111` (the pod's container port) to
`knowledge-flow-backend:8111` — but the Service only listens on `8080`
(forwarding internally to `8111`); port `8111` isn't reachable through the
Service DNS name at all, only `8080` is. Confirmed by curl: `:8111` times
out, `:8080` responds. A Service's `port:` and a pod's `containerPort` are
independent numbers by design — always check the Service definition, don't
assume the container's own listening port is what the DNS name answers on.

**A routine app version bump is usually simple — but check every time, not
just the first time.** One release needed a new Alembic migration and no new
config; the next needed no migration but a new optional config field
(off by default) and had silently dropped an old one. Neither followed the
same shape as the last. Before bumping any version: diff the new release's
Alembic `versions/` directories (a new migration must run **before** the new
image starts serving, not after — a live incident here took a service down
for hours the first time), and diff the config schema for both new
required-with-no-default fields (crash risk, §3) and removed fields your
values still set (usually harmless if the app's config model doesn't forbid
extra fields — check whether it does — but worth cleaning up rather than
leaving stale).

---

## 5. The monitoring/FinOps dashboard pattern (platform-agnostic part)

Regardless of platform, the useful pattern is:
- Dashboard JSON committed to git, loaded via Grafana's **file provisioning**
  (a ConfigMap + a file-based dashboard provider) — not built by hand in the UI.
- Separate **capacity** signals (requested vs. allocatable — "can I schedule
  more right now") from **FinOps** signals (absolute requested cores/memory
  against a fixed budget — "am I growing beyond what I planned for"). The first
  is a live scheduling fact; the second is a trend you set thresholds on
  yourself. Conflating them (coloring a scheduling fact red like an outage) is
  the mistake we made and then fixed.
- A "how healthy is the autoscaler itself" panel pair: current node count +
  node count over time (shows scale events directly), and pending-pod count +
  pending-pod count over time (the actual "can't schedule right now" signal —
  brief spikes during a rollout are normal, a sustained plateau isn't).

Only the datasource type and the exact queries change per platform (Cloud
Monitoring/`stackdriver` here; Azure Monitor's Grafana datasource on AKS); the
shape of the dashboard doesn't need to.

---

## 6. Application KPIs dashboard — what's needed

Distinct from the Resources & FinOps dashboard (§5, which reads GKE/GCP infra
metrics): this one reads metrics the **Fred apps themselves** emit — agent/tool
execution, API latency, RAG search, ingestion. Three things have to be true
before it shows anything.

**1. Each app's Prometheus exporter must be turned on and bound to something
the scraper can actually reach.** All three were broken or off by default:

- `control-plane-backend`: `controlPlane.config.observability.prometheus.enabled`
  was `false` — a deliberate default, just flip it to `true`.
- `fred-agents`: had **no** `observability.kpi.prometheus` block rendered into
  its ConfigMap at all — silently falling back to fred-runtime's own default
  (`enabled=true`, but `address=127.0.0.1`). Exporter was already running,
  just unreachable from outside the pod.
- `knowledge-flow` (backend + worker, shared ConfigMap): rendered `port` only,
  same `127.0.0.1`-default trap on `address`.

The pattern for all three, and for whatever the next app is: set `enabled:
true` and **always set `address: "0.0.0.0"` explicitly** — every app here
shares the same underlying config schema (fred-core's
`KpiPrometheusSinkConfig`), and its default bind address is loopback-only.
Never assume "it's enabled" means "it's reachable."

**2. A separate `metrics` containerPort on each app's Deployment**, distinct
from its API `http` port — the exporter runs its own dedicated HTTP server
(`prometheus_client.start_http_server`), not on the API port.

**3. A `PodMonitoring` CR (GMP's scrape-config CRD) per app**, selecting on
the pod's labels, `endpoints[].port: metrics`. This is **pod-based** service
discovery — it does not go through a Kubernetes `Service` at all, so you do
not need a Service port for this to work, only the named `containerPort` on
the pod itself.

**Source of truth for what to actually query — don't guess metric names or
labels.** This repo's dashboard
(`gcp-c1/helm/files/grafana-dashboards/application-kpis.json`) is built
entirely from `fred-website`'s `static/docs/observability-and-kpis.html` — it
documents every metric name, its Prometheus type, and, critically, exactly
which labels **survive** (many are sent by the app but silently dropped
before `/metrics` — e.g. no `team_id`, no `agent_instance_id`; per-team/
per-agent breakdowns are a separate, access-scoped data stream by design, not
an omission). A panel built against a label that doesn't survive returns
nothing, silently — same failure shape as the Cloud Monitoring `projectName`
bug in §4.

**Chart ownership, not a collision this time.** The `PodMonitoring` CRs live
only in the GitOps Apps chart (`gcp-c1/argocd/fred-apps`), not the Foundation
chart — these app pods are only ever actually deployed by the Apps chart (the
Foundation chart's copies of the same apps stay `enabled: false`). No point
creating a `PodMonitoring` in a chart with no matching pod to select, and no
collision risk either way since the Foundation chart never defines one.

**A ConfigMap change alone does not restart pods.** After fixing the exporter
config, running pods keep the *old* config in memory until restarted — a
`kubectl rollout restart` (or the next natural rollout) is required. Don't
assume a "successful" deploy picked up a ConfigMap-only change; check the pod's
actual age/restart count against when the ConfigMap changed.

**Design the dashboard for when it's actually full, not for when it's empty.**
A dense, condensed panel layout (small panel heights, tight legends) looks
harmless while every panel says "No data" — there's nothing to read either
way. The moment real traffic flows, cramped timeseries hide exactly the trend
shapes the dashboard exists to show. Ship a panel layout sized for real
data from the start (roughly double the height a purely-empty-state review
would suggest), with fixed colors for every bounded-cardinality series
(a status enum, an in/out pair) so Grafana's index-based auto-palette can't
repaint a series when the label set changes — reserve the auto-palette for
genuinely open-cardinality series (by route, by tool, by model) where no
fixed entity set exists to assign colors to.

**Prometheus counters are per-pod-instance — a restart resets them to
zero.** A metric that worked five minutes ago can show "No data" after a
routine pod restart (a new deploy, a config fix, node rescheduling) with
nothing actually broken — the *previous* pod's counter simply isn't the
*current* pod's counter. Before treating a suddenly-empty panel as a
regression, check whether the pod restarted since the last confirmed data
point, and re-exercise the code path once against the new pod before
concluding something is actually wrong.

---

## 7. What changes for each target platform

### S3NS (same substrate — GKE Autopilot)

Expect near-total reuse. Same chart, same Workload Identity pattern, same
GMP/Grafana stack. What changes is environment-scoped values only — project id,
region, hostnames, the secrets file contents — not the pattern or the chart
structure. Still re-check §4's ConfigMap-collision issue after any chart
change; it's a chart-structure risk, not a GKE-specific one.

### Thales AKS + SeaweedFS (different substrate)

| Concern | GKE reference | AKS + SeaweedFS equivalent |
| --- | --- | --- |
| Elastic capacity | Autopilot (automatic) | AKS **cluster autoscaler**, configured explicitly on a standard node pool — no Autopilot-equivalent zero-config mode. Size a baseline node pool for slower scale-up reaction than Autopilot's. |
| Pod-level credentials | Workload Identity (KSA↔GSA binding) | **Azure AD Workload Identity** — same no-static-keys shape, different setup: a federated credential + a pod annotation instead of an IAM binding. |
| Object storage | GCS + IAM `signBlob` | **SeaweedFS**, S3-compatible. `content_storage.type` becomes `s3`, not `gcs`. SeaweedFS issues presigned URLs via standard S3 SigV4 — no `signing_service_account_email`-style indirection needed — but you still need a real credential-injection path for the access key/secret (a Secret at minimum; check whether SeaweedFS supports a federated-identity-issued token if you need to avoid static keys entirely). |
| Metrics source | Google Managed Prometheus (free, built into Autopilot) | **Azure Monitor managed service for Prometheus**, or self-hosted `kube-prometheus-stack` if that's not available. Nothing is free-by-default the way GMP is — budget an explicit enable step or an extra in-cluster workload. |
| Model provider (chat/embedding/vision) | Vertex AI, `knowledgeFlow.config.models.project` | Azure OpenAI or self-hosted, per Fred's own model-provider config (an app concern, not a deployment one) — but expect the same failure mode: a required field with no safe default (endpoint/deployment/project) crashes the app the same way if left empty. Check for it explicitly. |
| Dashboard-as-code | Grafana file-provisioned JSON, `stackdriver` datasource | Same file-provisioning pattern — reuse it. Only the datasource type (Azure Monitor instead of Cloud Monitoring) and the panel queries change. Treat any new datasource plugin as unproven until you've verified it panel-by-panel against real data — don't assume a plugin's frontend is bug-free just because the backend query works (§4). |
| Git host + GitOps | GitHub + ArgoCD | GitLab + its native GitOps (or ArgoCD pointed at GitLab) |

**Bottom line:** the two-layer split and the boundary rule (Apps never create
Foundation resources) transfer unchanged. The real new work is re-deriving the
credential-federation and object-storage wiring for Azure, and choosing a
metrics source since nothing is free-by-default the way GMP is on GKE. The
ConfigMap-collision check in §4 applies identically no matter what cloud you're
on.

---

## 8. Pre-flight checklist for a new platform

- [ ] Elastic node capacity confirmed working (a test pod that needs more than
      current headroom actually gets scheduled, within a time budget you're
      okay with).
- [ ] Pod-level federated credentials working end-to-end (a pod can read from
      object storage / call the model provider with zero static keys anywhere).
- [ ] Object storage can mint a signed/presigned URL and you've confirmed the
      required config field for it (§3) is filled — not left on a default that
      doesn't exist.
- [ ] Metrics source reachable from Grafana; each dashboard panel confirmed
      against **real returned data**, not just "the panel didn't error."
- [ ] Application-level exporters (§6) confirmed separately from infra
      metrics — `enabled: true` is not enough, confirm each app's `/metrics`
      port actually answers (curl the pod IP directly) and that the scraper's
      `PodMonitoring`/equivalent is picking it up, not just that the app
      config says it should.
- [ ] Grepped every app image's bundled `config/` directory for `localhost` —
      not just the main config file (§4). Exercised every distinct feature
      path at least once (a tool-routing / SQL question, a document upload,
      not just a plain chat message) so a `localhost`-only-reachable-through-
      one-code-path bug can't hide behind a passing smoke test.
- [ ] Every `localhost:PORT` rewritten to an in-cluster DNS name was checked
      against the target Service's actual `port:` — not assumed to equal the
      pod's `containerPort` (§4).
- [ ] Rendered both chart trees (Foundation + Apps) and confirmed no object
      name collides between them (§4).
- [ ] Secrets file is git-ignored and confirmed as such
      (`git status --short --ignored <file>`).
- [ ] Ingress + TLS cert issued and `Active` for every public hostname.
- [ ] GitOps controller synced at least once, Application shows `Synced` /
      `Healthy`.
