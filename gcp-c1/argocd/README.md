# ArgoCD GitOps — fred application layer

ArgoCD (namespace `argocd`) owns the **stateless app workloads** in namespace `default`.
Infrastructure stays imperative and frozen (see `gcp-c1/helm/DEPLOYMENT-STEPS.md`).

**Rule:** every cluster change below is a `fredlab-*.sh` script or a chart/values file —
never an ad-hoc `kubectl`/`helm` command. The only manual steps are external (DNS, auth)
and are called out as prerequisites.

## Boundary

| Owned by ArgoCD (`fred-apps` chart) | Owned by the imperative infra layer (`fredlab-infra`) |
| --- | --- |
| control-plane-backend, fred-frontend, fred-agents, knowledge-flow (backend + worker) | postgres, keycloak, openfga, opensearch, temporal |
| their ConfigMaps + the fred-agents / knowledge-flow ServiceAccounts | `fredlab-infra-secrets`, the infra Ingress, ManagedCertificates, BackendConfigs, provision Jobs |

All four fred app workloads are cut over (since 2026-06-26). Apps reference the infra-owned
Secret + Services **by name**. ArgoCD never renders a Secret, the infra Ingress, or its certs.

> **Frontend edge stays in infra:** the studio Ingress host-rule, `fredlab-studio-cert`
> ManagedCertificate and the frontend BackendConfig live in `fredlab-infra`, gated on
> `fredFrontend.ingressEnabled` (default true) — decoupled from `fredFrontend.enabled` so the
> workload can be ArgoCD-owned while infra keeps the public studio URL + cert. The Ingress
> routes to the `fred-frontend` Service by name regardless of who creates it.

> **knowledge-flow migrations** are NOT in the GitOps slice — like control-plane, the live DB
> is at head and the alembic job stays imperative (`bin/fredlab-deploy.sh knowledge-flow migrate`).

> **Frozen-infra contract:** a new secret key, a new Keycloak client, or a new database is
> an *infra* change (touch `gcp-c1/helm`), not an app change.

## Prerequisites (manual / external — the only non-script steps)

- `kubectl`, `helm`, `gcloud` authenticated to the cluster:
  `gcloud container clusters get-credentials fredlab-playground-gke --region europe-west9 --project fredlab-playground`
- A DNS **A record** `argocd.playground.fredlab.dev` → the IP from step 1 below (managed in Square, outside Helm).

## One-time setup (run in order)

```bash
bin/fredlab-argocd-ip.sh                 # 1. reserve the static IP -> create the DNS A record
bin/fredlab-argocd-keycloak-client.sh    # 2. confidential `argocd` OIDC client in realm app
bin/fredlab-argocd-install.sh            # 3. install ArgoCD + OIDC + RBAC (config: gcp-c1/argocd/argocd-values.yaml)
bin/fredlab-argocd-expose.sh             # 4. Ingress + ManagedCertificate (gcp-c1/argocd/expose/)
bin/fredlab-argocd-app.sh                # 5. register the fred-apps Application (manual sync)
```

After step 4, wait for the cert: `bin/fredlab-status.sh` shows `argocd/fredlab-argocd-cert`
go `Active` (~15–60 min, needs the DNS record). Then log in at
`https://argocd.playground.fredlab.dev` via **Keycloak**.

## Admin access

Admins are **named people by email** in `gcp-c1/argocd/argocd-values.yaml` (`rbac.policy.csv`) — not
a group (the `fredlab` group has non-admins). Find emails with `bin/fredlab-keycloak-users.sh`,
add `g, <email>, role:admin` lines, then re-run `bin/fredlab-argocd-install.sh`. Everyone else
is read-only.

## Deploy / update an app — the steady-state loop

> Full operator walkthrough (auth, build prereqs, validation gate): [`../docs/DEPLOY-CLOUD.md`](../docs/DEPLOY-CLOUD.md). The loop below is the ArgoCD-focused summary.

Three commands. **Sync is manual by design** (auto-sync is off — no `automated:` block on the
`fred-apps` Application): `git push` records the new tags and shows **OutOfSync**, then
`bin/fredlab-argocd-sync.sh` is what actually deploys.

