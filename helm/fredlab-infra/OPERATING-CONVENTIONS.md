# Fredlab Operating Conventions

Shared operating agreements for the **fredlab playground** platform, co-owned by
**Dimitri, Sébastien, and Arthur**. This is the living "how we run the platform
together" doc — distinct from [DEPLOYMENT-STEPS.md](./DEPLOYMENT-STEPS.md)
(the canonical step-by-step procedure) and [README.md](./README.md) (chart
reference).

If a habit affects all three of us — how we tag, when we deploy, what we check
before/after — it belongs here so nobody has to guess what the others did.

## How to contribute

- Propose a change as a normal PR/commit to this file. Anyone of the three can
  ratify by merging; if it changes shared behaviour, get a 👍 from the other two
  first.
- Add a row to the **Conventions log** at the bottom when a convention is
  adopted or changed, so we keep the history of *why*.
- Keep it short and operational. Deep design rationale goes in `rfc/`.

---

## C1 — Image tagging

**Convention:** every image we build is tagged `YYYYMMDD-<shortsha>`.

- `YYYYMMDD` — UTC build date (sortable, tells us *when* at a glance).
- `<shortsha>` — `git rev-parse --short HEAD` of `~/fred` at build time
  (exact code provenance, fully reproducible).
- Example: `20260624-9ee83e7`.

**Rules:**

1. **One tag per build round, identical across every image** built from the
   same monorepo commit. The tag is a coherence marker: the same tag on
   `control-plane-backend`, `fred-agents`, and `knowledge-flow-backend` means
   "these three came from the same commit, no version skew."
2. **Build from a clean tree.** `gcloud builds submit` tars the working tree
   as-is — if `~/fred` is dirty, the `<shortsha>` lies about the content.
   Confirm `git status` is clean before building.
3. **Never reuse a tag for different content.** Because the SHA changes with
   every commit, a same-day rebuild after a code change gets a new tag
   automatically — don't hand-edit it back.
4. **Don't rely on the build script's SHA-only default.** Passing the tag
   explicitly keeps the date in it and keeps all images in the round aligned.

**Compute once, build all, reuse the variable** (this is what prevents
divergent hand-typed tags):

```bash
cd "$HOME/fred"
git diff --quiet && git diff --cached --quiet || echo "⚠ tree is dirty — tag will not match content"
TAG="$(date +%Y%m%d)-$(git rev-parse --short HEAD)"      # e.g. 20260624-9ee83e7
echo "Build tag: $TAG"

cd "$HOME/fred-deployment-factory"
bin/fredlab-build control-plane-backend  "$TAG"
bin/fredlab-build fred-agents            "$TAG"
bin/fredlab-build knowledge-flow-backend "$TAG"
```

## C2 — Deploy at the round's tag

Deploy every component at the same `$TAG` so the whole stack is one version.
Knowledge Flow keeps `migrate` and `start` explicit; `start` brings up the
backend **and** the Temporal worker off the same tag/GSA.

```bash
bin/fredlab-knowledge-flow-deploy.sh migrate "$TAG"
bin/fredlab-knowledge-flow-deploy.sh start   "$TAG"
bin/fredlab-control-plane-deploy.sh  start   "$TAG"   # migrate first if schema changed
bin/fredlab-frontend-deploy.sh       start   "$TAG"
```

## C3 — Know what is deployed right now

`bin/fredlab-status.sh` prints an **IMAGE TAG** column per workload — the single
source of truth for "what is running". After any deploy, run it and confirm the
app workloads show the `$TAG` you just shipped, and that App readiness `/ready`
is green.

Quick one-off without the full dashboard:

```bash
kubectl get deploy,statefulset -n default \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
```

If `/ready` shows `degraded` for `knowledge-flow`, port-forward and read the
per-dependency JSON before assuming an infra outage — it names the exact failing
backend (Postgres / OpenSearch / OpenFGA / GCS):

```bash
kubectl -n default port-forward deploy/knowledge-flow-backend 8111:8111 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -sS -m 30 http://localhost:8111/knowledge-flow/v1/ready; echo
kill $PF
```

## C4 — Retention & cost control

The playground accumulates images and logs that quietly cost money. Two
idempotent scripts set the guardrails (run `-h` on either for full detail):

- **`bin/fredlab-gcp-image-retention.sh`** — Artifact Registry cleanup policy
  (keep most-recent 10 versions/package, delete untagged >3d, tagged >30d; Keep
  wins over Delete so the deployed image is never pruned) + a 14-day lifecycle on
  the Cloud Build staging bucket. Defaults to **dry-run**; `--apply` to enable.
- **`bin/fredlab-gcp-log-retention.sh`** — `_Default` log bucket retention (7d)
  + an exclusion that drops sub-WARNING `default`-namespace container logs before
  ingestion (ingestion is the real cost). Defaults to **preview**; `--apply` to
  enable. Disable the exclusion while actively debugging an ingestion.

```bash
bin/fredlab-gcp-image-retention.sh            # preview, then --apply
bin/fredlab-gcp-log-retention.sh              # preview, then --apply
```

**Also set a billing budget** (Billing → Budgets) on the playground project with
email alerts at 50/90/100%. It is the catch-all backstop for image storage, log
ingestion, and everything else — two minutes, not scriptable here because it
needs the billing-account ID.

Agreed defaults are the script defaults above; tune via the documented env
overrides (`KEEP_COUNT`, `LOG_RETENTION_DAYS`, …) rather than editing the scripts.

---

## Conventions log

| Date       | ID | Convention                                   | Proposed by | Status   |
| ---------- | -- | -------------------------------------------- | ----------- | -------- |
| 2026-06-24 | C1 | Image tagging `YYYYMMDD-<shortsha>`          | Dimitri     | Adopted  |
| 2026-06-24 | C2 | Deploy every component at the round's tag    | Dimitri     | Adopted  |
| 2026-06-24 | C3 | `fredlab-status.sh` IMAGE TAG = what's live  | Dimitri     | Adopted  |
| 2026-06-24 | C4 | Retention & cost control scripts + budget    | Dimitri     | Adopted  |
