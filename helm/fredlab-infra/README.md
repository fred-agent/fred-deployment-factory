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

All services use `ClusterIP`. Public routing is handled only by the GKE `gce`
Ingress named `fredlab-infra-ingress`.

## Naming Rules

This chart intentionally avoids Helm release-name prefixes for service DNS.
Component names are fixed through `fullnameOverride` values:

- private services use short names: `postgres`, `openfga`, `temporal`
- public services use short service names plus DNS hosts under `*.playground.fredlab.dev`
- future backends should use `[app-name]-backend`
- future frontends should use `[app-name]-frontend`
- future admin UIs should use `[component]-ui`

## Security

The chart is designed for GKE Autopilot:

- no privileged containers
- no node-level `sysctl`
- no privileged `chown` init jobs
- explicit CPU and memory requests
- secrets are supplied through a local values file ignored by Git

Admin UIs exposed through Ingress must use Cloud Armor IP allowlisting.
Temporal UI is wired through a `BackendConfig` that references:

```text
fredlab-admin-ui-allowlist
```

Maintain the intended operator CIDR placeholders in `values.yaml`:

```yaml
adminAccess:
  allowedOperatorCidrs:
    dimitri: ""
    sebastien: ""
    simon: ""
```

Create or update the Cloud Armor policy in GCP before exposing admin UIs:

```bash
gcloud compute security-policies create fredlab-admin-ui-allowlist \
  --description="Allowlisted access to Fredlab admin UIs"

gcloud compute security-policies rules create 1000 \
  --security-policy=fredlab-admin-ui-allowlist \
  --src-ip-ranges=<dimitri-cidr>,<sebastien-cidr>,<simon-cidr> \
  --action=allow

gcloud compute security-policies rules update 2147483647 \
  --security-policy=fredlab-admin-ui-allowlist \
  --action=deny-403
```

## Secrets

The chart is safe to commit. Real passwords live only in:

```text
helm/fredlab-infra/fredlab-secrets.values.yaml
```

This file is ignored by Git. Create it from:

```bash
cp helm/fredlab-infra/fredlab-secrets.values.example.yaml \
   helm/fredlab-infra/fredlab-secrets.values.yaml
```

Required secret values:

- `postgresql.admin.password`
- `postgresql.keycloak.password`
- `postgresql.openfga.password`
- `postgresql.temporal.password`
- `keycloak.admin.password`
- `openfga.auth.apiToken`

## Deploy

Find the GCP global address resource name for the reserved IP `8.233.26.38`:

```bash
gcloud compute addresses list --global
```

Render:

```bash
helm template fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set ingress.staticIpName=<gcp-global-address-resource-name>
```

Install or upgrade:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set ingress.staticIpName=<gcp-global-address-resource-name>
```

Check:

```bash
kubectl get pods,svc,ingress,backendconfig
```
