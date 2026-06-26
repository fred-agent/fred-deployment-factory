# ArgoCD GitOps — fred application layer

ArgoCD (namespace `argocd`) owns the **stateless app workloads** in namespace `default`.
Infrastructure stays imperative and frozen (see `helm/fredlab-infra/DEPLOYMENT-STEPS.md`).

**Rule:** every cluster change below is a `fredlab-*.sh` script or a chart/values file —
never an ad-hoc `kubectl`/`helm` command. The only manual steps are external (DNS, auth)
and are called out as prerequisites.

## Boundary

| Owned by ArgoCD (`fred-apps` chart) | Owned by the imperative infra layer (`fredlab-infra`) |
| --- | --- |
| control-plane-backend (then: frontend, fred-agents, knowledge-flow) | postgres, keycloak, openfga, opensearch, temporal |
| their ConfigMaps | `fredlab-infra-secrets`, the infra Ingress, ManagedCertificates, provision Jobs |

Apps reference the infra-owned Secret + Services **by name**. ArgoCD never renders a
Secret, the infra Ingress, or its certs.

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

```bash
bin/fredlab-deploy.sh control-plane disable -fast    # remove from the imperative release (brief downtime)
# then SYNC fred-apps in ArgoCD -> ArgoCD becomes sole owner
```

Done for **control-plane**. frontend / fred-agents / knowledge-flow follow the same pattern
(copy their templates into `fred-apps/`, add their blocks to the values files, disable on the
imperative release, sync). **frontend** also needs the studio Ingress + cert kept in the infra
layer, decoupled from the app toggle, before it moves.

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
