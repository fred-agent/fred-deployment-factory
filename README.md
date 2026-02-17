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
