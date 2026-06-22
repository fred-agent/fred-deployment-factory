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
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get realms/app --fields realm,enabled
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r app -q clientId=app \
  --fields clientId,enabled,publicClient,redirectUris,webOrigins
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r app -q clientId=control-plane \
  --fields clientId,enabled,publicClient,serviceAccountsEnabled
```

Expected:

- core pods are `Running`
- `postgres-provision` is `Complete`
- services include `postgres`, `keycloak`, `openfga`, `temporal`, `temporal-ui`
- Keycloak realm `app` exists
- Keycloak clients `app` and `control-plane` exist

Responsibility:

- `postgres-provision` creates PostgreSQL users, databases, and grants.
- `keycloak-provision` creates/updates the Fred realm and clients.
- This step does not create application tables.

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

## 6. Prepare GCS For Future Knowledge Flow

Fredlab on GKE should use Google Cloud Storage for future Knowledge Flow and agentic file storage, not an in-cluster MinIO replacement.

Run once per project:

```bash
bin/fredlab-gcp-gcs-prereqs.sh
```

Default resources created:

- bucket: `gs://<project-id>-knowledge-flow`
- Google service account: `fredlab-knowledge-flow-gcs@<project-id>.iam.gserviceaccount.com`
- bucket role: `roles/storage.objectUser`
- Workload Identity bindings for future Kubernetes service accounts `knowledge-flow-backend` and `knowledge-flow-worker`

This step prepares GCP only. It does not create a Kubernetes Deployment, does not create a MinIO-compatible HMAC key, and does not store any cloud credential in Git or Helm secrets.

When Swift adds native GCS support, the future Knowledge Flow chart must:

- create/use a Kubernetes service account annotated with `iam.gke.io/gcp-service-account`
- set the storage backend to `gcs`
- set the bucket name returned by the script
- use Application Default Credentials through Workload Identity

Useful overrides:

```bash
BUCKET=fredlab-playground-knowledge-flow \
KSA_NAMES="knowledge-flow-backend knowledge-flow-worker" \
bin/fredlab-gcp-gcs-prereqs.sh
```

## 7. Build And Push Images

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
- runs as UID/GID `1000`, matching the chart `runAsUser`/`runAsGroup`
- uses `postgresql+asyncpg://...` for `DATABASE_URL`
- loads Fredlab runtime config from the `control-plane-config` ConfigMap through `CONFIG_FILE`
- runs the FastAPI server on container port `8222`
- exposes `/control-plane/v1/healthz`

## 8. Run Control Plane Migrations

`migrate` means "bring the Control Plane PostgreSQL schema to the version expected by this image". It runs a temporary Kubernetes Job executing `alembic upgrade head`. On a fresh database, this creates the initial tables; on an existing database, it applies pending schema changes.

The chart provides a Fredlab-specific runtime configuration through the `control-plane-config` ConfigMap. This intentionally replaces the image's bundled `configuration_prod.yaml`, which still contains local/example endpoints such as `localhost` and `app-keycloak`.

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

## 9. Confirm Alembic State

```bash
kubectl run pg-check-alembic --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_FRED_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U fred -d fred -c "select * from alembic_version_control_plane;"
```

Expected: at least one Alembic revision is present.

## 10. Start Control Plane Backend

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

## 11. Probe Control Plane Internally

```bash
kubectl run control-plane-curl --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://control-plane-backend:8080/control-plane/v1/healthz

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/control-plane-curl --timeout=60s || true
kubectl logs control-plane-curl
kubectl delete pod control-plane-curl --ignore-not-found
```

Expected: HTTP `200` or the app-specific healthy response.

## 12. Start Fred Frontend

The frontend image is already built by `bin/fredlab-build frontend 0.2`. Starting it only updates the Helm release. The script keeps already-enabled components and also loads new chart defaults, so adding frontend does not disable Control Plane.

At this stage only Control Plane is deployed. The frontend chart therefore points the not-yet-deployed `fred-agents` and `knowledge-flow-backend` upstreams to `control-plane-backend` temporarily, because Nginx fails at startup when an upstream DNS name does not exist. Switch those values to the real services when those components are deployed.

```bash
bin/fredlab-frontend-deploy.sh start 0.2
```

Validate:

```bash
kubectl rollout status deploy/fred-frontend
kubectl get pod -l app.kubernetes.io/component=fred-frontend
kubectl get svc fred-frontend
kubectl get ingress fredlab-infra-ingress
kubectl get managedcertificate fredlab-infra-cert
```

Expected:

