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

## C5 — ghcr.io as the image source (proposed 2026-07-15, pending ratification)

**Proposal:** for routine redeploys, source the four app images directly from the images
`.github/workflows/Build-and-push-docker.yml` (`fred` repo) already builds and pushes on
every `swift` push and `code/v*` tag — `ghcr.io/thalesgroup/fred-agent/<image>` — instead
of re-building the same commit into Artifact Registry via `bin/fredlab-release.sh`.

**Why:** CI already builds and pushes these on every relevant push/tag; the images are
public (`docker manifest inspect` succeeds anonymously — no `imagePullSecret` needed on
GKE); same Dockerfiles (`apps/<app>/dockerfiles/Dockerfile-prod`) as `fredlab-build`, so
it's not a different artifact, just built once instead of twice. A `code/vX.Y.Z` release
tag on `fred` maps directly to `ghcr.io/thalesgroup/fred-agent/<image>:vX.Y.Z` — deploying
that tag ties the running instance to a named GitHub Release rather than an
independently-built copy with its own `YYYYMMDD-<shortsha>` tag.

**What changes mechanically, if ratified:** `values-fredlab.yaml`'s `image.repository` for
`controlPlane`/`controlPlaneWorker`/`fredAgents`/`knowledgeFlow`/`knowledgeFlowWorker`/
`fredFrontend` points at `ghcr.io/thalesgroup/fred-agent/<image>` with `tag: "vX.Y.Z"`
(matching the `code/v*` tag on `fred`), and the release step becomes "edit the values
file to the new release tag" instead of running `bin/fredlab-release.sh`. `fredEvaluation`
images aren't built by this workflow and stay on Artifact Registry regardless.
`bin/fredlab-release.sh`/Cloud Build remain useful for testing an unpushed local commit
before it lands on `swift` — this doesn't retire that path, only changes the default for
routine redeploys of released code.

**Status: proposed, not adopted.** Per this doc's own rule ("if it changes shared
behaviour, get a 👍 from the other two first"), this needs Sébastien's and Arthur's
sign-off before C1/C2 above stop being the default. Used once, live, on 2026-07-15
(GKE C1 redeploy at `v2.1.1`) as the worked example this proposal is based on.

## C2 — Deploy at the round's tag

Deploy every component at the same `$TAG` so the whole stack is one version.
Knowledge Flow keeps `migrate` and `start` explicit; `start` brings up the
backend **and** the Temporal worker off the same tag/GSA.

```bash
bin/fredlab-deploy.sh knowledge-flow migrate "$TAG"
bin/fredlab-deploy.sh knowledge-flow start   "$TAG"
bin/fredlab-deploy.sh control-plane  start   "$TAG"   # migrate first if schema changed
bin/fredlab-deploy.sh frontend       start   "$TAG"
```

## C2.1 — Fast redeploys (`-fast`)

Every `helm upgrade` re-runs the `keycloak-provision` post-upgrade hook, and helm
**blocks** until it finishes. That hook is now heavy (it builds the temporal-ui
auth flow via dozens of sequential `kcadm` calls), so re-provisioning on every
code redeploy wastes minutes for no benefit — the realm, clients, and flow already
exist after the first deploy.

For an **app-only redeploy** (new image tag, identity unchanged), pass `-fast` to
skip that hook:

```bash
bin/fredlab-deploy.sh control-plane  start -fast "$TAG"
bin/fredlab-deploy.sh knowledge-flow start -fast "$TAG"
bin/fredlab-deploy.sh agents         start -fast "$TAG"
bin/fredlab-deploy.sh frontend       start -fast "$TAG"
```

`-fast` is position-independent (`start -fast <tag>` or `start <tag> -fast`) and
accepted by every deploy script; `SKIP_PROVISION=1` is an equivalent env alias.

Rules:

- **Use `-fast` for everyday code redeploys.** Run a normal `start` (no `-fast`)
  only when you changed identity — added a Keycloak client/role, or it's the first
  deploy on a fresh cluster — or when a teammate's merge touched the provisioning
  job (e.g. the temporal-ui auth flow). The default always (re)provisions.
- **Don't `disable` to "restart".** `start` rolls to the new image on its own.
  Disabling the frontend also tears down its `ManagedCertificate`, costing a
  15–60 min cert re-provision (`ERR_CERT_COMMON_NAME_INVALID`) when you bring it back.
- **Just bouncing pods (same image)?** Skip helm entirely — no hooks, no cert churn:

  ```bash
  kubectl rollout restart deploy/control-plane-backend deploy/knowledge-flow-backend \
    deploy/knowledge-flow-worker deploy/fred-agents deploy/fred-frontend
  ```

## C2.2 — `fredlab-ship`: the one-command code redeploy

The everyday loop — "I pulled the latest `~/fred`, push it live" — is a single
command. It derives the round tag, builds only what changed, and fast-redeploys
the app trio. It assumes infra/helm values are unchanged.

```bash
bin/fredlab-ship
```

What it does, in order:

1. **Derives the tag** from `~/fred` HEAD as `YYYYMMDD-<shortsha>` (C1); warns if
   the tree is dirty.
2. **Builds only what changed.** Because the tag embeds the sha, a new commit is a
   tag that is not yet in Artifact Registry. Per image (`control-plane-backend`,
   `fred-frontend`, `fred-agents`): already present → skip, absent → build. The
   registry *is* the change-detection state — no state file.
3. **Fast-redeploys** at that tag via `bin/fredlab-deploy.sh ... -fast`:
   control-plane `migrate` then `start`, then frontend and agents. The migrate is
   idempotent (`alembic upgrade head` is a no-op at head); `--no-migrate` skips it.
4. **Prints `fredlab-status.sh`** so you watch the new IMAGE TAG go green.

If HEAD has not moved since the last ship, every image is already in the registry
and the command is a no-op (`--redeploy` rolls anyway; `--force` rebuilds anyway).

Use `bin/fredlab-deploy.sh` directly (normal, non-`-fast`) for anything outside
this loop: identity changes, a fresh cluster, or knowledge-flow / evaluation —
`fredlab-ship` deliberately covers only the three frequently-changed app images.

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
| 2026-06-24 | C2.1 | `-fast` skips keycloak-provision on redeploys | Dimitri   | Adopted  |
| 2026-06-24 | C3 | `fredlab-status.sh` IMAGE TAG = what's live  | Dimitri     | Adopted  |
| 2026-06-24 | C4 | Retention & cost control scripts + budget    | Dimitri     | Adopted  |
| 2026-06-25 | C2.2 | `fredlab-ship` one-command build+fast-redeploy | Dimitri   | Adopted  |
| 2026-06-25 | — | Folded per-app deploy scripts into generic `fredlab-deploy.sh` | Dimitri | Adopted  |
