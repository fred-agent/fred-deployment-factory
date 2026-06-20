# Fredlab GKE Deployment Guide

Canonical deployment path for `fredlab-infra` on GKE Autopilot.

## 1. Prerequisites

Run from the repository root:

```bash
pwd
kubectl config current-context
kubectl get ns default
```

Expected:

- working directory is `~/fred-deployment-factory`
- current Kubernetes context points to `fredlab-playground-gke`
- namespace `default` exists

## 2. Prepare Private Values

Create one complete local secret file from the committed example:

```bash
cp helm/fredlab-infra/fredlab-secrets.values.example.yaml \
   helm/fredlab-infra/fredlab-secrets.values.yaml
```

Fill all required values in:

```text
helm/fredlab-infra/fredlab-secrets.values.yaml
```

Required values:

- `postgresql.admin.password`
- `postgresql.keycloak.password`
- `postgresql.openfga.password`
- `postgresql.temporal.password`
- `postgresql.fred.password`
- `keycloak.admin.password`
- `keycloak.clients.controlPlane.secret`
- `openfga.auth.apiToken`

Validate that the file is ignored by Git:

```bash
git status --short --ignored helm/fredlab-infra/fredlab-secrets.values.yaml
```

Expected:

```text
!! helm/fredlab-infra/fredlab-secrets.values.yaml
```

## 3. Install Or Upgrade Infrastructure

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

- core pods are `Running`
- `postgres-provision` is `Complete`
- services include `postgres`, `keycloak`, `openfga`, `temporal`, `temporal-ui`

Responsibility:

- `postgres-provision` creates PostgreSQL users, databases, and grants.
- It does not create application tables.

## 4. Confirm Fred Database

```bash
kubectl run pg-check-fred --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U admin -d postgres -c "\\l fred"
```

Expected: database `fred` exists.

## 5. Prepare Artifact Registry

Run once per project:

```bash
PROJECT_ID="$(gcloud config get-value project)"
REGION="europe-west1"
REPOSITORY="fred"

gcloud artifacts repositories create "${REPOSITORY}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Fred playground images" || true

gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

If the GKE pull identity does not already have access, grant:

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:<gke-pull-service-account>" \
  --role="roles/artifactregistry.reader"
```

## 6. Build And Push Control Plane Image

Run from the root of the Fred source repository:

```bash
PROJECT_ID="$(gcloud config get-value project)"
REGION="europe-west1"
REPOSITORY="fred"
IMAGE="control-plane-backend"
TAG="$(git rev-parse --short HEAD)"

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

Expected: `${TAG}` is listed.

Image contract:

- contains `alembic`, `alembic.ini`, and `alembic/versions`
- supports `alembic upgrade head`
- runs the FastAPI server on container port `8222`
- exposes `/healthz`

## 7. Run Control Plane Migrations

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
- logs show Alembic reached `head`

Responsibility:

- creates and updates Control Plane application tables in database `fred`
- does not create the database itself

## 8. Confirm Alembic State

```bash
kubectl run pg-check-alembic --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_FRED_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U fred -d fred -c "select * from alembic_version;"
```

Expected: at least one Alembic revision is present.

## 9. Start Control Plane Backend

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

## 10. Probe Control Plane Internally

```bash
kubectl run control-plane-curl --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://control-plane-backend:8080/healthz
```

Expected: HTTP `200` or the app-specific healthy response.

## Troubleshooting

### Helm Command Run From The Wrong Directory

If Helm reports `path "./helm/fredlab-infra" not found`, return to the repository root:

```bash
cd ~/fred-deployment-factory
```

### PostgreSQL StatefulSet Immutable Field

If Helm fails with:

```text
StatefulSet.apps "postgres" is invalid: spec: Forbidden: updates to statefulset spec ...
```

recreate only the StatefulSet controller and keep the existing pod/PVC:

```bash
kubectl delete statefulset postgres --cascade=orphan

helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

Use only for immutable StatefulSet spec drift.

### Disable Control Plane Without Deleting Data

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml \
  --set controlPlane.enabled=false \
  --set controlPlane.migration.enabled=false
```
