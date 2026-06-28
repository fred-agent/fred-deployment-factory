# Local development stack

Run Fred's backing services on your laptop — for day-to-day development against a local Fred,
or to host the [auth/isolation validation](../validation/README.md) release gate. Fred itself
can run on just ChromaDB + SQLite + the local filesystem; this repo gives the fuller
experience (real Postgres, Keycloak, OpenFGA, OpenSearch, Temporal, plus optional
Prometheus / Grafana / ClickHouse / Langfuse).

Two backends, same Make interface: **Docker Compose** (default, simplest) and **k3d** (local
Kubernetes). For the raw Compose internals (shared network, `.env`, per-service files) see
[`../docker-compose/README.md`](../docker-compose/README.md).

**Prerequisites:** Docker, Docker Compose (`docker compose`), `bash`. (k3d path also needs
`k3d`, `kubectl`, `helm`.)

## Quick start (Docker Compose)

```bash
make docker-up                  # base stack: core Fred services
make docker-up STACK=extended   # + Prometheus, Grafana, ClickHouse, Langfuse
```

Optional — browser SSO callbacks to Keycloak on localhost:

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

Cleanup:

```bash
make docker-wipe       # containers & volumes
make docker-destroy    # containers, volumes, network, and images
```

Extended-profile endpoints: Prometheus `:9090`, Grafana `:3002`, ClickHouse `:8123/play`,
Langfuse `:3001`. Per-service targets also exist (`make keycloak-up`, `make opensearch-up`,
`make openfga-up`, `make temporal-up`, …).

## Stack profiles: `base` vs `extended`

`STACK` selects which services launch, for both `make docker-up` and `make k3d-up`:

| `STACK` | Services |
|---------|----------|
| `base` (default) | Minimal stack — drops ClickHouse, Langfuse, Redis, Prometheus, Grafana |
| `extended` | Full stack, including ClickHouse, Langfuse (+ Redis), Prometheus, Grafana |

For Helm this maps to the chart value `stack` (`--set stack=<profile>`); extended-only
components deploy only when `stack=extended` **and** their own `enabled` flag is set.

## k3d + Helm stack

A local Kubernetes path: a vanilla `k3d` cluster + the `helm/fred-stack` chart (covers the
structural stack + Prometheus + Grafana + ClickHouse; Langfuse stays Compose-only). Optional
Cilium (`K3D_USE_CILIUM=true`) only for `CiliumNetworkPolicy` / air-gap flows.

```bash
make k3d-up            # create cluster 'fred', install the 'fred-stack' release into namespace 'fred'
make k3d-wipe          # full reset (down + delete)
```

Host ports (override with `K3D_HOST_PORT_*` if they clash with the Compose stack): Postgres
`:5432`, Keycloak `:8080`, SeaweedFS S3 `:8333`, OpenSearch `:9200`, OpenFGA HTTP `:9080` /
gRPC `:9081`, Temporal gRPC `:7233` / UI `:8233`, Prometheus `:9090`, Grafana `:3002`,
ClickHouse `:8123`. `make k3d-up` prefetches images, retries transient pull failures, and uses
`helm upgrade --install --rollback-on-failure`, so rerunning it converges cleanly.

Tear down: `make k3d-down` (uninstall release) · `make k3d-delete` (delete cluster) ·
`make k3d-wipe` (both).

## Working modes: swift-only vs kea→swift migration

| Mode | Command | Provisions |
| --- | --- | --- |
| **swift only** (default) | `make docker-up` / `make k3d-up` | the `fred` DB only — day-to-day swift work |
| **kea→swift migration** | `make docker-up WITH_KEA=true` | also a `fred_kea` DB, to test migrating a kea instance into swift |

Databases created in swift mode: `fred` (Fred), `keycloak`, `data` (tabular/vector),
`openfga`, `temporal`, `temporal_visibility`. `WITH_KEA=true` adds `fred_kea` (a temporary
migration aid; removed once the kea migration tooling is retired).

## Configuration & demo identities

`make docker-up` regenerates `docker-compose/.env` from `docker-compose/.env.template` — edit
the template for custom values. Keycloak backend client secrets:

- **Compose:** `KEYCLOAK_AGENTIC_CLIENT_SECRET`, `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`,
  `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET` in `docker-compose/.env.template`.
- **k3d:** `auth.keycloak*ClientSecret` in `helm/fred-stack/values.yaml`.

For the Compose workflow, the single source of truth for demo users / groups (teams) / client
roles / OpenFGA membership tuples is **`config/configuration.yaml`**. Edit it, then
`make docker-wipe && make docker-up`. (The k3d/Helm path is not yet migrated to it and still
uses the chart's `helm/fred-stack/files/openfga/openfga-seed.json`.)
