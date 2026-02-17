#!/bin/bash

docker network create fred-shared-network --driver bridge
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts

# todo manque la vestion du .env d'après le readme
cp docker-compose/.env.template docker-compose/.env

docker compose -f docker-compose-keycloak.yml -p keycloak up -d
docker compose -f docker-compose-minio.yml -p minio up -d
docker compose -f docker-compose-opensearch.yml -p opensearch up -d
docker compose -f docker-compose-kubernetes.yml -p kubernetes up -d
docker compose -f docker-compose-k8s-mcp.yml -p k8s-mcp up -d
docker compose -f docker-compose-temporal.yml -p temporal up -d
docker compose -f docker-compose-minio.yml -p minio up -d
