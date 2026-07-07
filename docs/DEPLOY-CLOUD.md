# Deploy to the cloud (GKE/GCP)

How to ship the latest Fred to the live **GKE/GCP** instance. This is the GitOps path: you
build images into Artifact Registry, record the new image tags in git, and ArgoCD reconciles
the cluster. **You do not build locally — Google Cloud Build does the builds**, so you just
need an authenticated `gcloud`.

Mental model: **authenticate once → (validate) → build & bump → push → sync.**

> Scope: this is the end-to-end *operator* guide. The ArgoCD-specific reference (one-time
> bootstrap, the Foundation/Apps boundary, per-app cutover, admin RBAC) lives in
> [`../argocd/README.md`](../argocd/README.md); the imperative Foundation (Postgres, Keycloak,
> OpenFGA, …) lives in [`../helm/fredlab-infra/`](../helm/fredlab-infra/README.md).

## Prerequisites

**Tools on your laptop:** `gcloud`, `kubectl`, `helm`, `git`, and a Fred monorepo checkout
(the source the images are built from — its `HEAD` short-sha becomes the image tag).

> **Where's the monorepo? One knob: `FRED_REPO_DIR` (default `~/fred`).** It is the single
> source of truth — used for both the tag *and* the build source (the catalog
> `config/fredlab-images.tsv` defers to it via the `$FRED_REPO_DIR` sentinel). If your
> checkout isn't at `~/fred`, set it once and everything follows:
> ```bash
> export FRED_REPO_DIR="$HOME/path/to/fred"   # e.g. ~/Fred/fred — add to ~/.bashrc
> ```
> Don't hand-edit paths in the catalog or the scripts; setting this variable is the whole story.

**Access:** the GKE/GCP instance is private. New team members: contact **Dimitri Tombroff**
(`dimitri.tombroff@fredlab.dev`) to be granted GCP project / GKE access, a Keycloak login, and
ArgoCD RBAC.

## 1. Authenticate your laptop (once per machine / when creds expire)

```bash
gcloud auth login                                   # browser SSO to your Google account
gcloud config set project fredlab-playground        # the GCP project (Artifact Registry + GKE live here)

# kubectl access to the GKE cluster (needed for the sync + status steps):
gcloud components install gke-gcloud-auth-plugin     # one-time, if not already present
gcloud container clusters get-credentials fredlab-playground-gke \
  --region europe-west9 --project fredlab-playground
```

> `gcloud init` does the `login` + `set project` interactively if you prefer a single prompt.

Quick check you're wired up:

```bash
gcloud config get-value project        # -> fredlab-playground
kubectl -n argocd get applications     # -> lists 'fred-apps'
```

> **Regions (don't mix them up):** the **GKE cluster is `europe-west9`**, but **Artifact
> Registry is `europe-west1`** (project `fredlab-playground`, repo `fredlab-repo`). The build
> scripts default to the right ones; just don't hand-edit them apart.

## 2. (First time only) enable the GCP build backend

One-time per project — enables the Cloud Build / Artifact Registry APIs, creates the
`fredlab-repo` registry, and grants the build service accounts push rights:

```bash
bin/fredlab-gcp-build-prereqs.sh
```

The one-time **ArgoCD bootstrap** (static IP + DNS, Keycloak OIDC client, install, expose,
register the `fred-apps` Application) is documented in
[`../argocd/README.md`](../argocd/README.md#one-time-setup-run-in-order). You only need it
when standing up a fresh cluster.

## 3. Validate before you ship (release gate)

The black-box **auth / team-isolation** suite — it proves Keycloak identity + OpenFGA
authorization + cross-team isolation against a *running* stack. Run it against your local
stack as the release gate for a `swift` candidate:

```bash
make validate-auth-isolation-localhost
```

It spins up a venv, installs the Fred libs editable, and runs the scenarios in `validation/`
against the localhost control-plane + runtime. See [`../validation/README.md`](../validation/README.md)
for the auth matrix it asserts. (A k3d/ingress variant, `validate-auth-isolation-k3d`, is
planned but not yet implemented.)

## 4. Ship it — the steady-state loop

Pull the latest `~/fred` first, then **four commands**:

```bash
bin/fredlab-release.sh all                     # 1. Cloud Build the 4 app images from ~/fred HEAD,
                                               #    then rewrite the image tags in values-fredlab.yaml
git commit -am "release <tag>" && git push     # 2. record the new tags in git (NOT a deploy yet)
bin/fredlab-argocd-sync.sh                      # 3. THE DEPLOY: apply git to the cluster
bin/fredlab-status.sh                           # 4. verify: new tag, healthy
```

What each step really does:

- **`fredlab-release.sh all`** — derives the tag `YYYYMMDD-swift-<shortsha>` from `~/fred`
  `HEAD`, submits a Cloud Build for each of the four app-layer images (control-plane-backend,
  fred-frontend, fred-agents, knowledge-flow-backend — the worker reuses the backend image),
  and rewrites the `# release-tag:` lines in `argocd/fred-apps/values-fredlab.yaml`. It does
  **not** commit, push, or touch the cluster. Build just one app with
  `bin/fredlab-release.sh <control-plane|frontend|fred-agents|knowledge-flow>`, or reuse an
  already-built image with `bin/fredlab-release.sh <component> <tag>`.
- **`git push`** — records the tag change. ArgoCD now shows **OutOfSync**, but nothing has
  reached the cluster yet. The push is a reviewable checkpoint.
- **`fredlab-argocd-sync.sh`** — *this* is the deploy. It drives the `fred-apps` Application
  via `kubectl` (no `argocd` CLI needed) and warns if your `HEAD` isn't pushed (ArgoCD syncs
  from git, not your laptop). Clicking **SYNC** in the ArgoCD UI does the same thing.
- **`fredlab-status.sh`** — shows the live image tag + per-app health (it probes each app's
  dependency-aware `/ready` endpoint in-cluster).

> **Sync is manual by design.** Auto-sync is intentionally **off** (no `automated:` block on
> the `fred-apps` Application). Pushing makes ArgoCD show OutOfSync; only the sync deploys.

## Rollback

Revert the tag commit in git and re-sync, or use ArgoCD history:

```bash
argocd app history fred-apps
argocd app rollback fred-apps <rev>
```

## Imperative fast path (alternative)

`bin/fredlab-ship` builds only what changed and rolls control-plane + frontend + agents
directly via `helm upgrade` (`-fast`), bypassing the git/ArgoCD loop. Handy for a quick code
redeploy when infra/values are unchanged; the GitOps loop above is the reviewed reference path.

```bash
bin/fredlab-ship                 # derive tag from ~/fred HEAD, build only missing images, fast-redeploy
bin/fredlab-ship --tag <tag>     # ship an exact tag
bin/fredlab-ship --redeploy      # roll at the tag even when nothing was rebuilt
```
