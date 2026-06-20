# Fredlab Infra
Helm chart for the Fredlab playground infrastructure on GKE Autopilot.

## Scope
Deployed components:

| Component | Visibility | Internal DNS | Public host |
| --- | --- | --- | --- |
| PostgreSQL | Private | `postgres:5432` | none |
| Keycloak | Public | `keycloak:8080` | `keycloak.playground.fredlab.dev` |
| OpenFGA | Private | `openfga:8080`, `openfga:8081` | none |
| Temporal | Private | `temporal:7233` | none |
| Temporal UI | Protected public admin UI | `temporal-ui:8080` | `temporal.playground.fredlab.dev` |

All services use `ClusterIP`. Public routing is handled only by the GKE `gce` Ingress named `fredlab-infra-ingress`.

## Naming Rules
This chart intentionally avoids Helm release-name prefixes for service DNS. Component names are fixed through `fullnameOverride` values:

- Private services use short names: `postgres`, `openfga`, `temporal`
- Public services use short service names plus DNS hosts under `*.playground.fredlab.dev`
- Future backends should use `[app-name]-backend`
- Future frontends should use `[app-name]-frontend`
- Future admin UUs should use `[component]-ui`

## Security
The chart is designed for GKE Autopilot:
- No privileged containers
- No node-level `sysctl`
- F privileged `chown` init jobs
- Explicit CPU and memory requests
- Secrets are supplied through a local values file ignored by Git

Admin UUs exposed through Ingress must use Cloud Armor IP allowlisting. Temporal UI is wired through a `BackendConfig` that references the policy: `fredlab-admin-ui-allowlist`.

Maintain the intended operator CIDR placeholders in `values.yaml` (the real IPs live in `fredlab-secrets.values.yaml` under the same structure):

```yaml
adminAccess:
 allowedOperatorCidrs:
    dimitri: ""
    sebastien: ""
    simon: ""
```

## Secrets
The chart is safe to commit. Real passwords and sensitive configuration live only in:
```text
helm/fredlab-infra/fredlab-secrets.values.yaml
```JThis file is ignored by Git. Create it from the template:
``bash
cp helm/fredlab-infra/fredlab-secrets.values.example.yaml \
   helm/fredlab-infra/fredlab-secrets.values.yaml
```
Required secret values:
- `postgresql.admin.password`
- `postgresql.keycloak.password`
- `postgresql.openfga.password
- `postgresql.temporal.password`
- `keycloak.admin.password`
- `openfga.auth.apiToken`

## Deploy
Find the GCP global address resource name for the reserved static IP:
``bash
gcloud compute addresses list --global
```Install or upgrade dynamically:
``bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set ingress.staticIpName=fredlab-playground-ip
```Check cluster convergence:
fbash
./bin/check-fredlab.sh
```
