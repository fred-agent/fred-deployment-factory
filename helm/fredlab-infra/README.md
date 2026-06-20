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
| Control Plane schema | `control-plane-migration` Helm hook | Control Plane tables via `alembic upgrade head` |
| Control Plane runtime | `control-plane-backend` Deployment | HTTP service only |

For Swift, the current Fred repository contains multiple Alembic revisions. Fredlab applies the repository contract as-is with `alembic upgrade head`. Before a first production Swift release, decide separately whether to keep this history or squash it into a single bootstrap migration.

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

Foundation only:

```bash
helm upgrade --install fredlab-infra ./helm/fredlab-infra \
  --namespace default \
  -f helm/fredlab-infra/fredlab-secrets.values.yaml
```

Control Plane deployment uses the helper scripts from the repository root:

```bash
bin/fredlab-gcp-build-prereqs.sh
FRED_REPO_DIR=~/fred IMAGE=control-plane-backend DOCKERFILE=apps/control-plane-backend/dockerfiles/Dockerfile-prod TAG=0.2 bin/fredlab-build-image.sh
bin/fredlab-control-plane-deploy.sh migrate 0.2
bin/fredlab-control-plane-deploy.sh start 0.2
```

The deployment phase stays explicit: migrations run first, then the HTTP backend starts.
