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
| Fred frontend | Public | `fred-frontend:8080` | `fred.playground.fredlab.dev` |

All services use `ClusterIP`. Public routing is handled by the GKE `gce` Ingress named `fredlab-infra-ingress`.

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
- users and team/group mapping for the Fred Swift identity model

The chart provisions the realm and clients with the `keycloak-provision` Helm hook. The control-plane reads the machine client secret from the exact env var `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET`.

User and team/group provisioning remains a separate application-domain step. Do not confuse it with the low-level realm/client bootstrap.

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
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

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

This deploys the public `fred-frontend` service at `https://fred.playground.fredlab.dev`. The frontend stays thin: Nginx serves the static UI and proxies `/control-plane/...` to `control-plane-backend:8080`. The login configuration still comes from Control Plane through `/control-plane/v1/frontend/config`.

During the first bootstrap, `fred-agents` and `knowledge-flow-backend` are not deployed yet. Their frontend upstreams intentionally point to `control-plane-backend` so Nginx can start; they must be switched to their real services when those components are deployed.

The deploy scripts preserve existing Helm release values when the release already exists, while also loading new chart defaults. That allows enabling frontend after Control Plane without accidentally disabling the components that are already running.
