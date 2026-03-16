# FRED Deployment Factory (Docker Core)

Local Docker Compose stack for the core FRED services:
- Keycloak (+ PostgreSQL)
- MinIO
- OpenSearch
- OpenFGA
- Temporal

## Related links
- FRED website: https://fredk8.dev
- FRED repository: https://github.com/ThalesGroup/fred.git

## Why this repository
FRED can be started as-is and run with only ChromaDB, SQLite, and the local filesystem.

The goal of this `fred-deployment-factory` repository is to provide a fuller local experience with supporting services such as MinIO, Keycloak, OpenSearch, and PostgreSQL (along with OpenFGA and Temporal in this stack).

## Prerequisites
- Docker
- Docker Compose (`docker compose`)
- `bash`

## Quick start
1. Optional: customize demo users / roles / teams for Docker demos in:

- `config/configuration.yaml`

2. Start everything:

```bash
make docker-up
```

3. Optional (for browser SSO callbacks to Keycloak on local machine):

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

4. Full cleanup (containers, volumes, network, docker prune):

```bash
make docker-wipe
```

## Configuration
`make docker-up` regenerates `docker-compose/.env` from `docker-compose/.env.template`.

If you need custom values, edit `docker-compose/.env.template` before running `make docker-up`.

Keycloak backend client secrets:
- Docker Compose mode: set `KEYCLOAK_AGENTIC_CLIENT_SECRET`, `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`, and `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET` in `docker-compose/.env.template`.
- k3d mode: set `auth.keycloakAgenticClientSecret`, `auth.keycloakKnowledgeFlowClientSecret`, and `auth.keycloakControlPlaneClientSecret` in `helm/fred-stack/values.yaml` (or via Helm overrides).

### Docker demos: single config file (users, roles, teams)
For the Docker Compose workflow (`make docker-up`), the single source of truth for demo identities is:

- `config/configuration.yaml`

This file drives:
- Keycloak demo users
- Keycloak groups (teams)
- Keycloak app client roles assigned to users
- Keycloak group memberships
- OpenFGA team membership tuples
- preflight expectations (`make preflight-check`; agent ownership coverage is opt-in via `PREFLIGHT_CHECK_AGENT_OWNERSHIP=true`)

If you want to prepare a demo/test scenario, edit only `config/configuration.yaml`, then run:

```bash
make docker-wipe
make docker-up
```

Notes:
- For the Docker workflow, you do not need to edit `helm/fred-stack/files/openfga/openfga-seed.json`.
- The k3d/Helm workflow (`make k3d-up`) is not yet migrated to `config/configuration.yaml` and still uses the Helm chart files.

## k3d + Helm stack
This repository also includes a Kubernetes deployment path using:
- a vanilla `k3d` cluster
- a standard Helm chart at `helm/fred-stack`
- optional Cilium (`K3D_USE_CILIUM=true`) only for CiliumNetworkPolicy/air-gap flows

### Bring it up
```bash
make k3d-up
```

By default, this creates a local `k3d` cluster named `fred` with default k3s networking (no Cilium), installs the Helm release (`fred-stack`) into namespace `fred`, and exposes these host ports:
- PostgreSQL: `localhost:5432`
- Keycloak: `http://localhost:8080`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`
- OpenSearch: `https://localhost:9200`
- OpenSearch Dashboards: `http://localhost:5601`
- OpenFGA HTTP: `http://localhost:9080`
- OpenFGA gRPC: `localhost:9081`
- Temporal Frontend gRPC: `localhost:7233`
- Temporal UI: `http://localhost:8233`

`make k3d-up` now prints colored step progress (`[STEP]`, `[OK]`, `[WARN]`, `[INFO]`, `[FAIL]`), pre-pulls chart images (and kube-system images by default) on the host and imports them into k3d (`K3D_PREFETCH_IMAGES=true`, `K3D_PREFETCH_SYSTEM_IMAGES=true`), retries image pulls on transient network errors (`IMAGE_PULL_RETRIES`, `IMAGE_PULL_RETRY_DELAY`), shows a deployment heartbeat every 10s while Helm waits, handles `Ctrl+C` cleanly (including stopping Helm subprocesses), and on Helm failure automatically dumps pods/jobs/events plus `helm status`.

The Helm deploy uses `upgrade --install --atomic`, and `k3d-up` auto-recovers a stuck `pending-*` Helm release before deploying, so rerunning `make k3d-up` is safe and converges cleanly.

If you disable prefetch (`K3D_PREFETCH_IMAGES=false`), `k3d-up` falls back to a DNS preflight from inside the k3d node and fails fast if registry DNS is broken.

If some ports are already used (for example by the Docker Compose stack), override them at launch time:

```bash
make k3d-up K3D_HOST_PORT_POSTGRES=15432 K3D_HOST_PORT_KEYCLOAK=18080 K3D_HOST_PORT_MINIO_API=19000
```

If your machine is slower, increase Helm wait timeout:

```bash
make k3d-up HELM_TIMEOUT=30m
```

If you need air-gap controls via `CiliumNetworkPolicy`, enable Cilium explicitly:

```bash
make k3d-up K3D_USE_CILIUM=true
```

### Tear down
```bash
make k3d-down     # uninstall Helm release only
make k3d-delete   # delete cluster
make k3d-wipe     # full reset (down + delete)
```
