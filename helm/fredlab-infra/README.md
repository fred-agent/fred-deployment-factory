# Fredlab Infra

Helm chart for Fredlab Playground on GKE Autopilot.

## Scope

| Component | Visibility | Internal DNS | Public host |
| --- | --- | --- | --- |
| PostgreSQL | Private | `postgres:5432` | none |
| Keycloak | Public | `keycloak:8080` | `keycloak.playground.fredlab.dev` |
| OpenFGA | Private | `openfga:8080`, `openfga:8081` | none |
| Temporal | Private | `temporal:7233` | none |
| Temporal UI | Protected admin UI | `temporal-ui:8080` | `temporal.playground.fredlab.dev` |
| Control Plane backend | Private | `control-plane-backend:8080` | none |
| Fred frontend | Public | `fred-frontend:8080` | `studio.playground.fredlab.dev` |

All services use `ClusterIP`. Public routing is handled by the GKE `gce` Ingress named `fredlab-infra-ingress`.

Public hostnames must exist in DNS outside Helm and point to the reserved GCP global IP `8.233.26.38`.

Each public hostname has its own GKE `ManagedCertificate`, all attached to the same Ingress:

- `fredlab-infra-cert` for Keycloak
- `fredlab-temporal-cert` for Temporal UI
- `fredlab-studio-cert` for Studio

This avoids mutating an already-attached Google-managed certificate when new public hosts are added.

## Naming Rules

The chart avoids Helm release-name prefixes for service DNS:

- infrastructure services use fixed short names: `postgres`, `keycloak`, `openfga`, `temporal`
- app backends use `[app-name]-backend`
- app frontends use `[app-name]-frontend`
- admin UIs use `[component]-ui`

## Security

The chart is designed for GKE Autopilot:

- no privileged containers
- no node-level `sysctl`
- no privileged `chown` init jobs
- explicit CPU and memory requests
- real secrets live in `fredlab-secrets.values.yaml`, ignored by Git

Temporal UI is protected by the Cloud Armor allowlist policy:

```text
fredlab-admin-ui-allowlist
```

## Data Ownership

PostgreSQL provisioning and application schema migrations are intentionally separated:

| Layer | Responsible object | Creates |
| --- | --- | --- |
| Database bootstrap | `postgres-provision` Helm hook | PostgreSQL users, databases, grants |
| Identity bootstrap | `keycloak-provision` Helm hook | Keycloak realm `app`, clients `app` and `control-plane` |
| Control Plane schema | `control-plane-migration` Helm hook | Control Plane tables via `alembic upgrade head` |
| Control Plane runtime | `control-plane-backend` Deployment | HTTP service only |

For Swift, the current Fred repository contains multiple Alembic revisions. Fredlab applies the repository contract as-is with `alembic upgrade head`. Before a first production Swift release, decide separately whether to keep this history or squash it into a single bootstrap migration.

## Identity State

Deploying Keycloak only starts the identity server. Fred still needs a provisioned realm and clients:

- realm `app`
- public frontend client `app`
- confidential machine client `control-plane`
- matching `keycloak.clients.controlPlane.secret`
- service-account roles required by Control Plane: `realm-management` user/group read/write basics, `account:view-groups`, and `app:service_agent`
- users and team/group mapping for the Fred Swift identity model

The chart provisions the realm and clients with the `keycloak-provision` Helm hook. The control-plane reads the machine client secret from the exact env var `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET`.

User and team/group provisioning remains a separate application-domain step. Do not confuse it with the low-level realm/client bootstrap.

For the current Fredlab phase, only the `control-plane` service client is provisioned. Future deployments of `knowledge-flow-backend` and `fred-agents` must add their own confidential clients and secrets (`knowledge-flow` / `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`, `agentic` / `KEYCLOAK_AGENTIC_CLIENT_SECRET`) before those services are enabled.

Initial Keycloak users and groups can be provisioned from a local identity file:

```bash
cp config/fredlab-keycloak-identity.example.json config/fredlab-keycloak-identity.json
bin/fredlab-keycloak-identity.sh
```

The real `config/fredlab-keycloak-identity.json` file is ignored by Git. The script creates Keycloak groups, users, app client roles, group membership, and the `groups` token claim. It does not yet create Fred/OpenFGA team ownership tuples.

When validating Keycloak clients, always use `kcadm.sh --fields ...`. The full representation of the confidential `control-plane` client includes its secret.

## Private Values

Create one complete local secret file from:

```bash
cp helm/fredlab-infra/fredlab-secrets.values.example.yaml \
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

Validate that the secret file is ignored:

```bash
git status --short --ignored helm/fredlab-infra/fredlab-secrets.values.yaml
```

Expected:

```text
!! helm/fredlab-infra/fredlab-secrets.values.yaml
```

## Deploy

Use [DEPLOYMENT-STEPS.md](./DEPLOYMENT-STEPS.md) for the canonical GKE deployment procedure.

Foundation:

```bash
bin/fredlab-infra-deploy.sh
```

Use this script instead of a raw `helm upgrade` after application components have been enabled. It preserves the current Helm release values, so Control Plane and Studio are not accidentally disabled during a foundation upgrade.

Images:

Image builds are driven by a small committed catalog: [config/fredlab-images.tsv](../../config/fredlab-images.tsv). This keeps daily commands short while making the required conventions explicit.

```bash
bin/fredlab-gcp-build-prereqs.sh
bin/fredlab-build list
bin/fredlab-build control-plane-backend 0.2
bin/fredlab-build frontend 0.2
bin/fredlab-build fred-agents 0.2
```

The catalog assumes source repositories exist in Cloud Shell at paths such as `~/fred`, `~/dt-agents`, or `~/fred-samples`, and that each image has a Dockerfile path declared from that repository root.

GCS preparation:

Knowledge Flow and agentic components should use Google Cloud Storage on GKE, not an in-cluster MinIO replacement. The current chart only prepares GCP for this future Swift capability; it does not yet wire Knowledge Flow to GCS.

```bash
bin/fredlab-gcp-gcs-prereqs.sh
```

This creates the future Knowledge Flow bucket, a Google service account, and Workload Identity bindings for the expected Kubernetes service accounts. No JSON key, HMAC key, or secret file is created.

Control Plane runtime:

```bash
bin/fredlab-control-plane-deploy.sh migrate 0.2
bin/fredlab-control-plane-deploy.sh start 0.2
```

The deployment phase stays explicit: `migrate` runs Alembic database migrations first, then `start` launches the HTTP backend. On a fresh database, migrations create the initial Control Plane tables.

Control Plane does not use the image's bundled `configuration_prod.yaml` directly. The chart renders a Fredlab-specific `control-plane-config` ConfigMap and sets `CONFIG_FILE=/etc/fred/control-plane/configuration.yaml`, so cluster DNS names, Keycloak issuer, OpenFGA, Temporal, and the health path are owned by Helm values.

Frontend runtime:

```bash
bin/fredlab-frontend-deploy.sh start 0.2
```

This deploys the public `fred-frontend` service at `https://studio.playground.fredlab.dev`. The frontend stays thin: Nginx serves the static UI and proxies `/control-plane/...` to `control-plane-backend:8080`. The login configuration still comes from Control Plane through `/control-plane/v1/frontend/config`.

During the first bootstrap, `fred-agents` and `knowledge-flow-backend` are not deployed yet. Their frontend upstreams intentionally point to `control-plane-backend` so Nginx can start; they must be switched to their real services when those components are deployed.

The deploy scripts preserve existing Helm release values when the release already exists, while also loading new chart defaults. That allows enabling frontend after Control Plane without accidentally disabling the components that are already running.
