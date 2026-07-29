# Remediation handoff

For every finding, decide which bucket it's in — **never blur the two**:

- **Safe to template**: a pure config one-liner or a new resource following an exact existing
  pattern, low-risk, easily reversible. Hand the operator the exact command/diff; he reviews and
  runs it (this repo's established rhythm: you diagnose and prepare, he executes platform
  mutations).
- **Not safe to template**: a real security or architecture decision (credential rotation, a new
  CRD design, anything touching auth). Propose a `docs/BACKLOG.md` entry instead — re-grep the file
  for the actual current next ID in the right theme before proposing a number; the ones below were
  correct as of 2026-07-24 and will be stale soon.

## Safe to template

### 1. Log-exclusion namespace/apply fix

If `gdpr-data-hygiene.md` check #1 still shows `exclusions: null`:

```bash
# preview first (default mode, no live change):
NAMESPACE=fred-demo bin/fredlab-gcp-log-retention.sh

# then, once reviewed:
NAMESPACE=fred-demo bin/fredlab-gcp-log-retention.sh --apply
```

Frame this to the operator as a **regression fix**, not routine maintenance — the exclusion was
apparently never actually active (or lost meaning after the `default`→`fred-demo` rename), so
INFO-level logs have been accumulating at full volume and 30-day retention since some unknown
point. Mention the likely cost impact if you can estimate it (check `gcloud logging` usage/billing
if reachable) rather than just applying it silently.

### 2. OpenFGA `PodMonitoring` (Foundation chart — `gcp-c1/helm`, NOT `gcp-c1/argocd/fred-apps`)

OpenFGA already exposes `/metrics` (`OPENFGA_METRICS_ENABLED`, port named `metrics` on
`.Values.openfga.service.metricsPort`, confirmed in `gcp-c1/helm/templates/openfga.yaml`); it just
isn't scraped. New file `gcp-c1/helm/templates/openfga-podmonitoring.yaml`, matching the exact
guard-clause/labeling style already used for `kube-state-metrics.yaml` in the same chart:

```yaml
{{- if .Values.openfga.enabled }}
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: {{ include "fredlab-infra.openfgaName" . }}
  labels:
    {{- include "fredlab-infra.labels" . | nindent 4 }}
    app.kubernetes.io/component: openfga
spec:
  selector:
    matchLabels:
      {{- include "fredlab-infra.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: openfga
  endpoints:
    - port: metrics
      interval: 30s
{{- end }}
```

(Confirm `fredlab-infra.openfgaName` exists as a named-template helper in `_helpers.tpl` — reuse
whatever the existing OpenFGA Service/Deployment templates use for `.metadata.name`, don't invent a
new naming helper for one new resource.) No values.yaml flag needed beyond the existing
`.openfga.enabled` — this mirrors kube-state-metrics' own PodMonitoring exactly, which has no
separate metrics-enabled toggle either. Apply via the normal Foundation path:
`bin/fredlab-infra-deploy.sh` (imperative, reviewed) — never `kubectl apply` directly on a template
diff.

## Not safe to template — propose a backlog entry, do not hand over a command

### 3. OpenSearch authentication

Re-enabling OpenSearch's security plugin means: generating/rotating admin + per-service credentials,
updating every client's config (`control-plane`, `knowledge-flow`, Grafana's OpenSearch datasource,
this skill's own read commands), and deciding on a role/permission model for the KPI-index access
that's supposed to be admin-gated in code already. This is a real project, not a one-liner — propose
it as `docs/BACKLOG.md` **`SEC-5`** (check the file first — this was the correct next `SEC` number
as of 2026-07-24; `SEC-1` through `SEC-4` already exist) rather than attempting any fix yourself.

### 4. Keycloak metrics enablement

Needs a real templated change: `KC_METRICS_ENABLED=true` env var on the Keycloak container plus a
new `.Values.keycloak.metrics.enabled` (or similar) flag threaded through
`gcp-c1/helm/templates/keycloak-deployment.yaml` and `values.yaml`, then its own `PodMonitoring`
once the port is confirmed. More involved than OpenFGA's gap (which only needed a scrape target,
not a source-side enable) — don't undersell it as equally trivial. Propose as part of the same
`OPS-` alerting/observability backlog line below, or its own line if it's being actively planned.

### 5. Alerting infrastructure

Zero `PrometheusRule`/GMP `Rules`/`GlobalRules`/Alertmanager config exists anywhere. GMP's own
managed-rules CRD is not a drop-in `PrometheusRule` — it needs its own design pass (what pages on
what threshold, who receives it). Propose as `docs/BACKLOG.md` **`OPS-4`** (check the file first —
correct next `OPS` number as of 2026-07-24; `OPS-1` through `OPS-3` already exist).

### 6. Audit-trail durability / classification-portability gap

`fred`'s own `OBSERVABILITY-AND-AUDIT.md` states this is unresolved at every classification level
today. This is squarely a deployment-pattern question (where does `fred.security.audit`'s stdout
durably land, for how long, who can read it — differently at C1/C2 vs. a future C3 twin), not
something `fred`'s code can decide alone. Propose as `docs/BACKLOG.md` **`CLASS-7`** (check the file
first — correct next `CLASS` number as of 2026-07-24; `CLASS-1` through `CLASS-6` already exist).

### 7. Load-testing capability

No tooling exists anywhere for empirically validating "1000 concurrent users." Standing on its own
merits as future work for whenever a C3 twin exists to test against — propose as a backlog line in
whichever theme fits best at the time (likely a new `INST-` or `OPS-` item depending on scope), not
something to stand up speculatively now.
