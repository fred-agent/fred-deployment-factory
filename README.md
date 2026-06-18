# Fred Deployment Factory (docker-compose & k3d)

Local deployment repository for Fred.

The Docker Compose workflow in this repository groups services into two scopes:
- Structural Fred stack:
  - PostgreSQL
  - Keycloak
  - SeaweedFS
  - OpenSearch
  - OpenFGA
  - Temporal
- Additional local platform services:
  - Prometheus for metrics collection and scraping
  - Grafana for metrics dashboards
  - ClickHouse for analytics/event/vector storage
  - Langfuse for LLM tracing and observability

## Related links
- Fred website: https://fredk8.dev
- Fred repository: https://github.com/ThalesGroup/fred.git

## Why this repository
Fred can be started as-is and run with only ChromaDB, SQLite, and the local filesystem.

The goal of this `fred-deployment-factory` repository is to provide a fuller local experience around Fred.

The structural Fred services exposed here are PostgreSQL, Keycloak, SeaweedFS, OpenSearch, OpenFGA, and Temporal.

Prometheus, Grafana, ClickHouse, and Langfuse are also available for local observability, tracing, and analytics, but they are not structural requirements.

## Prerequisites
- Docker
- Docker Compose (`docker compose`)
- `bash`

## Quick start
1. Optional: customize demo users / roles / teams for Docker demos in:

- `config/configuration.yaml`

2. Start the local Docker environment:

```bash
make docker-up
```

By default this starts the **base** stack (`STACK=base`): the core Fred services without the additional local platform services. To also launch `Prometheus`, `Grafana`, `ClickHouse`, and `Langfuse`, use the **extended** profile:

```bash
make docker-up STACK=extended
```

Default endpoints for the additional services (extended profile only):
- Prometheus: `http://localhost:9090`
- Grafana: `http://localhost:3002`
- ClickHouse SQL UI / HTTP API: `http://localhost:8123/play`
- Langfuse: `http://localhost:3001`

If you only need part of the platform, use the per-service Make targets such as `make keycloak-up`, `make seaweedfs-up`, `make opensearch-up`, `make openfga-up`, `make temporal-up`, `make clickhouse-up`, `make langfuse-up`, `make prometheus-up`, or `make grafana-up`.

### Stack profiles: `base` vs `extended`

`STACK` selects which services are launched, for both `make docker-up` and `make k3d-up`:

| `STACK` | Services |
|---------|----------|
| `base` (default) | Minimal stack — drops ClickHouse, Langfuse, Redis, Prometheus and Grafana |
| `extended` | The full stack, including ClickHouse, Langfuse (+ its Redis), Prometheus and Grafana |

```bash
make docker-up STACK=extended
# or
make k3d-up STACK=extended
```

For Helm, this maps to the chart value `stack` (`--set stack=<profile>`); the extended-only components are deployed only when `stack=extended` **and** their own `enabled` flag is set.

3. Optional (for browser SSO callbacks to Keycloak on local machine):

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

4. Data cleanup (containers & volumes):

```bash
make docker-wipe
```

4. Docker complete cleanup (containers, volumes, network, and images):

```bash
make docker-destroy
```

## Working modes: swift-only vs kea→swift migration testing

This repository supports two releases of Fred: **kea** (the previous release) and **swift** (the current release).

### Mode 1 — swift only (default)

The default for both `make docker-up` and `make k3d-up`. Only the `fred` database is provisioned. This is the right mode for day-to-day swift development or deployment.

```bash
make docker-up
# or
make k3d-up
```

PostgreSQL databases created:

| Database | Owner | Purpose |
|----------|-------|---------|
| `fred` | `fred` | Fred swift (primary) |
| `keycloak` | `keycloak_db_user` | Keycloak |
| `data` | `tabular` | Tabular / vector data |
| `openfga` | `openfga` | OpenFGA |
| `temporal` | `temporal` | Temporal workflow |
| `temporal_visibility` | `temporal` | Temporal visibility |

### Mode 2 — kea→swift migration testing

Pass `WITH_KEA=true` to also provision a `fred_kea` database alongside `fred`. This lets you start a kea instance (pointing at `fred_kea`), populate it with agents, sessions, and prompts, then start a swift instance (pointing at `fred`) and run the migration logic against the two databases.

```bash
make docker-up WITH_KEA=true
# or
make k3d-up WITH_KEA=true
```

The additional database created:

| Database | Owner | Purpose |
|----------|-------|---------|
| `fred_kea` | `fred` | Fred kea (source for migration) |

> **Note:** `fred_kea` is intended to be a temporary migration aid. The kea release is deprecated; this mode will be removed once the migration tooling is no longer needed.

