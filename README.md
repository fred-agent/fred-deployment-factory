# FRED Deployment Factory (Docker Core)

Local Docker Compose stack for the core FRED services:
- Keycloak (+ PostgreSQL)
- MinIO
- OpenSearch
- OpenFGA
- Temporal

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
