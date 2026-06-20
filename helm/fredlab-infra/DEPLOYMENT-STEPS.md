# Fredlab Deployment Steps

Run each step separately. Do not continue until the validation command succeeds.

## 0. Confirm Context

```bash
kubectl config current-context
kubectl get ns default
```

Expected: the context is the GKE Autopilot cluster and namespace `default` exists.

## 0.5. Confirm Local Secrets

Make sure the local, non-git-tracked file contains the Control Plane secrets:

```bash
grep -n "fred:" helm/fredlab-infra/fredlab-secrets.values.yaml
grep -n "controlPlane:" helm/fredlab-infra/fredlab-secrets.values.yaml
```

Expected: both keys exist.

Minimum required shape:

```yaml
postgresql:
  fred:
    password: "<fred-db-password>"

keycloak:
  clients:
    controlPlane:
      secret: "<keycloak-control-plane-client-secret>"
```

## 1. Deploy Or Upgrade The Foundation

This creates or updates infrastructure objects and runs `postgres-provision`.

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

Validate:

```bash
kubectl get pods,svc,ingress,backendconfig,managedcertificate
kubectl get job postgres-provision
```

Expected:

- `postgres`, `keycloak`, `openfga`, `temporal`, `temporal-ui` services exist.
- `postgres-provision` is `Complete`.

Responsibility:

- Creates PostgreSQL roles and databases.
- Does not create application tables.

## 2. Confirm The Fred Database Exists

```bash
kubectl run pg-check-fred --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U admin -d postgres -c "\\l fred"
```

Expected: database `fred` exists.

Responsibility:

- Database `fred` is created by `postgres-provision`.
- Tables are not created here.

## 3. Build And Push Control Plane Image

Run this from the Fred source repository, not from this deployment repo.

```bash
PROJECT_ID="$(gcloud config get-value project)"
REGION="europe-west1"
REPOSITORY="fred"
IMAGE="control-plane-backend"
TAG="$(git rev-parse --short HEAD)"

gcloud artifacts repositories create "${REPOSITORY}" \
  --repository-format=docker \
  --location="${REGION}" || true

gcloud auth configure-docker "${REGION}-docker.pkg.dev"

docker build \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}" \
  -f apps/control-plane-backend/dockerfiles/Dockerfile-prod \
  .

docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}"
```

Validate:

```bash
gcloud artifacts docker images list \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --include-tags
```

Expected: the pushed `${TAG}` is listed.

Image must contain:

- the backend server
- `alembic`
- `alembic.ini`
- `alembic/versions`
- a runnable command: `alembic upgrade head`
- the FastAPI server on port `8222`
- the health endpoint `/healthz`

## 4. Run Control Plane Migrations Only

This creates or upgrades Control Plane tables in database `fred`.

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.migration.enabled=true \
  --set controlPlane.enabled=false \
  --set controlPlane.image.repository="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --set controlPlane.image.tag="${TAG}"
```

Validate:

```bash
kubectl get job -l app.kubernetes.io/component=control-plane-migration
kubectl logs job/control-plane-migration
```

Expected:

- migration job is `Complete`
- logs show Alembic applied or confirmed the latest revision

Responsibility:

- Creates and updates Control Plane application tables.
- Does not create PostgreSQL database `fred`.

## 5. Confirm Alembic State

```bash
kubectl run pg-check-alembic --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_FRED_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U fred -d fred -c "select * from alembic_version;"
```

Expected: at least one Alembic revision is present.

## 6. Start Control Plane Backend

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.migration.enabled=false \
  --set controlPlane.enabled=true \
  --set controlPlane.image.repository="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --set controlPlane.image.tag="${TAG}"
```

Validate:

```bash
kubectl rollout status deploy/control-plane-backend
kubectl get pod -l app.kubernetes.io/component=control-plane-backend
kubectl get svc control-plane-backend
```

Expected:

- rollout completes
- pod is `Running`
- service `control-plane-backend` exists on port `8080`

## 7. Probe The Backend Internally

```bash
kubectl run control-plane-curl --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://control-plane-backend:8080/healthz
```

Expected: HTTP `200` or the app-specific healthy response.

If the app uses another health path, deploy with:

```bash
--set controlPlane.health.path=/actual/health/path
```

## Rollback

Disable the backend but keep data:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.enabled=false \
  --set controlPlane.migration.enabled=false
```

This does not delete PostgreSQL data.
