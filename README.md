# FRED Deployment Factory

Local deployment repository for FRED.

The Docker Compose workflow in this repository groups services into two scopes:
- Structural Fred stack:
  - PostgreSQL
  - Keycloak
  - MinIO
  - OpenSearch
  - OpenFGA
  - Temporal
- Additional local platform services:
  - Prometheus for metrics collection and scraping
  - ClickHouse for analytics/event/vector storage
  - Langfuse for LLM tracing and observability

## Related links
- FRED website: https://fredk8.dev
- FRED repository: https://github.com/ThalesGroup/fred.git

## Why this repository
FRED can be started as-is and run with only ChromaDB, SQLite, and the local filesystem.

The goal of this `fred-deployment-factory` repository is to provide a fuller local experience around Fred.

The structural Fred services exposed here are PostgreSQL, Keycloak, MinIO, OpenSearch, OpenFGA, and Temporal.

Prometheus, ClickHouse, and Langfuse are also available for local observability, tracing, and analytics, but they are not structural requirements.

## Prerequisites
- Docker
- Docker Compose (`docker compose`)
- `bash`

## Quick start
1. Optional: customize demo users / roles / teams for Docker demos in:

- `config/configuration.yaml`

2. Start the full local Docker environment:

```bash
make docker-up
```

This launches both the structural FRED services and the additional local platform services (`Prometheus`, `ClickHouse`, and `Langfuse`).

Default endpoints for the additional services:
- Prometheus: `http://localhost:9090`
- ClickHouse SQL UI / HTTP API: `http://localhost:8123/play`
- Langfuse: `http://localhost:3001`

If you only need part of the platform, use the per-service Make targets such as `make keycloak-up`, `make minio-up`, `make opensearch-up`, `make openfga-up`, `make temporal-up`, `make clickhouse-up`, `make langfuse-up`, or `make prometheus-up`.

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

Additional Docker settings:
- ClickHouse: set `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_HTTP_PORT`, and `CLICKHOUSE_NATIVE_PORT` as needed.
- Langfuse: set `POSTGRES_LANGFUSE_USER`, `POSTGRES_LANGFUSE_PASSWORD`, `POSTGRES_LANGFUSE_DB`, and the relevant `LANGFUSE_S3_*` bucket settings.

Prometheus Docker settings:
- set `PROMETHEUS_PORT` to change the exposed host port
- set `PROMETHEUS_RETENTION` to change TSDB retention

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

At the moment, the `k3d` / Helm path covers the structural Fred stack + Prometheus. The optional ClickHouse and Langfuse services are currently available through Docker Compose only.

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
- Prometheus: `http://localhost:9090`

`make k3d-up` now prints colored step progress (`[STEP]`, `[OK]`, `[WARN]`, `[INFO]`, `[FAIL]`), pre-pulls chart images (and kube-system images by default) on the host and imports them into k3d (`K3D_PREFETCH_IMAGES=true`, `K3D_PREFETCH_SYSTEM_IMAGES=true`), retries image pulls on transient network errors (`IMAGE_PULL_RETRIES`, `IMAGE_PULL_RETRY_DELAY`), shows a deployment heartbeat every 10s while Helm waits, handles `Ctrl+C` cleanly (including stopping Helm subprocesses), and on Helm failure automatically dumps pods/jobs/events plus `helm status`.

The Helm deploy uses `upgrade --install --atomic`, and `k3d-up` auto-recovers a stuck `pending-*` Helm release before deploying, so rerunning `make k3d-up` is safe and converges cleanly.

If you disable prefetch (`K3D_PREFETCH_IMAGES=false`), `k3d-up` falls back to a DNS preflight from inside the k3d node and fails fast if registry DNS is broken.

If some ports are already used (for example by the Docker Compose stack), override them at launch time:

```bash
make k3d-up K3D_HOST_PORT_POSTGRES=15432 K3D_HOST_PORT_KEYCLOAK=18080 K3D_HOST_PORT_MINIO_API=19000 K3D_HOST_PORT_PROMETHEUS=19090
```

Prometheus is configured with persistent local storage and discovers scrape targets through standard Kubernetes annotations (`prometheus.io/scrape`, `prometheus.io/port`, `prometheus.io/path`) on Services or Pods.

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
