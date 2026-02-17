#!/bin/bash

docker compose -f docker-compose-keycloak.yml -p keycloak down
docker compose -f docker-compose-opensearch.yml -p opensearch down
docker compose -f docker-compose-kubernetes.yml -p kubernetes down
docker compose -f docker-compose-k8s-mcp.yml -p k8s-mcp down
docker compose -f docker-compose-temporal.yml -p temporal down
