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
bin/fredlab-gcp-build-prereqs.sh
```

The script enables the required APIs, creates Artifact Registry repository `fredlab-repo`, grants Cloud Build write access to Artifact Registry, grants Cloud Build logging rights, and grants Cloud Build read access to the staging bucket `gs://<project-id>_cloudbuild`.

If the GKE pull identity does not already have access, grant:

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:<gke-pull-service-account>" \
  --role="roles/artifactregistry.reader"
```

## 6. Build And Push Images

Use Cloud Build as the official build path. This avoids depending on Cloud Shell Docker push connectivity and keeps builds reproducible from source repositories. The build script enables Docker BuildKit, which is required by modern Dockerfile features such as `COPY --chmod`.

The short command is:

```bash
bin/fredlab-build <name> <tag>
```

Examples:

```bash
bin/fredlab-build control-plane-backend 0.2
bin/fredlab-build frontend 0.2
bin/fredlab-build fred-agents 0.2
bin/fredlab-build knowledge-flow-backend 0.2
```

Known images are declared in [config/fredlab-images.tsv](../../config/fredlab-images.tsv):

```bash
bin/fredlab-build list
```

The catalog is the contract. For each image it declares:

- short name used in the command
- Artifact Registry image name
- local source repository root, for example `~/fred`
- Dockerfile path from that source repository root
- Docker build context, usually `.`

If a build fails immediately with `Cannot find Dockerfile`, fix the catalog entry or clone the missing source repository at the declared path. If the tag is omitted, `bin/fredlab-build` uses the short Git commit SHA from the source repository declared in the catalog.

Validate:

```bash
PROJECT_ID="$(gcloud config get-value project)"
REGION="europe-west1"
REPOSITORY="fredlab-repo"
IMAGE="<image-name>"

gcloud artifacts docker images list \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}" \
  --include-tags
```

Expected: tag `0.2` is listed.

Do not use a local "push image" wrapper for this step. `gcloud builds submit --tag ... .` rebuilds the current directory; it does not upload an already-built local Docker image passed as an argument. If an image was built locally first, treat it only as a quick local sanity check and still run the Cloud Build command above for the deployable image.

Control Plane image contract:

- contains `alembic`, `alembic.ini`, and `alembic/versions`
- supports `alembic upgrade head`
- runs the FastAPI server on container port `8222`
- exposes `/healthz`

## 7. Run Control Plane Migrations

```bash
bin/fredlab-control-plane-deploy.sh migrate 0.2
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
bin/fredlab-control-plane-deploy.sh start 0.2
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
bin/fredlab-control-plane-deploy.sh disable
```
