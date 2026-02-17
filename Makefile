.DEFAULT_GOAL := help
SHELL := /bin/bash

DOCKER_COMPOSE_BASE := docker compose -f docker-compose/docker-compose-

CORE_COMPOSE_FILES := \
	docker-compose/docker-compose-temporal.yml \
	docker-compose/docker-compose-opensearch.yml \
	docker-compose/docker-compose-openfga.yml \
	docker-compose/docker-compose-minio.yml \
	docker-compose/docker-compose-keycloak.yml

K3D_CLUSTER ?= fred
K3D_NAMESPACE ?= fred
HELM_RELEASE ?= fred-stack
HELM_CHART_DIR ?= ./helm/fred-stack
HELM_TIMEOUT ?= 20m

K3D_HOST_PORT_KEYCLOAK ?= 8080
K3D_HOST_PORT_POSTGRES ?= 5432
K3D_HOST_PORT_MINIO_API ?= 9000
K3D_HOST_PORT_MINIO_CONSOLE ?= 9001
K3D_HOST_PORT_OPENSEARCH ?= 9200
K3D_HOST_PORT_OPENSEARCH_DASHBOARDS ?= 5601
K3D_HOST_PORT_OPENFGA_HTTP ?= 9080
K3D_HOST_PORT_OPENFGA_GRPC ?= 9081
K3D_HOST_PORT_TEMPORAL_FRONTEND ?= 7233
K3D_HOST_PORT_TEMPORAL_UI ?= 8233

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

k3d-create: ## Create a local k3d cluster configured for FRED NodePorts
	@if ! command -v k3d >/dev/null 2>&1; then echo "k3d is required"; exit 1; fi
	@echo "Creating k3d cluster '$(K3D_CLUSTER)' (if missing)..."
	@k3d cluster get "$(K3D_CLUSTER)" >/dev/null 2>&1 || \
	k3d cluster create "$(K3D_CLUSTER)" \
	  --servers 1 \
	  --agents 1 \
	  --wait \
	  -p "$(K3D_HOST_PORT_POSTGRES):30432@server:0" \
	  -p "$(K3D_HOST_PORT_KEYCLOAK):30080@server:0" \
	  -p "$(K3D_HOST_PORT_MINIO_API):30900@server:0" \
	  -p "$(K3D_HOST_PORT_MINIO_CONSOLE):30901@server:0" \
	  -p "$(K3D_HOST_PORT_OPENSEARCH):30920@server:0" \
	  -p "$(K3D_HOST_PORT_OPENSEARCH_DASHBOARDS):30561@server:0" \
	  -p "$(K3D_HOST_PORT_OPENFGA_HTTP):30908@server:0" \
	  -p "$(K3D_HOST_PORT_OPENFGA_GRPC):30981@server:0" \
	  -p "$(K3D_HOST_PORT_TEMPORAL_FRONTEND):30723@server:0" \
	  -p "$(K3D_HOST_PORT_TEMPORAL_UI):30233@server:0"

k3d-up: k3d-create ## Deploy the full stack into k3d with Helm
	@if ! command -v helm >/dev/null 2>&1; then echo "helm is required"; exit 1; fi
	@kubectl config use-context "k3d-$(K3D_CLUSTER)" >/dev/null
	@echo "Deploying Helm release '$(HELM_RELEASE)' into namespace '$(K3D_NAMESPACE)'..."
	helm upgrade --install "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" \
	  --namespace "$(K3D_NAMESPACE)" \
	  --create-namespace \
	  --wait \
	  --wait-for-jobs \
	  --timeout "$(HELM_TIMEOUT)"

k3d-down: ## Uninstall the Helm release from k3d namespace
	@echo "Removing Helm release '$(HELM_RELEASE)' from namespace '$(K3D_NAMESPACE)'..."
	-helm uninstall "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)"

k3d-delete: ## Delete the k3d cluster
	@echo "Deleting k3d cluster '$(K3D_CLUSTER)'..."
	-k3d cluster delete "$(K3D_CLUSTER)"

k3d-status: ## Show pods and services in the k3d namespace
	@kubectl config use-context "k3d-$(K3D_CLUSTER)" >/dev/null
	@echo "Namespace: $(K3D_NAMESPACE)"
	kubectl get pods,svc -n "$(K3D_NAMESPACE)"

.PHONY: help network-create env-setup keycloak-post-install keycloak-up minio-up opensearch-up openfga-post-install openfga-up temporal-up preflight-check core-up all-down wipe k3d-create k3d-up k3d-down k3d-delete k3d-status
