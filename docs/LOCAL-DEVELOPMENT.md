# Local development stack

Run Fred's backing services on your laptop — for day-to-day development against a local Fred,
or to host the auth/isolation validation release gate, which now lives in the sibling `fred`
monorepo's own `validation/README.md` (run `cd ../fred && make validation-report`). Fred itself
can run on just ChromaDB + SQLite + the local filesystem; this repo gives the fuller
experience (real Postgres, Keycloak, OpenFGA, OpenSearch, Temporal, plus optional
Prometheus / Grafana / ClickHouse / Langfuse).

Two backends, same Make interface: **Docker Compose** (default, simplest) and **k3d** (local
Kubernetes). For the raw Compose internals (shared network, `.env`, per-service files) see
[`../docker/README.md`](../docker/README.md).

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

A local Kubernetes path: a vanilla `k3d` cluster + the `k3d` chart (covers the
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

## What `docker-up` / `k3d-up` provisions

One mode, no flags. Both backends provision the same thing: Keycloak with an **empty realm**
(self-registration enabled), OpenFGA with an **empty store** and the Swift authorization model
only, Postgres, and Temporal - infrastructure only, zero business data. There are no demo
users, no Keycloak groups, no app roles, and no OpenFGA tuples baked in by either backend. The
imported Keycloak realm template never carries team groups, and no script in this repo ever
creates a Keycloak group.

Databases created: `fred` (Fred), `keycloak`, `data` (tabular/vector), `openfga`, `temporal`,
`temporal_visibility`.

Every identity and role - platform (`platform_admin`/`platform_observer`) and team
(`team_admin`/`team_editor`/`team_analyst`/`team_member`) - is provisioned afterwards by
`fred`/control-plane-backend's declarative platform-import feature
(`POST /import-export/import`), not by this repo. See
[`../docker/README.md`](../docker/README.md) ("Platform and demo-data provisioning now lives
in `fred`") for the exact sequence (`make build-demo-bundle` + **Admin → Migration** upload),
or self-register the first user and complete the AUTHZ-07 `/bootstrap` flow to become
`platform_admin`.

## Configuration

`make docker-up` regenerates `docker/.env` from `docker/.env.template` — edit
the template for custom values. Keycloak backend client secrets:

- **Compose:** `KEYCLOAK_AGENTIC_CLIENT_SECRET`, `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`,
  `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET` in `docker/.env.template`.
- **k3d:** `auth.keycloak*ClientSecret` in `k3d/values.yaml`.
