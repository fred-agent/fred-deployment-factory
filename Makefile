.DEFAULT_GOAL := help
SHELL := /bin/bash

DOCKER_COMPOSE_BASE := docker compose -f docker-compose/docker-compose-

CORE_COMPOSE_FILES := \
	docker-compose/docker-compose-temporal.yml \
	docker-compose/docker-compose-opensearch.yml \
	docker-compose/docker-compose-openfga.yml \
	docker-compose/docker-compose-minio.yml \
	docker-compose/docker-compose-keycloak.yml

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nAvailable targets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

network-create:
	@echo "Creating 'fred-shared-network'..."
	docker network create fred-shared-network --driver bridge || echo "Network already exists or error occurred."

env-setup:
	@echo "Setting up .env file..."
	cp docker-compose/.env.template docker-compose/.env
	@echo "NOTE: Remember to customize docker-compose/.env if needed."

keycloak-post-install:
	@echo "Running Keycloak post-install..."
	bash docker-compose/keycloak/keycloak-post-install.sh

keycloak-up: network-create env-setup
	@echo "Launching Keycloak and PostgreSQL..."
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak up -d
	$(MAKE) keycloak-post-install

minio-up: keycloak-up
	@echo "Launching MinIO..."
	$(DOCKER_COMPOSE_BASE)minio.yml -p minio up -d

opensearch-up: keycloak-up
	@echo "Launching OpenSearch..."
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch up -d

openfga-post-install:
	@echo "Running OpenFGA post-install..."
	bash docker-compose/openfga/openfga-post-install.sh

openfga-up: keycloak-up
	@echo "Launching OpenFGA..."
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga up -d
	$(MAKE) openfga-post-install

temporal-up: keycloak-up
	@echo "Launching Temporal..."
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal up -d

preflight-check:
	@echo "Running FRED preflight..."
	bash bin/fred-preflight.sh

core-up: keycloak-up minio-up opensearch-up openfga-up temporal-up ## Launch the core stack (Keycloak, MinIO, OpenSearch, OpenFGA, Temporal)
	$(MAKE) preflight-check
	@echo "All core services are running and preflight passed."

all-down:
	@echo "Stopping core services..."
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga down
	$(DOCKER_COMPOSE_BASE)minio.yml -p minio down
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down

wipe: all-down ## Stop core services, delete volumes, remove network, and prune
	@echo -e "\n--- WIPE IN PROGRESS ---"
	@for file in $(CORE_COMPOSE_FILES); do \
		docker compose -f $$file down -v; \
	done
	docker network rm fred-shared-network || true
	docker system prune -f
	@echo -e "\n--- WIPE COMPLETE ---"

.PHONY: help network-create env-setup keycloak-post-install keycloak-up minio-up opensearch-up openfga-post-install openfga-up temporal-up preflight-check core-up all-down wipe