```bash
bin/fredlab-release.sh all               # 1. build all four app images from ~/fred HEAD + bump tags
git commit -am "release <tag>" && git push   # 2. push -> ArgoCD sees the new tags
bin/fredlab-argocd-sync.sh               # 3. trigger the sync (UI -> fred-apps -> SYNC also works)
bin/fredlab-status.sh                    # 4. verify: new tag, healthy
```

`bin/fredlab-release.sh` takes `all` or a single component (`control-plane`, `frontend`,
`fred-agents`, `knowledge-flow`); pass `<component> [tag]` to build/bump just one, or a bare
`[tag]` to reuse an already-built image. The tags live in `gcp-c1/argocd/fred-apps/values-fredlab.yaml`
(marked `# release-tag: <image>`); the script rewrites them. `bin/fredlab-argocd-sync.sh` drives
the Application via `kubectl` (no `argocd` CLI needed) and warns if HEAD isn't pushed.

> **Small-cluster rollout note:** the fred-apps Deployments pin `maxSurge: 0` /
> `maxUnavailable: 1` so a rollout replaces each pod **in place** rather than needing a spare
> node for a surge pod. Without it, all four apps surging at once can exhaust node memory — and
> if node auto-provisioning hits a GCE quota, new pods wedge in `Pending` while old pods keep
> serving. Trade-off: a few seconds of per-app unavailability during a deploy. The same block is
> mirrored in `gcp-c1/helm` so a fresh-cluster bootstrap behaves identically.

## First-time cutover per app (one-time, hands it off the imperative release)

**All four fred apps are cut over** (control-plane, fred-agents, knowledge-flow, fred-frontend).
The procedure used for each, for reference / future apps:

```bash
# 1. copy the app's templates from gcp-c1/helm/templates into gcp-c1/argocd/fred-apps/templates
#    (they share the fredlab-infra.* helpers — usually a verbatim copy), add the value block to
#    gcp-c1/argocd/fred-apps/values.yaml (enabled:false) and the enable+image pin to values-fredlab.yaml.
# 2. validate: helm template fred-apps gcp-c1/argocd/fred-apps -f values.yaml -f values-fredlab.yaml
#    and diff the rendered configuration.yaml against the live ConfigMap (must be identical).
git commit && git push
bin/fredlab-deploy.sh <app> disable -fast     # 3. remove the workload from the imperative release (brief blip)
# 4. SYNC fred-apps in ArgoCD (UI, or: kubectl -n argocd patch app fred-apps --type merge \
#    -p '{"operation":{"sync":{"revision":"<sha>"}}}') -> ArgoCD becomes sole owner
bin/fredlab-status.sh                          # 5. verify: ownership instance=fred-apps, healthy
```

Notes from the cutover:
- **frontend** needed the studio Ingress host-rule + `fredlab-studio-cert` + BackendConfig
  decoupled from `fredFrontend.enabled` first (now gated on `fredFrontend.ingressEnabled`,
  default true) so they stay in `fredlab-infra` while the workload moves. Verified the edge
  resources render byte-identical with the workload disabled — no cert churn.
- **knowledge-flow** moved backend + worker together; the migration Job is intentionally left
  out of the GitOps slice (live DB at head).
- **fred-agents / knowledge-flow** ServiceAccounts (Workload Identity) are recreated by the
  fred-apps chart; the GCP-side IAM bindings on the GSA are unaffected by the cutover.

## Rollback

`argocd app history fred-apps` then `argocd app rollback fred-apps <rev>` — or revert the tag
commit in git and re-sync.

## Files

| Path | What |
| --- | --- |
| `gcp-c1/argocd/fred-apps/` | the app chart (templates copied from `fredlab-infra`) |
| `gcp-c1/argocd/fred-apps/values-fredlab.yaml` | per-app enable + pinned image tags (bumped by `fredlab-release.sh`) |
| `gcp-c1/argocd/applications/fred-apps.yaml` | the ArgoCD Application |
| `gcp-c1/argocd/argocd-values.yaml` | ArgoCD config: `server.insecure`, url, OIDC, RBAC |
| `gcp-c1/argocd/expose/` | ArgoCD's Ingress + ManagedCertificate |
| `bin/fredlab-release.sh` | build + bump tags: `all` or one component |
| `bin/fredlab-argocd-sync.sh` | trigger the sync via `kubectl` (no `argocd` CLI) |
| `bin/fredlab-argocd-*.sh` | one-time setup (ip, keycloak-client, install, expose, app) |