## Configuration
`make docker-up` regenerates `docker-compose/.env` from `docker-compose/.env.template`.

If you need custom values, edit `docker-compose/.env.template` before running `make docker-up`.

Keycloak backend client secrets:
- Docker Compose mode: set `KEYCLOAK_AGENTIC_CLIENT_SECRET`, `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`, and `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET` in `docker-compose/.env.template`.
- k3d mode: set `auth.keycloakAgenticClientSecret`, `auth.keycloakKnowledgeFlowClientSecret`, and `auth.keycloakControlPlaneClientSecret` in `helm/fred-stack/values.yaml` (or via Helm overrides).

ClickHouse k3d settings:
- set `auth.clickhouseUser`, `auth.clickhousePassword`, and `auth.clickhouseDb` in `helm/fred-stack/values.yaml` (or via Helm overrides)

Additional Docker settings:
- ClickHouse: set `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_HTTP_PORT`, and `CLICKHOUSE_NATIVE_PORT` as needed.
- Langfuse: set `POSTGRES_LANGFUSE_USER`, `POSTGRES_LANGFUSE_PASSWORD`, `POSTGRES_LANGFUSE_DB`, and the relevant `LANGFUSE_S3_*` bucket settings.

Prometheus Docker settings:
- set `PROMETHEUS_PORT` to change the exposed host port
- set `PROMETHEUS_RETENTION` to change TSDB retention

Grafana Docker settings:
- set `GRAFANA_PORT` to change the exposed host port
- set `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD` for the local admin account

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

At the moment, the `k3d` / Helm path covers the structural Fred stack + Prometheus + Grafana + ClickHouse. Langfuse remains available through Docker Compose only.

### Bring it up
```bash
make k3d-up
```

By default, this creates a local `k3d` cluster named `fred` with default k3s networking (no Cilium), installs the Helm release (`fred-stack`) into namespace `fred`, and exposes these host ports:
- PostgreSQL: `localhost:5432`
- Keycloak: `http://localhost:8080`
- SeaweedFS S3 API: `http://localhost:8333`
- SeaweedFS Filer API: `http://localhost:8888`
- SeaweedFS Master API: `http://localhost:9333`
- OpenSearch: `https://localhost:9200`
- OpenSearch Dashboards: `http://localhost:5601`
- OpenFGA HTTP: `http://localhost:9080`
- OpenFGA gRPC: `localhost:9081`
- Temporal Frontend gRPC: `localhost:7233`
- Temporal UI: `http://localhost:8233`
- Prometheus: `http://localhost:9090`
- Grafana: `http://localhost:3002`
- ClickHouse HTTP / SQL UI: `http://localhost:8123/play`
- ClickHouse native protocol: `localhost:9002`

`make k3d-up` now prints colored step progress (`[STEP]`, `[OK]`, `[WARN]`, `[INFO]`, `[FAIL]`), pre-pulls chart images (and kube-system images by default) on the host and imports them into k3d (`K3D_PREFETCH_IMAGES=true`, `K3D_PREFETCH_SYSTEM_IMAGES=true`), retries image pulls on transient network errors (`IMAGE_PULL_RETRIES`, `IMAGE_PULL_RETRY_DELAY`), shows a deployment heartbeat every 10s while Helm waits, handles `Ctrl+C` cleanly (including stopping Helm subprocesses), and on Helm failure automatically dumps pods/jobs/events plus `helm status`.

The Helm deploy uses `upgrade --install --rollback-on-failure`, and `k3d-up` auto-recovers a stuck `pending-*` Helm release before deploying, so rerunning `make k3d-up` is safe and converges cleanly.

If you disable prefetch (`K3D_PREFETCH_IMAGES=false`), `k3d-up` falls back to a DNS preflight from inside the k3d node and fails fast if registry DNS is broken.

If some ports are already used (for example by the Docker Compose stack), override them at launch time:

```bash
make k3d-up K3D_HOST_PORT_POSTGRES=15432 K3D_HOST_PORT_KEYCLOAK=18080 K3D_HOST_PORT_SEAWEEDFS_S3=18333 K3D_HOST_PORT_CLICKHOUSE_HTTP=18123 K3D_HOST_PORT_CLICKHOUSE_NATIVE=19002 K3D_HOST_PORT_PROMETHEUS=19090 K3D_HOST_PORT_GRAFANA=13000
```

Prometheus is configured with persistent local storage and discovers scrape targets through standard Kubernetes annotations (`prometheus.io/scrape`, `prometheus.io/port`, `prometheus.io/path`) on Services or Pods.
Grafana is pre-provisioned with a Prometheus datasource that targets the in-cluster service `http://prometheus:9090`.

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
