# Fredlab GKE Deployment Guide

Canonical deployment path for `fredlab-infra` on GKE Autopilot.

> **The verdict is a script, not this page.** This guide is the *path*; the *checklist*
> is executable. After each phase, run `bin/fredlab-status.sh` — a fully green run
> (workloads · MISSING check · GCS · app `/ready` · TLS certs · **Correctness**) means the
> deployment is complete **and** correct. `bin/fred-preflight.sh` covers identity
> prerequisites before the first deploy. **If a step here ever disagrees with the scripts,
> trust the scripts and fix the step.**
>
> This page does not restate what already lives elsewhere — it points:
> - image tags, deploy order, fast redeploys (`-fast`) → `OPERATING-CONVENTIONS.md`
> - required secrets → `fredlab-secrets.values.example.yaml`
> - GCS / Workload-Identity reference → `docs/swift/platform/DEPLOYMENT_GUIDE_GKE.md`

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
bin/fredlab-infra-deploy.sh
```

This is the safe foundation command. On an existing release it preserves currently enabled application components such as Control Plane and Studio. Avoid using a raw `helm upgrade --install ...` for routine upgrades after apps have been enabled, because chart defaults keep application components disabled.

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
- services include `postgres`, `keycloak`, `openfga`, `opensearch`, `temporal`, `temporal-ui`
- Keycloak realm `app` exists
- Keycloak clients `app` and `control-plane` exist

Responsibility:

- `postgres-provision` creates PostgreSQL users, databases, and grants.
- `keycloak-provision` creates/updates the Fred realm and clients.
- This step does not create application tables.
- `opensearch` is a private single-node search engine for future Knowledge Flow / hybrid search workloads.

For a deeper Control Plane service-client check:

```bash
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r app -q clientId=control-plane \
  --fields clientId,enabled,publicClient,serviceAccountsEnabled
```

Expected:

- `control-plane` is confidential: `publicClient=false`, `serviceAccountsEnabled=true`

For an OpenSearch check:

```bash
kubectl rollout status statefulset/opensearch
kubectl get pod -l app.kubernetes.io/component=opensearch

kubectl run opensearch-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS http://opensearch:9200/_cluster/health?pretty
```

Expected: the pod is `Running`, the service answers internally, and the JSON response has a cluster name `fredlab-opensearch`.

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

## 8. Fredlab Legal Content

The frontend needs the CGU version before it can call authenticated control-plane bootstrap routes. Fredlab therefore serves a Helm-managed `/config.json` with:

```json
{
  "properties": {
    "gcuVersion": "v1",
    "releaseBrand": "fredlab"
  }
}
```

The actual CGU/GDPR text is also mounted by Helm from Markdown files:

```text
helm/fredlab-infra/legal/gcu.fr.md
helm/fredlab-infra/legal/gcu.md
helm/fredlab-infra/legal/gdpr.fr.md
helm/fredlab-infra/legal/gdpr.md
```

This content is public, not secret. Update and review it in Git, then redeploy the frontend:

```bash
bin/fredlab-frontend-deploy.sh start 0.2
```

Validate from inside the cluster:

```bash
kubectl run frontend-config-check --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS http://fred-frontend:8080/config.json

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/frontend-config-check --timeout=60s || true
kubectl logs frontend-config-check
kubectl delete pod frontend-config-check --ignore-not-found

kubectl run frontend-gcu-check --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS http://fred-frontend:8080/gcu.fr.md

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/frontend-gcu-check --timeout=60s || true
kubectl logs frontend-gcu-check
kubectl delete pod frontend-gcu-check --ignore-not-found
```

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
kubectl get managedcertificate
```

Expected:

- rollout completes
- pod is `Running`
- service `fred-frontend` exists on port `8080`
- Ingress contains host `studio.playground.fredlab.dev`
- ManagedCertificates exist for the public hosts:
  - `fredlab-infra-cert` for `keycloak.playground.fredlab.dev`
  - `fredlab-temporal-cert` for `temporal.playground.fredlab.dev`
  - `fredlab-studio-cert` for `studio.playground.fredlab.dev`

DNS must point `studio.playground.fredlab.dev` to the reserved IP `8.233.26.38`.
After adding a new domain, its Google managed certificate can stay in provisioning before becoming `Active`.

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

If the page redirects to Keycloak, the public route, frontend proxy, Control Plane frontend config, and Keycloak issuer are connected. Login requires the user provisioning step below.

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

- `fredlab` for initial platform validation
- `Innovation`, `Engineering`, `Enterprise` for demo/customer onboarding

The file can also define initial operators and team members. Use app role `admin` for global Fredlab administrators, and `viewer` or `editor` for normal team users.

For first login tests, a user can include:

```json
"temporaryPassword": "change-me-with-a-real-temporary-password"
```

The script sets `temporaryPassword` only when the user is created. For an existing user, it does not reset the password unless the user entry also contains:

```json
"resetPassword": true
```

