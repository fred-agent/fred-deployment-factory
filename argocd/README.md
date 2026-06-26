# ArgoCD GitOps — fred application layer

ArgoCD (namespace `argocd`) owns the **stateless app workloads** in namespace `default`.
Infrastructure stays imperative and frozen (see `helm/fredlab-infra/DEPLOYMENT-STEPS.md`).

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
> an *infra* change (touch `helm/fredlab-infra`), not an app change.

## Prerequisites (manual / external — the only non-script steps)

- `kubectl`, `helm`, `gcloud` authenticated to the cluster:
  `gcloud container clusters get-credentials fredlab-playground-gke --region europe-west9 --project fredlab-playground`
- A DNS **A record** `argocd.playground.fredlab.dev` → the IP from step 1 below (managed in Square, outside Helm).

## One-time setup (run in order)

```bash
bin/fredlab-argocd-ip.sh                 # 1. reserve the static IP -> create the DNS A record
bin/fredlab-argocd-keycloak-client.sh    # 2. confidential `argocd` OIDC client in realm app
bin/fredlab-argocd-install.sh            # 3. install ArgoCD + OIDC + RBAC (config: argocd/argocd-values.yaml)
bin/fredlab-argocd-expose.sh             # 4. Ingress + ManagedCertificate (argocd/expose/)
bin/fredlab-argocd-app.sh                # 5. register the fred-apps Application (manual sync)
```

After step 4, wait for the cert: `bin/fredlab-status.sh` shows `argocd/fredlab-argocd-cert`
go `Active` (~15–60 min, needs the DNS record). Then log in at
`https://argocd.playground.fredlab.dev` via **Keycloak**.

## Admin access

Admins are **named people by email** in `argocd/argocd-values.yaml` (`rbac.policy.csv`) — not
a group (the `fredlab` group has non-admins). Find emails with `bin/fredlab-keycloak-users.sh`,
add `g, <email>, role:admin` lines, then re-run `bin/fredlab-argocd-install.sh`. Everyone else
is read-only.

## Deploy / update an app — the steady-state loop

```bash
bin/fredlab-release.sh control-plane     # 1. build image from ~/fred HEAD + bump tag in values-fredlab.yaml
git commit -am "release control-plane" && git push   # 2. push -> ArgoCD sees the new tag
# 3. ArgoCD UI -> fred-apps -> SYNC  (automatic once auto-sync is enabled)
bin/fredlab-status.sh                    # 4. verify: new tag, healthy
```

`git push` is the deploy. The image tag lives in `argocd/fred-apps/values-fredlab.yaml`
(marked `# release-tag: <image>`); `fredlab-release.sh` rewrites it.

## First-time cutover per app (one-time, hands it off the imperative release)

**All four fred apps are cut over** (control-plane, fred-agents, knowledge-flow, fred-frontend).
The procedure used for each, for reference / future apps:

```bash
# 1. copy the app's templates from helm/fredlab-infra/templates into argocd/fred-apps/templates
#    (they share the fredlab-infra.* helpers — usually a verbatim copy), add the value block to
#    argocd/fred-apps/values.yaml (enabled:false) and the enable+image pin to values-fredlab.yaml.
# 2. validate: helm template fred-apps argocd/fred-apps -f values.yaml -f values-fredlab.yaml
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

> **TODO — steady-state release loop:** `bin/fredlab-release.sh` only knows `control-plane`.
> Extend its component map (and the `# release-tag:` markers already in `values-fredlab.yaml`)
> to `frontend` / `fred-agents` / `knowledge-flow-backend` so the push-to-deploy loop above
> works for all four. Until then, bump the tag in `values-fredlab.yaml` by hand (or with
> `bin/fredlab-release.sh <app> <tag>` once extended) and sync.

## Rollback

`argocd app history fred-apps` then `argocd app rollback fred-apps <rev>` — or revert the tag
commit in git and re-sync.

## Files

| Path | What |
| --- | --- |
| `argocd/fred-apps/` | the app chart (templates copied from `fredlab-infra`) |
| `argocd/fred-apps/values-fredlab.yaml` | per-app enable + pinned image tags (bumped by `fredlab-release.sh`) |
| `argocd/applications/fred-apps.yaml` | the ArgoCD Application |
| `argocd/argocd-values.yaml` | ArgoCD config: `server.insecure`, url, OIDC, RBAC |
| `argocd/expose/` | ArgoCD's Ingress + ManagedCertificate |
| `bin/fredlab-argocd-*.sh`, `bin/fredlab-release.sh` | the scripts above |
