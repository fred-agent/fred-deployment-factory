# Deploy to the cloud (GKE/GCP)

The end-to-end **operator** guide: from an empty GCP project to a working, bootstrapped Fred
instance, and the steady-state loop for shipping new code afterward.

## 0. The big picture

**One GCP project + one GKE cluster can host more than one named Fred instance** — e.g. one
tracking nightly images, another pinned to stable tagged releases for demos — each fully
isolated in its own Kubernetes namespace (convention `C6`,
[`../gcp-c1/helm/OPERATING-CONVENTIONS.md`](../gcp-c1/helm/OPERATING-CONVENTIONS.md)). **ArgoCD
itself is installed once per cluster**, shared across every instance; each instance gets its own
ArgoCD `Application`.

**Every instance has two layers, deliberately split by mechanism and change-rate** (the *why* is
[`../docs/rfc/RFC-0001-gitops-deployment-pattern.md`](rfc/RFC-0001-gitops-deployment-pattern.md)):

| Layer | Contents | Mechanism | Change-rate |
| --- | --- | --- | --- |
| **Foundation** | Postgres, Keycloak, OpenFGA, OpenSearch, Temporal, the instance's Ingress/certs/Secret | imperative Helm, `bin/fredlab-*.sh`, `NAMESPACE=<instance>` | rare, reviewed |
| **Apps** | control-plane, fred-agents, frontend, knowledge-flow (+ fred-evaluation) | ArgoCD GitOps, one `Application` per instance | frequent |

**Standing up a fresh instance is five phases, in order** (skip phase 1 if the cluster already
has ArgoCD — check `kubectl -n argocd get applications`):

1. **Cluster-wide, one-time setup** — auth, build backend, install ArgoCD (§1)
2. **Foundation** for this instance — empty Postgres/Keycloak/OpenFGA/OpenSearch/Temporal (§2)
3. **Apps** for this instance, via ArgoCD (§3)
4. **Root bootstrap** — the *one* secret-gated call that creates the first `platform_admin` (§4)
5. **Declarative import** — populate real teams/users, once identities exist in Keycloak (§5)

Only phase 1 is cluster-wide and non-repeating. Phases 2–5 repeat per named instance. Once an
instance exists, day-to-day work is the steady-state loop (§6).

---

## 1. One-time, cluster-wide setup

Skip this entirely if ArgoCD is already installed on the cluster (`kubectl -n argocd get
applications` lists something) — go straight to §2.

**Tools on your laptop:** `gcloud`, `kubectl`, `helm`, `git`, and a Fred monorepo checkout (the
source app images are built from — its `HEAD` short-sha becomes the image tag when building
locally; see §6). One knob, `FRED_REPO_DIR` (default `~/fred`):

```bash
export FRED_REPO_DIR="$HOME/path/to/fred"   # e.g. ~/Fred/fred — add to ~/.bashrc if it isn't ~/fred
```

**Access:** the GKE/GCP instance is private. New team members: contact **Dimitri Tombroff**
(`dimitri.tombroff@fredlab.dev`) for GCP project / GKE access, a Keycloak login, and ArgoCD RBAC.

### 1.1 Authenticate and connect

```bash
gcloud auth login
gcloud config set project fredlab-playground
gcloud components install gke-gcloud-auth-plugin     # one-time, if not already present
gcloud container clusters get-credentials fredlab-playground-gke \
  --region europe-west9 --project fredlab-playground
```

> **Regions:** the GKE cluster is `europe-west9`; Artifact Registry is `europe-west1`. Scripts
> default to the right ones — don't hand-edit them apart.

### 1.2 Enable the GCP build backend

Enables Cloud Build / Artifact Registry, creates the `fredlab-repo` registry, grants the build
service accounts push rights. Needed for `fred-evaluation` (still Artifact-Registry-sourced) and
for building locally with `bin/fredlab-release.sh`/`bin/fredlab-build` — **not** needed for the 4
core apps if you only ever deploy them from ghcr.io (`C5`, §3.3).

```bash
bin/fredlab-gcp-build-prereqs.sh
```