- rollout completes
- pod is `Running`
- service `fred-frontend` exists on port `8080`
- Ingress contains host `studio.playground.fredlab.dev`
- ManagedCertificate contains `keycloak.playground.fredlab.dev`, `temporal.playground.fredlab.dev`, and `studio.playground.fredlab.dev`

DNS must point `studio.playground.fredlab.dev` to the reserved IP `8.233.26.38`.
After adding a new domain, the Google managed certificate can temporarily return to a provisioning state before becoming `Active` again.

If the browser returns `DNS_PROBE_FINISHED_NXDOMAIN`, the DNS record does not exist yet. In Squarespace/Square DNS, create this explicit custom record:

```text
Type: A
Name: studio.playground
Data: 8.233.26.38
```

If the DNS zone is managed by Cloud DNS instead, create the same A record there:

```bash
gcloud dns managed-zones list

DNS_ZONE="<zone-name-from-the-list>"

gcloud dns record-sets create studio.playground.fredlab.dev. \
  --zone="${DNS_ZONE}" \
  --type=A \
  --ttl=300 \
  --rrdatas=8.233.26.38

dig +short studio.playground.fredlab.dev
```

Expected: `dig` eventually returns `8.233.26.38`. If the DNS zone is not managed in this GCP project, create the same A record at the external DNS provider instead.

If the frontend pod enters `CrashLoopBackOff`, inspect logs first:

```bash
kubectl logs -l app.kubernetes.io/component=fred-frontend --tail=80
```

If logs contain `host not found in upstream`, the frontend is pointing to a Kubernetes service that has not been deployed yet.

## 13. Probe Frontend And Auth Bootstrap

First check that Nginx serves the static app:

```bash
kubectl run frontend-config --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://fred-frontend:8080/config.json

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/frontend-config --timeout=60s || true
kubectl logs frontend-config
kubectl delete pod frontend-config --ignore-not-found
```

Then check that frontend proxying reaches Control Plane and returns the Keycloak-facing public config:

```bash
kubectl run frontend-auth-config --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://fred-frontend:8080/control-plane/v1/frontend/config

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/frontend-auth-config --timeout=60s || true
kubectl logs frontend-auth-config
kubectl delete pod frontend-auth-config --ignore-not-found
```

Expected: HTTP `200`, with frontend auth fields referencing realm `app`, client `app`, and issuer `https://keycloak.playground.fredlab.dev/realms/app`.

At this point the browser test is:

```text
https://studio.playground.fredlab.dev
```

If the page redirects to Keycloak, the public route, frontend proxy, Control Plane frontend config, and Keycloak issuer are connected. Team/group provisioning is validated after login, because it depends on the actual Fred user/team data model and Keycloak realm content.

Keycloak state to verify next:

- service is running: `keycloak:8080`
- realm exists: `app`
- public frontend client exists: `app`
- confidential machine client exists: `control-plane`
- the `control-plane` client secret matches `keycloak.clients.controlPlane.secret`
- operator users and Fred teams/groups are provisioned according to the Fred Swift identity model

The chart bootstraps realm/client state through the `keycloak-provision` Helm hook. It does not yet invent operator users or Fred teams. Those must be created from the agreed Swift identity model.

Avoid `kcadm.sh get clients -r app -q clientId=control-plane` without `--fields`: the full Keycloak client representation includes the confidential client secret.

If `/control-plane/v1/frontend/config` returns HTTP `500`, inspect Control Plane logs:

```bash
kubectl logs deploy/control-plane-backend --tail=200
```

If logs mention `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET is not set`, the control-plane pod is missing the exact env var named by `security.m2m.secret_env_var`.

## 14. Provision Initial Keycloak Users And Teams

Keycloak identity provisioning is driven by a local JSON file, not by names hard-coded in a script.

Create the local file:

```bash
cp config/fredlab-keycloak-identity.example.json \
   config/fredlab-keycloak-identity.json
```

Edit:

```text
config/fredlab-keycloak-identity.json
```

Suggested first Fredlab teams:

- `Innovation`
- `Engineering`
- `Enterprise`

The file can also define initial operators and team members. Use app role `admin` for global Fredlab administrators, and `viewer` or `editor` for normal team users.

Apply it:

```bash
bin/fredlab-keycloak-identity.sh
```

Validate:

```bash
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get groups -r app --fields name

kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get users -r app --fields username,email,enabled
```

Responsibility:

- creates/updates Keycloak users
- creates Keycloak groups for teams
- assigns users to groups
- creates/assigns app client roles such as `admin`, `editor`, `viewer`
- configures the `groups` OIDC claim on the public app client

Important boundary: Keycloak groups prepare identity and login claims. Team ownership and application permissions inside Fred/OpenFGA remain a separate application-domain provisioning step until Swift exposes the official team bootstrap path.

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