Use `resetPassword: true` only for an intentional admin reset, then remove it from the local file.

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

kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r app -q clientId=app \
  --fields clientId,defaultClientScopes
```

Responsibility:

- creates/updates Keycloak users
- creates Keycloak groups for teams
- assigns users to groups
- creates/assigns app client roles such as `admin`, `editor`, `viewer`
- configures the `groups` OIDC claim on the public app client

Important boundary: Keycloak groups prepare identity and login claims. Team ownership and application permissions inside Fred/OpenFGA remain a separate application-domain provisioning step until Swift exposes the official team bootstrap path.

Final browser validation:

```text
https://studio.playground.fredlab.dev
```

Expected: redirect to Keycloak, login with a provisioned user, then return to Studio.

## 15. Deploy Knowledge Flow With Native GCS

Knowledge Flow is the only component that uses object storage. On GKE it uses
native Google Cloud Storage through Workload Identity / ADC — no service-account
JSON key. It plugs into two storage layers: the content store (buckets
`<prefix>-documents` / `-objects` / `-files`) and the virtual filesystem (one
bucket). See `docs/swift/platform/DEPLOYMENT_GUIDE_GKE.md` in the Fred repo.

### 15.1 GCP prerequisites (buckets + IAM + Vertex)

```bash
bin/fredlab-gcp-gcs-prereqs.sh
```

This is idempotent and replayable. It creates the four buckets
(`<project>-content-documents/-objects/-files` and `<project>-knowledge-flow`),
grants the Google service account `roles/storage.objectAdmin` on them, enables
Vertex AI and grants `roles/aiplatform.user`, and prepares Workload Identity
bindings for the `knowledge-flow-backend` / `knowledge-flow-worker` Kubernetes
service accounts. Override `CONTENT_PREFIX` / `FS_BUCKET` / `REGION` if needed.

### 15.2 Set the Keycloak knowledge-flow client secret

Add to `helm/fredlab-infra/fredlab-secrets.values.yaml`:

```yaml
keycloak:
  clients:
    knowledgeFlow:
      secret: "<a-strong-secret>"
```

This is now required by the chart. Re-run the foundation deploy so the
`keycloak-provision` hook creates the confidential `knowledge-flow` client and
stores the secret:

```bash
bin/fredlab-infra-deploy.sh
```

Validate the client exists:

```bash
kubectl exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r app -q clientId=knowledge-flow \
  --fields clientId,enabled,publicClient,serviceAccountsEnabled
```

Expected: `publicClient=false`, `serviceAccountsEnabled=true`.

### 15.3 Build the image

```bash
bin/fredlab-build knowledge-flow-backend 0.2
```

### 15.4 Run Knowledge Flow migrations

KF stores its metadata/tag/resource tables in PostgreSQL (`fred` database) and
creates them with Alembic (version table `alembic_version_knowledge_flow`, separate
from control-plane's). Run this once before starting KF, or after any schema change:

```bash
bin/fredlab-knowledge-flow-deploy.sh migrate 0.2
```

Validate:

```bash
kubectl logs job/knowledge-flow-migration --tail=20   # Alembic reached head
```

Without this, KF starts but API calls that read those tables fail with
`relation "tag" does not exist` (HTTP 500), and the UI shows
"Service de connaissance non démarré".

### 15.5 Start Knowledge Flow

```bash
bin/fredlab-knowledge-flow-deploy.sh start 0.2
```

The script enables `knowledgeFlow`, sets the Artifact Registry image, annotates
the Kubernetes service account for Workload Identity
(`fredlab-knowledge-flow-gcs@<project>.iam.gserviceaccount.com`), and injects the
Vertex AI project. The chart points the frontend `knowledgeFlow` upstream at
`knowledge-flow-backend:8080` automatically.

Validate:

```bash
bin/fredlab-status.sh        # KF workload + all four GCS buckets must be green
```

### 15.5 Confirm health and GCS via Workload Identity

```bash
kubectl run kf-health --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  -- curl -sS -i http://knowledge-flow-backend:8080/knowledge-flow/v1/healthz

# Prove the pod can write to GCS purely via Workload Identity (no key):
kubectl exec deploy/knowledge-flow-backend -- \
  python -c "from google.cloud import storage; storage.Client().bucket('$(gcloud config get-value project)-knowledge-flow').blob('healthz').upload_from_string('ok')"
```

Expected: HTTP `200` from healthz; the GCS write succeeds with no credential
error. An ingestion smoke test (upload a document, confirm objects under
`gs://<project>-content-documents/<document_uid>/`) exercises Vertex AI
embeddings end to end.

### 15.6 Redeploy the frontend (so it proxies to the real Knowledge Flow)

```bash
bin/fredlab-frontend-deploy.sh start 0.2
```

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

