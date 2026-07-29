# GDPR / data-hygiene audit workstream

Ground every finding in `fred`'s `docs/swift/platform/OBSERVABILITY-AND-AUDIT.md` (the three-stream
model: operational metrics / product analytics / security-audit trail — read it once per session if
it's been a while, it's the target spec). This checklist is the deployment-factory-side half of
that model: the *code*-side guarantees (no email ever logged, audit logger carries only opaque IDs,
Prometheus labels structurally excluding identity) are `fred`'s responsibility and were already
verified sound as of `code/v2.1.13` — this workstream is about whether the *cluster* respects those
guarantees, which is squarely this repo's job.

## The closed checklist

1. **Is the log-ingestion cost/hygiene exclusion actually active, and in the right namespace?**
   ```bash
   gcloud logging sinks describe _Default --format='yaml(exclusions)'
   gcloud logging buckets describe _Default --location=global --format='yaml(retentionDays)'
   ```
   `exclusions: null` means `bin/fredlab-gcp-log-retention.sh` was never run with `--apply`, or was
   run before the `default`→`fred-demo` namespace rename and never re-applied — confirmed exactly
   this state on 2026-07-24. `retentionDays: 30` with no custom exclusion means every INFO-level
   log from every app is being ingested and retained at full volume, unfiltered, right now — a
   live cost/governance regression against this repo's own stated `C4` convention
   (`gcp-c1/helm/OPERATING-CONVENTIONS.md`), not a hypothetical. If still true, this is a
   ready-to-run fix — see `remediation-snippets.md`.

2. **Does OpenSearch require authentication?**
   ```bash
   kubectl -n fred-demo exec deploy/control-plane-backend -- python3 -c \
     "import urllib.request; print(urllib.request.urlopen('http://opensearch:9200/_cat/indices').read().decode())"
   ```
   If this succeeds with zero credentials (confirmed true on 2026-07-24), any pod in the namespace
   can read/write/delete the entire `kpi-index` — which carries real `user_id`/`session_id`/
   `team_id`, not anonymous aggregates (`OpenSearchKPIStore`, `libs/fred-core/fred_core/kpi/
   opensearch_kpi_store.py` — it's a deliberate per-user store with a real
   `anonymise_for_session()` erasure primitive, gated behind control-plane's admin-only KPI preset
   API in code; the gap is that nothing enforces that gate at the OpenSearch layer itself, so any
   in-cluster workload bypasses it entirely). **This is the single highest-value finding this
   workstream can surface** — a genuine access-control gap, not a code defect, and not something to
   template as a quick fix (re-enabling OpenSearch's security plugin means credential rotation for
   every client that talks to it — control-plane, knowledge-flow, the KPI dashboards). Propose a
   `docs/BACKLOG.md` `SEC-` entry (check the file for the actual next number — was `SEC-5` as of
   this writing) if still open; do not attempt to fix it yourself.

3. **Any new PII-in-logs regression, matching the known pattern?**
   The one confirmed violation as of `code/v2.1.13`:
   `apps/knowledge-flow-backend/knowledge_flow_backend/features/vector_search/
   vector_search_controller.py:202` — `logger.info("SECURITY: test_post_success called by user: %s",
   user.username)` on the generic app logger (not the audit logger), on a reachable `/vector/test`
   route. Contradicts the project's own stated policy: "directly identifying data (name, email) —
   nowhere" (`OBSERVABILITY-AND-AUDIT.md` §7). To check for *new* instances of this pattern when
   auditing a newer `fred` tag, grep the checked-out monorepo (`~/Fred/fred`) for:
   ```bash
   grep -rn "logger\.\(info\|warning\|error\)(.*\(username\|\.email\b\)" apps/*/  --include="*.py" | grep -v "fred\.security\.audit\|test_"
   ```
   (adjust and re-verify by hand — this is a starting grep, not a certified detector; false
   positives on service-account/infra-config usernames are expected and not the same category as
   an end-user's identity, see the distinction already drawn in this skill's design notes).

4. **Has `log_level` drifted off its safe INFO default anywhere?**
   ```bash
   kubectl -n fred-demo get cm control-plane-config knowledge-flow-config -o jsonpath='{.data.configuration\.yaml}' | grep -i "log_level"
   ```
   INFO is the only level verified safe today. A latent risk exists at DEBUG:
   `libs/fred-runtime/fred_runtime/react/react_runtime.py` stringifies raw tool-result content into
   a `logger.debug(...)` call — harmless only because DEBUG records never reach the store handler
   at the INFO default (`log_setup.py`). If you ever find `log_level: debug` configured anywhere,
   that's an immediate, concrete content-leak risk into whatever log store is active — treat it as
   urgent, not a style nit.

5. **Is the security audit trail's downstream durability actually decided anywhere?**
   As of `fred`'s own `OBSERVABILITY-AND-AUDIT.md` §5/§9: no — "the guarantee of where it durably
   lives, for how long, and who can read it, is a deployment-level responsibility that must be
   established per classification level," and its own maturity table flags this as **not yet
   established at any classification level**. Check whether this repo has since done anything about
   it (grep `gcp-c1/` and `docs/` for a Cloud Logging sink/export rule scoped to `fred.security.audit`
   records, or a locked-down OpenSearch index for them) — as of this writing, nothing exists. If
   still true, this is exactly the kind of gap that belongs in the `CLASS` backlog theme (was
   through `CLASS-6` as of this writing) since it's explicitly a classification-portability
   question, not a one-off bug.

## Closing this workstream

Report each of the five items above as green / regression-found / not-yet-addressed-gap, with the
live command output as evidence. Don't let #2 (OpenSearch auth) get buried under the others — if
it's still open, it should be the first line of the whole session's summary, not workstream #3's
third bullet point.