### 1.3 Install ArgoCD (cluster-wide, once)

```bash
bin/fredlab-argocd-ip.sh                 # reserve the static IP -> create the DNS A record
bin/fredlab-argocd-install.sh            # install ArgoCD (works fine with NO Keycloak yet)
bin/fredlab-argocd-expose.sh             # Ingress + ManagedCertificate for the ArgoCD UI
```

`fredlab-argocd-install.sh` degrades gracefully on a truly empty cluster: if no `argocd` Keycloak
client exists yet (because no instance's Keycloak is up yet), it installs **without OIDC** and
tells you so — that's expected on a first run. Wire up OIDC login after §2 gives you a Keycloak
to point at:

```bash
NAMESPACE=<instance> bin/fredlab-argocd-keycloak-client.sh   # confidential 'argocd' client in that instance's realm
bin/fredlab-argocd-install.sh                                 # re-run — picks up the client secret, enables OIDC
```

Full detail (admin RBAC, boundary contract, rollback): [`../gcp-c1/argocd/README.md`](../gcp-c1/argocd/README.md).

---

## 2. Stand up this instance's Foundation

Everything below is namespaced by `NAMESPACE=<instance-name>` (e.g. `fred-demo`) — every script
takes it as an env var and creates the namespace idempotently (`--create-namespace`); there is no
separate manual `kubectl create namespace` step, for this or any future instance.

### 2.1 Prepare the secrets file

```bash
cp gcp-c1/helm/fredlab-secrets.values.example.yaml gcp-c1/helm/fredlab-secrets.values.yaml   # first instance only; git-ignored
```

Fill in the DB/Keycloak/OpenFGA passwords, **and** generate this instance's one-time root-bootstrap
secret (never generated or logged by Fred itself):

```bash
TOKEN=$(openssl rand -hex 32)
printf 'controlPlaneBootstrapToken: "%s"\n' "$TOKEN" >> gcp-c1/helm/fredlab-secrets.values.yaml
unset TOKEN
```

Keep that value somewhere private for yourself — you need it again in §4, and it's never printed
back by any script.

### 2.2 Deploy the Foundation

```bash
NAMESPACE=<instance> bin/fredlab-infra-deploy.sh
```

Creates the namespace, fresh Postgres/Keycloak/OpenFGA/OpenSearch/Temporal, and this instance's
Ingress + ManagedCertificates (reusing a shared reserved static IP is fine across instances that
share hostnames one-at-a-time — see the note on decommissioning an old instance, §2.4). TLS cert
issuance takes **15–60 minutes**; the rest of this guide doesn't need to wait for it (internal
cluster DNS is used everywhere until §4's browser step).

### 2.3 Workload Identity for this instance's service accounts

```bash
NAMESPACE=<instance> bin/fredlab-gcp-gcs-prereqs.sh
```

Additive and idempotent — binds `knowledge-flow-backend`/`-worker`/`fred-agents`/
`fred-evaluation-*` in **this namespace** to the shared GCS service account via Workload
Identity. Same GCS buckets are reused (they're project-scoped, not namespace-scoped). **Do not
skip this** — without it, `knowledge-flow-backend` crash-loops on startup with a `403` fetching a
GCP access token (missing IAM policy binding), because embeddings need Vertex AI credentials.

### 2.4 Moving an existing instance to a new namespace (e.g. renaming `default` → a named instance)

Only relevant if you're migrating an instance that used the bare `default` namespace. The
reserved static IP and DNS records are **not namespace-scoped** and can be reused as-is — only
one Ingress can hold the IP at a time, so free it first:

```bash
kubectl delete ingress <old-ingress-name> -n <old-namespace>
kubectl delete managedcertificate <old-cert-names...> -n <old-namespace>
# then §2.2 into the new namespace claims the same IP/hostnames — new ManagedCertificates,
# same DNS, 15-60 min reprovisioning window, no DNS record changes needed.
```

Once the new instance is verified (through §4), decommission the old namespace's Foundation:
`helm uninstall fredlab-infra -n <old-namespace>`.

> **Don't forget ArgoCD's OIDC login still points at the old namespace's Keycloak.** ArgoCD is
> cluster-wide (§1.3) and was wired up once, against whichever namespace was live at the time —
> its OIDC issuer is the *public* hostname (`https://<keycloak-host>/realms/app`), which now
> resolves to the *new* namespace once its Ingress claims the shared static IP (above). But the
> `argocd` Keycloak **client** itself only exists in the *old* namespace's realm — the new
> Keycloak is a brand-new empty realm and was never given one. Symptom: ArgoCD redirects to
> Keycloak fine, but login fails for everyone, on every account, with no useful error — because
> the OIDC client the redirect needs simply doesn't exist where ArgoCD is now actually pointed.
> Fix, right after §2.2 stands up the new namespace's Foundation:
>
> ```bash
> NAMESPACE=<new-namespace> bin/fredlab-argocd-keycloak-client.sh   # create the argocd client in the NEW realm
> KC_NAMESPACE=<new-namespace> bin/fredlab-argocd-install.sh        # re-run install to pick up its secret (note: KC_NAMESPACE, not NAMESPACE)
> ```

### 2.5 Validate

```bash
NAMESPACE=<instance> bin/fredlab-status.sh
NAMESPACE=<instance> bin/fred-preflight.sh   # read-only: realm/OpenFGA shape, no live users expected yet
```

---

## 3. Deploy this instance's Apps layer via ArgoCD

> **Today, one `Application` = one instance.** `gcp-c1/argocd/applications/fred-apps.yaml`
> declares a single Application; standing up a **second** concurrent instance means copying that
> file (new `metadata.name`, `spec.destination.namespace`, its own `values-<instance>.yaml`) —
> `bin/fredlab-argocd-app.sh`/`bin/fredlab-release.sh` are currently hardwired to the one file and
> would need a parameter to target a second one. Tracked as a known gap in `OPERATING-CONVENTIONS.md`
> `C6` (`CHART-2`/`INST-1` backlog territory), not solved by this doc.

### 3.1 Point the Application at this instance

Edit `gcp-c1/argocd/applications/fred-apps.yaml`: `spec.destination.namespace: <instance>`,
`syncOptions: [CreateNamespace=true, ...]` (namespace created idempotently by ArgoCD itself — no
manual step). Then register/update it:

```bash
bin/fredlab-argocd-app.sh
```

### 3.2 Migrate the app schemas onto the fresh Foundation database

Required on a fresh Foundation — without it, `control-plane-backend` has no
`platformbootstrap` table (§4 fails outright) and `knowledge-flow-backend` has no metadata
tables.

```bash
NAMESPACE=<instance> bin/fredlab-deploy.sh control-plane migrate <tag>
NAMESPACE=<instance> bin/fredlab-deploy.sh knowledge-flow migrate <tag>
```

`<tag>` must be an image that already exists somewhere the script can pull from — by default
Artifact Registry (`bin/fredlab-release.sh`/`bin/fredlab-build`, §6). To migrate using an image
sourced from ghcr.io instead (see `C5` below) without a redundant local rebuild:

```bash
NAMESPACE=<instance> REGISTRY_BASE=ghcr.io/thalesgroup/fred-agent bin/fredlab-deploy.sh control-plane migrate v2.1.1
NAMESPACE=<instance> REGISTRY_BASE=ghcr.io/thalesgroup/fred-agent bin/fredlab-deploy.sh knowledge-flow migrate v2.1.1
```

### 3.3 Point the four core apps at the images to run

**Convention `C5` (proposed, `OPERATING-CONVENTIONS.md`, pending Sébastien/Arthur's 👍):** `fred`'s
own `Build-and-push-docker.yml` already builds and pushes `control-plane-backend`, `fred-agents`,
`knowledge-flow-backend`, `frontend` to `ghcr.io/thalesgroup/fred-agent/<image>` on every `swift`
push and `code/v*` tag — publicly pullable, no `imagePullSecret` needed. A `code/vX.Y.Z` release
tag maps directly to `ghcr.io/thalesgroup/fred-agent/<image>:vX.Y.Z`. Point
`gcp-c1/argocd/fred-apps/values-fredlab.yaml`'s `image.repository`/`tag` there for a release, or
use the classic Cloud-Build path (`bin/fredlab-release.sh`, §6) if you'd rather build locally.
`fred-evaluation` (separate repo, `fred-agent-evaluator`) has its own analogous
`Build-and-push-docker.yml` and is sourced from `ghcr.io/fred-agent/fred-evaluation-api` /
`fred-evaluation-worker` the same way, at its own `code/vX.Y.Z` tag — not on Artifact Registry.

```bash
git commit -am "release vX.Y.Z" && git push
```

### 3.4 Sync and validate

```bash
bin/fredlab-argocd-sync.sh
NAMESPACE=<instance> bin/fredlab-status.sh
```

> **Check for pending migrations before calling a `control-plane`/`knowledge-flow` bump done.**
> The sync only rolls the new image — it never runs alembic. Diff `apps/<app>/alembic/versions/`
> between the old and new tag in the `fred` repo; if the new tag added a revision, run §3.2's
> `migrate` command again at the new tag. Skipping it doesn't fail the sync — it surfaces later
> as a live `UndefinedColumnError`/`UndefinedTableError` on the first request touching the new
> schema (hit live on fredlab, 2026-07-21).
>
> **A brand-new M2M/service-account client (e.g. a freshly wired `fred-evaluation-worker`) needs
> one-time GCU acceptance too**, same mechanism as §4.1's human bootstrap — control-plane's
> `get_current_user` 403s with `user_not_accept_gcu` for *any* caller, service identities
> included, until it's accepted once. There is no UI flow for a service account, so do it
> manually: get an M2M token via `client_credentials` for that Keycloak client, then
> `POST /control-plane/v1/gcu` with it (empty body, once, idempotent). Easy to misdiagnose as a
> permissions/role bug — check the response body for `user_not_accept_gcu` before chasing ReBAC.

---

## 4. Root bootstrap — the first `platform_admin`

**No identity is ever declared in deployment config.** The secret generated in §2.1 only proves
"I have deploy-time access to this instance" — it never names a target user; the grant always
targets the caller's own authenticated identity, and it can only ever succeed once (durably
persisted, survives even a later total loss of every `platform_admin`). Full design: `fred`'s
`docs/swift/rfc/FRED-AUTHORIZATION-TARGET-MODEL-RFC.md` Part 8 (§40-42).

### 4.1 Create your own account — **not** self-registration

> **On GKE, `registrationAllowed` is `false` by design** — unlike local/k3d dev (which sets it
> `true` for convenience), this instance's realm never exposes a public sign-up form. The very
> first account (yours) is **admin-created**:

```bash
kubectl exec -n <instance> deploy/keycloak -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin \
  --password "$(kubectl get secret fredlab-infra-secrets -n <instance> -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"

kubectl exec -n <instance> deploy/keycloak -- /opt/keycloak/bin/kcadm.sh create users -r app \
  -s username=<your email> -s email=<your email> -s enabled=true -s emailVerified=true \
  -s firstName=<First> -s lastName=<Last>

kubectl exec -n <instance> deploy/keycloak -- /opt/keycloak/bin/kcadm.sh set-password -r app \
  --username <your email> --new-password '<choose one>'
```

> `kcadm` caches its admin session **inside the running `keycloak` pod**
> (`~/.keycloak/kcadm.config` in that container), so the `config credentials` call is only
> needed once per pod lifetime — every subsequent `kubectl exec ... kcadm.sh ...` into the
> *same* pod reuses it. A pod restart clears it and the login step is needed again.

> **`firstName`/`lastName` are not optional here** — this realm's User Profile schema marks
> both `required` for the `user` role. Omit them and every subsequent password-grant login
> fails with `invalid_grant: Account is not fully set up` — a generic Keycloak message that
> gives no hint it's a missing-profile-field issue, not a password or required-action problem.
> If you already created the account without them: `kcadm.sh update users/<id> -r app -s
> firstName=<First> -s lastName=<Last>`.
>
> **Direct (password) grant is also disabled by default** on the `app` client
> (`directAccessGrantsEnabled: false` — sensible for a public client that should normally only
> use the browser redirect flow). This one bootstrap step needs it enabled once:
> `kcadm.sh update clients/<app-client-uuid> -r app -s directAccessGrantsEnabled=true` (get the
> UUID via `kcadm.sh get clients -r app -q clientId=app --fields id --format csv --noquotes`).

Every subsequent real user is created by §5's declarative import (server-side, under an
authenticated `platform_admin` session) — never by a public registration form, on this instance.

### 4.2 Call the bootstrap endpoint

**Two different hostnames, not one** — the token comes from Keycloak's own public host; the
bootstrap call goes through the frontend, which proxies `/control-plane/*` to control-plane-backend.
`<instance-studio-host>` does **not** proxy `/realms/*` — using it for the token request returns
the frontend's SPA HTML (`200`, but not JSON), not a token.

**A brand-new user must accept the Terms of Use (GCU) first, or `get_current_user` 403s with
`user_not_accept_gcu`** — this is a global auth-dependency check applied to nearly every
authenticated route (bootstrap included), not something bootstrap opts into specially. The
frontend does this invisibly via a modal on first login; calling the API directly, do it
explicitly with one empty-body call before bootstrap:

```bash
TOKEN=$(curl -s https://<instance-keycloak-host>/realms/app/protocol/openid-connect/token \
  -d grant_type=password -d client_id=app \
  -d username=<your email> -d password=<your password> \
  | jq -r .access_token)

curl -s -X POST https://<instance-studio-host>/control-plane/v1/gcu -H "Authorization: Bearer $TOKEN"

SECRET=$(grep '^controlPlaneBootstrapToken:' gcp-c1/helm/fredlab-secrets.values.yaml | sed -E 's/^controlPlaneBootstrapToken: *"(.*)"$/\1/')

curl -s -X POST https://<instance-studio-host>/control-plane/v1/bootstrap/platform-admin \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"token\": \"$SECRET\"}"
```

Success looks like `{"user_id": "...", "username": "..."}`. The grant is one-shot and permanent
— a second call, ever, returns `409` (the durable marker) — a quick way to *prove* the grant
actually stuck, not just that the first call returned `200`. Confirm by logging into Studio and
checking **Admin → Migration** is reachable.

---

## 5. Populate real teams and users

Two separate mechanisms, deliberately not one — identity (who exists, what's their first
credential) and authorization (which team, which role) have different owners and different
sensitivity, so they don't share a format. See `docs/rfc/RFC-0001-gitops-deployment-pattern.md`
§2 (Layer C) for why.

### 5.1 Identity — create the Keycloak accounts

Every target user must exist in Keycloak before Fred can grant them anything (§4.1's admin-create
path did this manually for the very first account; everyone else uses this script). Author a
git-ignored roster file — copy the tracked example, it is never committed:

```bash
cp config/fredlab-keycloak-identity.example.json config/fredlab-keycloak-identity.json
# edit: real username/email/firstName/lastName per user; leave "temporaryPassword" out to
# auto-generate a strong one, or set your own
```

```bash
NAMESPACE=<instance> bin/fredlab-keycloak-provision-users.sh --dry-run   # preview first
NAMESPACE=<instance> bin/fredlab-keycloak-provision-users.sh
```

Each new user is created with a **one-time temporary password** — Keycloak forces
`UPDATE_PASSWORD` at their first login (`kcadm set-password --temporary`), the same mechanism
Keycloak's own admin console uses for admin-created accounts. Auto-generated passwords are
printed once at the end of the run — hand them to each user over a secure channel (never Slack/
email in the clear, never a log file) and discard the terminal output afterward. The script is
idempotent: a username that already exists is left completely untouched, so re-running it to add
new hires to an existing roster is safe.

This is **identity only** — no team, no role, no group is created here. Fred never sees a
password: nothing above touches control-plane, and Fred's own `users.json` (next) never carries
one for a real team.

### 5.2 Authorization — grant teams and roles

With identities in place, a `manifest.json` + `users.json` bundle declares their teams/roles and
is uploaded through **Admin → Migration** (`POST /import-export/import`). For a real team, every
`users.json` entry should name only `username` + `teams`/`team_roles`/`platform_roles` — **omit
the `password` field** (it exists for the self-contained demo fixture only; a real bundle should
never carry one, since the identity already exists from §5.1). Resolution is then read-only by
username — the import fails closed if a name doesn't resolve, so a typo here is caught, not
silently ignored. Full contract: `fred`'s `docs/swift/rfc/PLATFORM-IMPORT-RFC.md` §10.

A real bundle lives in a git-ignored `config/<instance>-platform-import/` directory (e.g.
`config/fredlab-platform-import/manifest.json` + `.../users.json`) — real names and team
assignments, still no secrets, still not committed. Zip it the same way `make build-demo-bundle`
zips the demo fixture in `fred`, then upload:

```bash
cd config/fredlab-platform-import && zip -q -X ../fredlab-platform-import.zip manifest.json users.json && cd -
```

Upload `config/fredlab-platform-import.zip` via **Admin → Migration**, or:

```bash
curl -s -X POST https://<instance-studio-host>/control-plane/v1/import-export/import \
  -H "Authorization: Bearer $TOKEN" -F file=@config/fredlab-platform-import.zip
```

---

## 6. Steady-state loop — shipping new code to an existing instance

Pull the latest `~/fred` first, then **four commands**:

```bash
bin/fredlab-release.sh all                     # 1. Cloud Build the 4 app images from ~/fred HEAD,
                                               #    then rewrite the image tags in values-fredlab.yaml
git commit -am "release <tag>" && git push     # 2. record the new tags in git (NOT a deploy yet)
bin/fredlab-argocd-sync.sh                      # 3. THE DEPLOY: apply git to the cluster
NAMESPACE=<instance> bin/fredlab-status.sh      # 4. verify: new tag, healthy
```

What each step really does:

- **`fredlab-release.sh all`** — derives the tag `YYYYMMDD-swift-<shortsha>` from `~/fred`
  `HEAD`, submits a Cloud Build for each of the four app-layer images (control-plane-backend,
  fred-frontend, fred-agents, knowledge-flow-backend — the worker reuses the backend image),
  and rewrites the `# release-tag:` lines in `gcp-c1/argocd/fred-apps/values-fredlab.yaml`. It does
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

> **ghcr.io alternative (`C5`, proposed):** skip the Cloud Build round entirely and point
> `values-fredlab.yaml` at `ghcr.io/thalesgroup/fred-agent/<image>:vX.Y.Z` instead — see §3.3.
> This has in practice been the only path used on fredlab since `v2.1.1`.

> **Don't forget the migration step.** Neither loop above runs alembic. If the new
> `control-plane`/`knowledge-flow` tag added a schema revision, run §3.2's `migrate` command
> again at the new tag right after the sync, or the new code will 500 on the first request
> touching the new column/table — a `UndefinedColumnError`/`UndefinedTableError` that looks like
> a bug but is just a missed step (hit live on fredlab, 2026-07-21).

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

## See also

| Topic | Doc |
| --- | --- |
| Why the Foundation/Apps split, classification knobs (C1/C2/C3) | [`rfc/RFC-0001-gitops-deployment-pattern.md`](rfc/RFC-0001-gitops-deployment-pattern.md) |
| ArgoCD ops in depth (admin RBAC, per-app cutover, rollback) | [`../gcp-c1/argocd/README.md`](../gcp-c1/argocd/README.md) |
| Foundation chart reference + exhaustive step-by-step | [`../gcp-c1/helm/README.md`](../gcp-c1/helm/README.md) · [`../gcp-c1/helm/DEPLOYMENT-STEPS.md`](../gcp-c1/helm/DEPLOYMENT-STEPS.md) |
| Day-to-day conventions (image tagging, named instances, ghcr.io) | [`../gcp-c1/helm/OPERATING-CONVENTIONS.md`](../gcp-c1/helm/OPERATING-CONVENTIONS.md) |
| Auth / team-isolation validation (release gate) | `fred` monorepo's own `validation/README.md` |
