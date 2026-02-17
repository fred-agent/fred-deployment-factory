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
1. Start everything:

```bash
make core-up
```

2. Optional (for browser SSO callbacks to Keycloak on local machine):

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

3. Full cleanup (containers, volumes, network, docker prune):

```bash
make wipe
```

## Configuration
`make core-up` regenerates `docker-compose/.env` from `docker-compose/.env.template`.

If you need custom values, edit `docker-compose/.env.template` before running `make core-up`.

## k3d + Helm stack
This repository also includes a Kubernetes deployment path using:
- a vanilla `k3d` cluster
- a standard Helm chart at `helm/fred-stack`

### Bring it up
```bash
make k3d-up
```

This creates a local `k3d` cluster named `fred`, installs the Helm release (`fred-stack`) into namespace `fred`, and exposes these host ports:
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

If some ports are already used (for example by the Docker Compose stack), override them at launch time:

```bash
make k3d-up K3D_HOST_PORT_POSTGRES=15432 K3D_HOST_PORT_KEYCLOAK=18080 K3D_HOST_PORT_MINIO_API=19000
```

### Tear down
```bash
make k3d-down     # uninstall Helm release only
make k3d-delete   # delete cluster
```