bin/fredlab-infra-deploy.sh
```

Use only for immutable StatefulSet spec drift.

### Disable Control Plane Without Deleting Data

```bash
bin/fredlab-control-plane-deploy.sh disable
```

### Studio TLS Certificate Is Not Ready

If DNS resolves but HTTPS fails with a certificate name mismatch:

```bash
dig +short studio.playground.fredlab.dev
kubectl get managedcertificate
kubectl describe managedcertificate fredlab-studio-cert
```

Expected:

- DNS returns `8.233.26.38`
- `fredlab-studio-cert` eventually becomes `Active`

Use `curl -k -I https://studio.playground.fredlab.dev` only to confirm routing while the certificate is still provisioning.

### OpenSearch Pod Does Not Start

Check the StatefulSet and logs:

```bash
kubectl get statefulset,pod,pvc -l app.kubernetes.io/component=opensearch
kubectl logs statefulset/opensearch --tail=120
kubectl describe pod -l app.kubernetes.io/component=opensearch
```

Fredlab runs OpenSearch with `node.store.allow_mmap=false` so GKE Autopilot does not need a forbidden `vm.max_map_count` node sysctl. If logs mention memory pressure or scheduling failures, increase `opensearch.resources` rather than adding privileged init containers.

### Knowledge Flow Storage / Auth Failures

```bash
kubectl logs deploy/knowledge-flow-backend --tail=120
```

| Symptom | Likely cause / fix |
| --- | --- |
| `DefaultCredentialsError` at startup | Workload Identity not wired: the KSA annotation or the GSA binding is missing. Re-run `bin/fredlab-gcp-gcs-prereqs.sh` and confirm `knowledgeFlow.serviceAccount.gcpServiceAccount` is set (the deploy script sets it). |
| `403 ... does not have storage.objects.* access` | GSA missing `roles/storage.objectAdmin` on a bucket. Re-run the prereq script. |
| `404 ... bucket does not exist` | A bucket is missing or `content_storage.bucket_name` / `filesystem.bucket_name` is wrong. Remember the content store suffixes `-documents/-objects/-files`. |
| `FRED_POSTGRES_PASSWORD is required` | The deployment env is not wired to the infra secret — should come from `POSTGRES_FRED_PASSWORD`. |
| `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET is not set` | Set `keycloak.clients.knowledgeFlow.secret` in the secrets file and re-run the foundation deploy. |
| Vertex AI / `PermissionDenied` during ingestion | GSA missing `roles/aiplatform.user`, or the model `location` is not a valid Vertex region. Re-run the prereq script; adjust `knowledgeFlow.config.models.location`. |
| Tabular SQL preview errors with `NotImplementedError` | Expected on pure Workload Identity — GCS presigned URLs need an SA key or `signBlob`. |
| `GET /knowledge-flow/v1/tags` hangs → 504, UI "Service de connaissance non démarré" | KNOWN OPEN ISSUE (app-level, not deployment). KF's rebac engine stalls initializing/syncing its authorization model in the shared OpenFGA `fred` store on the first tags lookup (`rebac.lookup_user_resources`). Auth, DB schema, OpenFGA, and KF rebac config are all confirmed correct. Investigate in `fred-core` `security/rebac/openfga_engine.py`; candidate fixes: dedicated OpenFGA store for KF, or a unified authorization model including KF's `tags`/`document` types. |

### Conversations Disappear After A Restart

A conversation shows in the list but reopens empty after a `fred-agents` restart/redeploy.
Cause: the runtime was using SQLite on an `emptyDir` (wiped on every pod restart) instead
of Postgres. The chart now points the runtime `storage.postgres` at the `fred` DB (no
`sqlite_path`); `bin/fredlab-status.sh` **Correctness** must read
`runtime store … fred-agents → Postgres (durable)`. Inspect the tables with
`bin/fredlab-sessions.sh`. Conversations created before the fix are unrecoverable.

### Analytics Dashboard 503 (`KPI store not available`)

The admin analytics dashboard errors; `/control-plane/v1/kpi/presets/...` returns 503.
Cause: the control-plane KPI store reads from OpenSearch, but the KPI OpenSearch sink was
disabled / had no `storage.opensearch` connection, so it fell back to the non-queryable log
sink. The chart now sets `observability.kpi.opensearch.enabled: true` + a `storage.opensearch`
block + `OPENSEARCH_PASSWORD`; Correctness must read `kpi store … → OpenSearch`. KPI events
accrue forward from when the sink was enabled (the log-only period is not backfilled).

### Deploys / Restarts Are Very Slow

Every `helm upgrade` re-runs the `keycloak-provision` post-upgrade hook (heavy: it builds
the temporal-ui auth flow) and helm blocks on it. For app-only redeploys where identity is
unchanged, pass `-fast` to skip that hook (`OPERATING-CONVENTIONS.md` C2.1). To just bounce
pods without helm at all: `kubectl rollout restart deploy/<name>`. Do **not** `disable` the
frontend to "restart" it — that deletes its managed certificate and forces a 15–60 min
re-provision (see "Studio TLS Certificate Is Not Ready").
