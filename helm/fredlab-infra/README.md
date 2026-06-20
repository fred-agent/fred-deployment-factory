# Fredlab Infra

Helm chart for the Fredlab playground on GKE Autopilot.

## Scope

| Component | Visibility | Internal DNS | Public host |
| --- | --- | --- | --- |
| PostgreSQL | Private | `postgres:5432` | none |
| Keycloak | Public | `keycloak:8080` | `keycloak.playground.fredlab.dev` |
| OpenFGA | Private | `openfga:8080`, `openfga:8081` | none |
| Temporal | Private | `temporal:7233` | none |
| Temporal UI | Protected admin UI | `temporal-ui:8080` | `temporal.playground.fredlab.dev` |
| Control Plane backend | Private | `control-plane-backend:8080` | none |

All services use `ClusterIP`. Public routing is handled by the GKE `gce` Ingress named `fredlab-infra-ingress`.

## Naming Rules

This chart avoids Helm release-name prefixes for service DNS. Component names are fixed through `fullnameOverride` values:

- private services use short names: `postgres`, `openfga`, `temporal`
- app backends use `[app-name]-backend`
- app frontends use `[app-name]-frontend`
- admin UIs use `[component]-ui`

## Security

The chart is designed for GKE Autopilot:

- no privileged containers
- no node-level `sysctl`
- no privileged `chown` init jobs
- explicit CPU and memory requests
- real secrets are supplied through `fredlab-secrets.values.yaml`, which is ignored by Git

Admin UIs exposed through Ingress must use Cloud Armor IP allowlisting. Temporal UI is wired through the policy:

```text
fredlab-admin-ui-allowlist
```

## Secrets

Create the local secret values file from the committed template:

```bash
cp helm/fredlab-infra/fredlab-secrets.values.example.yaml \
   helm/fredlab-infra/fredlab-secrets.values.yaml
```

Required values include:

- `postgresql.admin.password`
- `postgresql.keycloak.password`
- `postgresql.openfga.password`
- `postgresql.temporal.password`
- `postgresql.fred.password`
- `keycloak.admin.password`
- `keycloak.clients.controlPlane.secret`
- `openfga.auth.apiToken`

## Control Plane Image

The Control Plane backend is present in the chart but disabled by default until an image is available.

Control Plane deployment is intentionally split into two short actions:

1. run `controlPlane.migration.enabled=true` to execute `alembic upgrade head`
2. run `controlPlane.enabled=true` to start the backend

This makes it clear that:

- `postgres-provision` creates the `fred` database and user
- the Control Plane migration job creates the application tables
- the backend deployment only starts the HTTP service

Build and push an image from the Fred source repository in Cloud Shell. Adapt the Dockerfile path to the real Fred repo layout:

```bash
PROJECT_ID="$(gcloud config get-value project)"
REGION="europe-west1"
REPOSITORY="fred"
IMAGE="control-plane-backend"
TAG="$(git rev-parse --short HEAD)"

gcloud artifacts repositories create "${REPOSITORY}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Fred playground images" || true

gcloud auth configure-docker "${REGION}-docker.pkg.dev"

docker build \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}" \
  -f apps/control-plane-backend/dockerfiles/Dockerfile-prod \
  .

docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}"
```

Run migrations once the image exists:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.migration.enabled=true \
  --set controlPlane.enabled=false \
  --set controlPlane.image.repository="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --set controlPlane.image.tag="${TAG}"
```

Then start the backend:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.migration.enabled=false \
  --set controlPlane.enabled=true \
  --set controlPlane.image.repository="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --set controlPlane.image.tag="${TAG}"
```

If the application exposes health on a different path, override it:

```bash
--set controlPlane.health.path=/actuator/health
```

If the application needs additional environment variables, use:

```yaml
controlPlane:
  extraEnv:
    SOME_SETTING: value
```

## Deploy

Install or upgrade the foundation without Control Plane:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

Check:

```bash
kubectl get pods,svc,ingress,backendconfig,managedcertificate
```
