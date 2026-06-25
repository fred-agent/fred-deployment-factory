# ArgoCD / GitOps for the fred application layer

ArgoCD (namespace `argocd`, installed by `bin/fredlab-argocd-install.sh`) owns the
**stateless app workloads** in `default`. Infrastructure stays imperative and frozen.

## Boundary (what ArgoCD does and does NOT touch)

| Owned by ArgoCD (`fred-apps` chart) | Owned by the imperative infra layer (`fredlab-infra`) |
| --- | --- |
| control-plane-backend (+ later: frontend, fred-agents, knowledge-flow) | postgres, keycloak, openfga, opensearch, temporal (StatefulSets/Services) |
| their ConfigMaps | `fredlab-infra-secrets` Secret, Ingress, ManagedCertificates, provision Jobs |

Apps reference the infra-owned Secret and Services **by name**. ArgoCD never renders a
Secret, an Ingress, or a certificate — so there is no data-loss or cert-churn risk.

> Frozen-infra contract: the moment an app needs a **new** secret key, a **new** Keycloak
> client, or a **new** database, that is an *infra* change (touch `helm/fredlab-infra`),
> not an app change.

## Layout

```
argocd/
  fred-apps/                 # the dedicated app chart (templates copied from fredlab-infra)
    values.yaml              # defaults; apps disabled
    values-fredlab.yaml      # env overlay: enables apps + pins image repo/tag  <-- image bump edits this
  applications/
    fred-apps.yaml           # the ArgoCD Application (manual sync until green)
```

## First cutover (control-plane) — run in Cloud Shell

Context must be the fredlab cluster (`kubectl config current-context`).

1. **Validate the chart renders** (catches extraction mistakes before ArgoCD ever runs):
   ```bash
   helm template fred-apps argocd/fred-apps \
     -f argocd/fred-apps/values.yaml -f argocd/fred-apps/values-fredlab.yaml | head -60
   ```

2. **Pin the current live tag** so the cutover does not change the image. Read the
   IMAGE TAG for control-plane from `bin/fredlab-status.sh`, then set it in
   `argocd/fred-apps/values-fredlab.yaml` (`controlPlane.image.tag`). Commit + push to
   `main` (ArgoCD reads git, not your working tree).

3. **Hand control-plane off the imperative release** (infra and the other apps stay up):
   ```bash
   bin/fredlab-deploy.sh control-plane disable
   ```
   This removes the imperative control-plane Service/Deployment/ConfigMap so there is a
   single owner. (Brief control-plane downtime until step 5.)

4. **Create the Application** (still manual sync):
   ```bash
   kubectl apply -f argocd/applications/fred-apps.yaml
   ```

5. **Review the diff, then sync** — from the UI (`port-forward svc/argocd-server`) or CLI:
   ```bash
   argocd app diff fred-apps      # expect: creates control-plane Service/Deployment/ConfigMap
   argocd app sync fred-apps
   ```

6. **Confirm green:**
   ```bash
   argocd app get fred-apps
   bin/fredlab-status.sh          # control-plane Running at the pinned tag, /ready green
   ```

7. **Enable auto-sync** once happy (edit `applications/fred-apps.yaml`, add the
   `automated: {prune: true, selfHeal: true}` block shown in that file, re-apply).

## Rollback

```bash
argocd app history fred-apps
argocd app rollback fred-apps <REVISION>
```

## Next apps

frontend, fred-agents, knowledge-flow follow the same pattern: copy their templates into
`fred-apps/templates/`, add their blocks to `values.yaml` + `values-fredlab.yaml`,
`disable` them on the imperative release, sync. **frontend has one extra step** — its
Service is referenced by the infra Ingress, so the infra layer must keep owning the
studio Ingress rule + ManagedCertificate independently of the app toggle before moving it.
