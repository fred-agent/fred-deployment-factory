.DEFAULT_GOAL := help
SHELL := /bin/bash

# FRED names a Fred release line, a Helmfile environment: it decides where an application
# goes. It is typed on each command: a value left in the shell must never choose for you.
ifneq ($(filter k3d-% docker-app,$(MAKECMDGOALS)),)
ifneq ($(filter environment environment override,$(origin FRED)),)
$(error FRED is set in your shell. Unset it and type it on the command: make $(firstword $(MAKECMDGOALS)) FRED=...)
endif
endif

K3D_INFRA_COMMANDS := k3d-up k3d-validate k3d-start k3d-stop k3d-status k3d-health k3d-wipe
ifneq ($(filter $(K3D_INFRA_COMMANDS),$(MAKECMDGOALS)),)
ifneq ($(words $(MAKECMDGOALS)),1)
$(error Run one k3d command at a time)
endif
ifneq ($(strip $(filter-out VALUES=%,$(MAKEOVERRIDES))),)
$(error This command prepares every Fred release line and takes no such variable. Use make k3d-app FRED=... APP=... for an application)
endif
endif

# Docker and k3d have independent selectors. Existing Docker commands keep Swift.
DOCKER_ENV ?= swift
ifeq ($(filter $(DOCKER_ENV),swift weaver),)
$(error Invalid DOCKER_ENV '$(DOCKER_ENV)'. Use DOCKER_ENV=swift or DOCKER_ENV=weaver)
endif
include docker/environments/$(DOCKER_ENV).env
DOCKER_SHARED_ENV_FILE ?= $(CURDIR)/docker/.env
ifeq ($(DOCKER_ENV),swift)
DOCKER_ENV_FILE ?= $(CURDIR)/docker/.env
else
DOCKER_ENV_FILE ?= $(CURDIR)/docker/.env.weaver
endif
# Recompute the default env-file path when an explicit launcher calls Make
# recursively with another environment; command-line overrides still propagate.
export $(filter-out DOCKER_ENV_FILE,$(filter DOCKER_%,$(.VARIABLES)))
unexport DOCKER_ENV_FILE
DOCKER_COMPOSE_BASE := docker compose --env-file "$(DOCKER_ENV_FILE)" -f docker/docker-compose-
DOCKER_SHARED_COMPOSE_BASE := docker compose --env-file "$(DOCKER_SHARED_ENV_FILE)" -f docker/docker-compose-

# Both environments use the same endpoints; their data is selected at launch.
DOCKER_KEYCLOAK_URL := http://localhost:8080
DOCKER_OPENFGA_URL := http://localhost:9080
DOCKER_HELPER_ENV = ENV_FILE="$(DOCKER_ENV_FILE)" \
	KEYCLOAK_CONTAINER="app-keycloak" \
	KEYCLOAK_SERVER_URL="$(DOCKER_KEYCLOAK_URL)" \
	KC="$(DOCKER_KEYCLOAK_URL)" FGA="$(DOCKER_OPENFGA_URL)" \
	OPENFGA_URL="$(DOCKER_OPENFGA_URL)" \
	SEAWEEDFS_CONTAINER="$(DOCKER_CONTAINER_PREFIX)app-seaweedfs"
DOCKER_KEYCLOAK_HELPER_ENV = ENV_FILE="$(DOCKER_SHARED_ENV_FILE)" \
	KEYCLOAK_CONTAINER="app-keycloak" KEYCLOAK_SERVER_URL="$(DOCKER_KEYCLOAK_URL)"

# New data stacks contain no business/demo data. The shared Keycloak realm is
# kept across switches; platform authorization and business data belong to the
# selected application database. Bootstrap a fresh platform through Fred.

# STACK selects Docker Compose services only; k3d has one fixed service set:
#   base (default) → minimal stack: drops ClickHouse, Langfuse (+ its Redis),
#                    and, on Docker only, Prometheus and Grafana (k3d keeps its
#                    observability: Prometheus, Grafana, Fluent Bit)
#   extended       → the full stack (everything)
STACK ?= base
ifeq ($(filter $(STACK),base extended),)
$(error Invalid STACK '$(STACK)'. Use STACK=base or STACK=extended)
endif

# Service groups for `docker-up`. The base group is always launched; the
# extended group is appended only when STACK=extended.
DOCKER_BASE_SERVICES := postgres-up keycloak-up seaweedfs-up opensearch-up temporal-up
ifeq ($(DOCKER_ENV),swift)
DOCKER_BASE_SERVICES += openfga-up
endif
DOCKER_EXTENDED_SERVICES := clickhouse-up langfuse-up prometheus-up grafana-up
ifeq ($(STACK),extended)
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES) $(DOCKER_EXTENDED_SERVICES)
else
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES)
endif

# Application data projects. Shared Keycloak has its own persistent PostgreSQL
# and remains running when either application's data stack is stopped or wiped.
DOCKER_REST_PROJECTS_BASE := seaweedfs opensearch temporal
ifeq ($(DOCKER_ENV),swift)
DOCKER_REST_PROJECTS_BASE += openfga
endif
DOCKER_REST_PROJECTS_EXTENDED := clickhouse langfuse prometheus grafana
ifeq ($(STACK),extended)
DOCKER_REST_PROJECTS := $(DOCKER_REST_PROJECTS_BASE) $(DOCKER_REST_PROJECTS_EXTENDED)
else
DOCKER_REST_PROJECTS := $(DOCKER_REST_PROJECTS_BASE)
endif

# `docker-stop` ignores STACK and stops every project, mirroring `all-down`:
# stopping something that is already stopped is free, and a half-stopped stack
# is worse than an over-stopped one.
DOCKER_ALL_PROJECTS := postgres $(DOCKER_REST_PROJECTS_BASE) $(DOCKER_REST_PROJECTS_EXTENDED)

##@ Help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1mAvailable targets:\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Local k3d infrastructure
K3D_KUBECTL := kubectl --context k3d-fred
# Carry the host trust bundle into the cluster (corporate TLS inspection), when there is one.
K3D_CA_BUNDLE := $(firstword $(wildcard /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt))
K3D_CA_VOLUMES := $(if $(K3D_CA_BUNDLE),--volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@server:* --volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@agent:*)
K3D_VALUES := $(addprefix --values ,$(abspath $(VALUES)))

k3d-up: ## Create the cluster if needed and prepare the infrastructure for every Fred release line; no application deployment
	@if k3d cluster get fred >/dev/null 2>&1; then k3d cluster start fred; else k3d cluster create --config k3d/cluster.yaml $(K3D_CA_VOLUMES); fi
	@if $(K3D_KUBECTL) get namespace fred >/dev/null 2>&1; then \
	  echo 'This cluster has the former layout (namespace fred), and its data cannot move to fred-infra. Save what you need, then make k3d-wipe and make k3d-up.' >&2; exit 1; \
	fi
	helmfile sync $(K3D_VALUES)
	@echo 'Infrastructure ready in namespace fred-infra. Deploy an application: make k3d-app FRED=swift|weaver APP=fred [DIR=... | RELEASE=...]'

k3d-validate: ## Render the infrastructure; no cluster changes
	helm lint k3d
	helmfile template $(K3D_VALUES) >/dev/null
	@echo 'Infrastructure rendered. No cluster changes.'

k3d-start: ## Resume the existing cluster; preserve data
	k3d cluster start fred

k3d-stop: ## Stop the cluster; preserve data
	k3d cluster stop fred

k3d-status: ## Show the infrastructure and Fred release line namespaces
	@for namespace in $$($(K3D_KUBECTL) get namespace -o name | sed -n 's#^namespace/\(fred-.*\)#\1#p'); do \
	  echo "== $$namespace"; $(K3D_KUBECTL) -n "$$namespace" get pods,svc; \
	done

k3d-health: ## Inspect the collected logs, events and health
	@bin/k3d-observe health

k3d-wipe: ## DELETE cluster fred and ALL its data; checkouts remain untouched
	k3d cluster delete fred
	rm -rf .cache/k3d-apps

##@ k3d applications (separate from infrastructure)
k3d-app: ## Deploy one application: FRED=swift|weaver APP=fred DIR=/path/to/checkout (or RELEASE=version)
	@bin/k3d-app sync

k3d-app-validate: ## Render one application: FRED=swift|weaver APP=fred DIR=/path/to/checkout; no deployment
	@bin/k3d-app template

k3d-app-uninstall: ## Uninstall one application: FRED=swift|weaver APP=fred
	@bin/k3d-app destroy

# Retired commands fail; they are not aliases for another configuration surface.
k3d-%:
	@echo 'Removed command. Use make k3d-up, or make k3d-app FRED=swift|weaver APP=...; see make help.' >&2
	@exit 2

##@ Docker Compose: Swift or Weaver data on the usual ports
docker-up docker-start docker-stop preflight-check: export STACK := $(STACK)
docker-env: ## Show the selected Docker environment and its connection endpoints
	@printf 'DOCKER_ENV=%s\nEnv file: %s\nNetwork: %s\nProject prefix: %s\n' "$(DOCKER_ENV)" "$(DOCKER_ENV_FILE)" "$(DOCKER_NETWORK_NAME)" "$(DOCKER_PROJECT_PREFIX)"
	@printf 'PostgreSQL: localhost:5432\nKeycloak: http://app-keycloak:8080\nS3: http://localhost:8333\nOpenSearch: https://localhost:9200\nTemporal: localhost:7233\n'
ifeq ($(DOCKER_ENV),swift)
	@printf 'OpenFGA: %s\n' "$(DOCKER_OPENFGA_URL)"
endif
	@printf 'Browser DNS (/etc/hosts if needed): 127.0.0.1 app-keycloak\n'
	@printf 'Shared authentication: keycloak (app-keycloak), database in keycloak_vol-keycloak-postgres-data\n'

docker-config: env-setup shared-env-setup ## Render one Compose project as JSON without launching it (SVC=postgres)
	@test -n "$(filter $(SVC),keycloak $(DOCKER_ALL_PROJECTS))" || { echo "Use SVC=<project>: keycloak $(DOCKER_ALL_PROJECTS)" >&2; exit 1; }
ifeq ($(SVC),keycloak)
	@$(DOCKER_SHARED_COMPOSE_BASE)keycloak.yml -p keycloak config --format json
else
	@$(DOCKER_COMPOSE_BASE)$(SVC).yml -p $(DOCKER_PROJECT_PREFIX)$(SVC) config --format json
endif

# Explicit launchers keep day-to-day commands short. The common lifecycle
# targets above and below remain available with DOCKER_ENV=weaver as well.
docker-weaver-up: ## Switch to Weaver's data on the usual ports, keeping shared Keycloak (STACK=extended for all services)
	@$(MAKE) DOCKER_ENV=weaver docker-up

docker-weaver-start: ## Switch to and resume Weaver containers and their existing data
	@$(MAKE) DOCKER_ENV=weaver docker-start

docker-weaver-stop: ## Stop Weaver while keeping its containers and data
	@$(MAKE) DOCKER_ENV=weaver docker-stop

docker-weaver-down: ## Remove Weaver containers, preserving its volumes
	@$(MAKE) DOCKER_ENV=weaver docker-down

docker-weaver-wipe: ## Delete only Weaver containers and volumes
	@$(MAKE) DOCKER_ENV=weaver docker-wipe

docker-weaver-env: ## Show Weaver endpoints and browser DNS setup
	@$(MAKE) DOCKER_ENV=weaver docker-env

.PHONY: docker-env docker-config docker-prepare shared-env-setup docker-weaver-up docker-weaver-start docker-weaver-stop docker-weaver-down docker-weaver-wipe docker-weaver-env

network-create:
	@docker network inspect "$(DOCKER_NETWORK_NAME)" >/dev/null 2>&1 || \
		docker network create "$(DOCKER_NETWORK_NAME)" --driver bridge

env-setup:
	@test -f "$(DOCKER_ENV_FILE)" || cp -n docker/.env.template "$(DOCKER_ENV_FILE)"

shared-env-setup:
	@test -f "$(DOCKER_SHARED_ENV_FILE)" || cp -n docker/.env.template "$(DOCKER_SHARED_ENV_FILE)"

# Initialize/migrate shared authentication before stopping the old data stack.
# Migration may need the legacy Swift PostgreSQL just once to copy its realm.
docker-prepare: keycloak-up env-setup
	@$(MAKE) DOCKER_ENV=$(if $(filter weaver,$(DOCKER_ENV)),swift,weaver) docker-stop

keycloak-post-install:
	@echo "Running Keycloak post-install..."
	$(DOCKER_KEYCLOAK_HELPER_ENV) bash docker/keycloak/keycloak-post-install.sh

postgres-up: docker-prepare
	@echo "Launching PostgreSQL..."
	$(DOCKER_COMPOSE_BASE)postgres.yml -p $(DOCKER_PROJECT_PREFIX)postgres up -d --wait postgres
	$(DOCKER_COMPOSE_BASE)postgres.yml -p $(DOCKER_PROJECT_PREFIX)postgres up -d --no-deps --force-recreate postgres-post-install-job
	@echo "Waiting for PostgreSQL post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait $(DOCKER_CONTAINER_PREFIX)app-postgres-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "PostgreSQL post-install job failed (exit $$rc). Showing logs:"; \
			docker logs $(DOCKER_CONTAINER_PREFIX)app-postgres-post-install-job || true; \
			exit 1; \
		fi

mock-oidc-up: ## Start the opt-in local generic OIDC test provider
	docker compose -f docker/docker-compose-mock-oidc.yml -p mock-oidc up -d

mock-oidc-down: ## Stop the local generic OIDC test provider
	docker compose -f docker/docker-compose-mock-oidc.yml -p mock-oidc down

keycloak-generic-oidc: ## Opt in to generic OIDC token claims on the local Keycloak realm
	$(DOCKER_KEYCLOAK_HELPER_ENV) STRICT="$(STRICT)" bash docker/keycloak/generic-oidc-profile.sh apply

keycloak-generic-oidc-revert: ## Restore the local Keycloak baseline claims and admin roles
	$(DOCKER_KEYCLOAK_HELPER_ENV) bash docker/keycloak/generic-oidc-profile.sh revert

keycloak-up: network-create shared-env-setup
	@echo "Ensuring shared Keycloak and its database are running..."
	DOCKER_SHARED_ENV_FILE="$(DOCKER_SHARED_ENV_FILE)" bash docker/keycloak/up-shared.sh

seaweedfs-up: postgres-up
	@echo "Launching SeaweedFS..."
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p $(DOCKER_PROJECT_PREFIX)seaweedfs up -d
	@echo "Waiting for SeaweedFS post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait $(DOCKER_CONTAINER_PREFIX)app-seaweedfs-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "SeaweedFS post-install job failed (exit $$rc). Showing logs:"; \
			docker logs $(DOCKER_CONTAINER_PREFIX)app-seaweedfs-post-install-job || true; \
			exit 1; \
		fi

opensearch-up: postgres-up
	@echo "Launching OpenSearch..."
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p $(DOCKER_PROJECT_PREFIX)opensearch up -d

clickhouse-up: docker-prepare
	@echo "Launching ClickHouse..."
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p $(DOCKER_PROJECT_PREFIX)clickhouse up -d
	@echo "Waiting for ClickHouse post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait $(DOCKER_CONTAINER_PREFIX)app-clickhouse-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "ClickHouse post-install job failed (exit $$rc). Showing logs:"; \
			docker logs $(DOCKER_CONTAINER_PREFIX)app-clickhouse-post-install-job || true; \
			exit 1; \
		fi

langfuse-up: postgres-up clickhouse-up
	@echo "Launching Langfuse..."
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p $(DOCKER_PROJECT_PREFIX)langfuse up -d

prometheus-up: docker-prepare
	@echo "Launching Prometheus..."
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p $(DOCKER_PROJECT_PREFIX)prometheus up -d

grafana-up: prometheus-up
	@echo "Launching Grafana..."
	$(DOCKER_COMPOSE_BASE)grafana.yml -p $(DOCKER_PROJECT_PREFIX)grafana up -d

openfga-post-install:
	@echo "Running OpenFGA post-install..."
	$(DOCKER_HELPER_ENV) bash docker/openfga/openfga-post-install.sh

openfga-up: postgres-up
	@echo "Launching OpenFGA..."
	$(DOCKER_COMPOSE_BASE)openfga.yml -p $(DOCKER_PROJECT_PREFIX)openfga up -d
	$(MAKE) openfga-post-install

temporal-up: postgres-up
	@echo "Launching Temporal..."
	$(DOCKER_COMPOSE_BASE)temporal.yml -p $(DOCKER_PROJECT_PREFIX)temporal up -d

preflight-check:
	@echo "Running FRED preflight..."
	$(DOCKER_HELPER_ENV) bash bin/fred-preflight.sh

docker-up: $(DOCKER_UP_SERVICES) ## Switch to the selected data stack on the usual ports, keeping shared authentication
ifeq ($(DOCKER_ENV),weaver)
	$(MAKE) keycloak-post-install KEYCLOAK_FORCE_RELOGIN=false
endif
	$(MAKE) preflight-check
ifeq ($(DOCKER_ENV),weaver)
	@echo 'Backing services ready. Run Fred: make docker-app FRED=weaver APP=fred DIR=/path/to/fred [KEY_FILE=/path/to/key-file]'
else
	@echo 'Swift backing services ready. Run make run in the Swift checkout.'
endif

docker-app: ## Run Fred from a checkout on the host: FRED=weaver APP=fred DIR=/path/to/fred [KEY_FILE=...]
	@bin/docker-app

# Resume an existing stack — after a reboot, a Docker daemon restart, or
# `make docker-stop`. Unlike `docker-up` this recreates nothing and re-runs no
# post-install job, so realm/volume state is left exactly as it was.
# Keycloak must answer OIDC discovery before opensearch-dashboards boots, or
# the dashboards security plugin exits with "Failed when trying to obtain the
# endpoints from your IdP".
# Start the persistent containers directly: Compose start can also launch their
# completed dependency jobs even when only persistent services are requested.
docker-start: docker-prepare ## Switch to and resume the existing data stack (no data-container recreate or re-provision)
	@set -uo pipefail; \
		start_project() { \
			local project="$$1" name policy containers=(); \
			while IFS= read -r name; do \
				policy="$$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$$name")"; \
				[ "$$policy" != unless-stopped ] || containers+=("$$name"); \
			done < <(docker ps -a --filter "label=com.docker.compose.project=$(DOCKER_PROJECT_PREFIX)$$project" --format '{{.Names}}'); \
			[ "$${#containers[@]}" -gt 0 ] || return 0; \
			docker start "$${containers[@]}" >/dev/null 2>&1 || true; \
		}; \
		await() { \
			name="$$1"; tries=90; state=""; \
			for _ in $$(seq 1 $$tries); do \
				state="$$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$$name" 2>/dev/null)" || { \
					echo "  $$name: absent — run 'make docker-up' to create it"; return 0; }; \
				case "$$state" in \
					healthy|running) echo "  $$name: $$state"; return 0;; \
					exited|dead) echo "  $$name: $$state — 'docker logs $$name' for why"; return 1;; \
				esac; \
				sleep 2; \
			done; \
			echo "  $$name: still '$$state' after $$((tries * 2))s"; return 1; \
		}; \
		await_project() { \
			rc=0; \
			for name in $$(docker ps -a --filter "label=com.docker.compose.project=$(DOCKER_PROJECT_PREFIX)$$1" --format '{{.Names}}'); do \
				case "$$name" in *-install-job|*-migrate|*-admin-tools) continue;; esac; \
				await "$$name" || rc=1; \
			done; \
			return $$rc; \
		}; \
		echo "Resuming PostgreSQL..."; start_project postgres; await $(DOCKER_CONTAINER_PREFIX)app-postgres || exit 1; \
		echo "Waiting for shared Keycloak..."; await app-keycloak || exit 1; \
		echo "Resuming $(DOCKER_REST_PROJECTS)..."; \
		for project in $(DOCKER_REST_PROJECTS); do start_project "$$project"; done; \
		overall=0; \
		for project in $(DOCKER_REST_PROJECTS); do await_project "$$project" || overall=1; done; \
		if [ "$$overall" = 0 ]; then echo "Docker stack is up."; else \
			echo "Docker stack is up, but some services did not come back — see above."; fi; \
		exit $$overall

# Stop without deleting: the counterpart to `docker-start`. `docker-down`
# removes the containers, which would force a full re-provision on the next
# start; this keeps them so `docker-start` can resume them.
docker-stop: env-setup ## Stop the selected data stack; keep its containers and shared authentication
	@echo "Stopping Docker stack services (containers kept)..."
	@for project in $(DOCKER_ALL_PROJECTS); do \
		$(DOCKER_COMPOSE_BASE)$$project.yml -p $(DOCKER_PROJECT_PREFIX)$$project stop 2>/dev/null || true; \
	done

docker-down: all-down ## Remove the selected data containers; keep volumes and shared authentication

all-down: env-setup
	@echo "Stopping Docker stack services..."
	$(DOCKER_COMPOSE_BASE)grafana.yml -p $(DOCKER_PROJECT_PREFIX)grafana down
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p $(DOCKER_PROJECT_PREFIX)prometheus down
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p $(DOCKER_PROJECT_PREFIX)langfuse down
	$(DOCKER_COMPOSE_BASE)temporal.yml -p $(DOCKER_PROJECT_PREFIX)temporal down
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p $(DOCKER_PROJECT_PREFIX)clickhouse down
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p $(DOCKER_PROJECT_PREFIX)opensearch down
ifeq ($(DOCKER_ENV),swift)
	$(DOCKER_COMPOSE_BASE)openfga.yml -p $(DOCKER_PROJECT_PREFIX)openfga down
endif
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p $(DOCKER_PROJECT_PREFIX)seaweedfs down
	$(DOCKER_COMPOSE_BASE)postgres.yml -p $(DOCKER_PROJECT_PREFIX)postgres down

docker-wipe: all-down ## Delete selected data containers and volumes; keep shared Keycloak and its database
	@echo -e "\n--- WIPE IN PROGRESS ---"
	$(DOCKER_COMPOSE_BASE)grafana.yml -p $(DOCKER_PROJECT_PREFIX)grafana down -v
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p $(DOCKER_PROJECT_PREFIX)prometheus down -v
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p $(DOCKER_PROJECT_PREFIX)langfuse down -v
	$(DOCKER_COMPOSE_BASE)temporal.yml -p $(DOCKER_PROJECT_PREFIX)temporal down -v
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p $(DOCKER_PROJECT_PREFIX)clickhouse down -v
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p $(DOCKER_PROJECT_PREFIX)opensearch down -v
ifeq ($(DOCKER_ENV),swift)
	$(DOCKER_COMPOSE_BASE)openfga.yml -p $(DOCKER_PROJECT_PREFIX)openfga down -v
endif
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p $(DOCKER_PROJECT_PREFIX)seaweedfs down -v
	$(DOCKER_COMPOSE_BASE)postgres.yml -p $(DOCKER_PROJECT_PREFIX)postgres down -v
	@echo -e "\n--- WIPE COMPLETE ---"

docker-destroy: all-down ## Delete selected data containers/volumes and their images; keep shared authentication/network
	@echo -e "\n--- destroy IN PROGRESS ---"
	$(DOCKER_COMPOSE_BASE)grafana.yml -p $(DOCKER_PROJECT_PREFIX)grafana down -v --rmi all
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p $(DOCKER_PROJECT_PREFIX)prometheus down -v --rmi all
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p $(DOCKER_PROJECT_PREFIX)langfuse down -v --rmi all
	$(DOCKER_COMPOSE_BASE)temporal.yml -p $(DOCKER_PROJECT_PREFIX)temporal down -v --rmi all
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p $(DOCKER_PROJECT_PREFIX)clickhouse down -v --rmi all
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p $(DOCKER_PROJECT_PREFIX)opensearch down -v --rmi all
ifeq ($(DOCKER_ENV),swift)
	$(DOCKER_COMPOSE_BASE)openfga.yml -p $(DOCKER_PROJECT_PREFIX)openfga down -v --rmi all
endif
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p $(DOCKER_PROJECT_PREFIX)seaweedfs down -v --rmi all
	$(DOCKER_COMPOSE_BASE)postgres.yml -p $(DOCKER_PROJECT_PREFIX)postgres down -v
	@echo -e "\n--- destroy COMPLETE ---"

keycloak-token-short: ## Local Docker: use browser 60s and agentic M2M 120s access tokens
	$(DOCKER_KEYCLOAK_HELPER_ENV) bash local-testing/scripts/keycloak-token-lifetime.sh short

keycloak-token-normal: ## Local Docker: set browser and agentic M2M access tokens to 300s
	$(DOCKER_KEYCLOAK_HELPER_ENV) bash local-testing/scripts/keycloak-token-lifetime.sh normal

keycloak-token-status: ## Local Docker: show browser and agentic M2M access token lifetimes
	$(DOCKER_KEYCLOAK_HELPER_ENV) bash local-testing/scripts/keycloak-token-lifetime.sh status

##@ Checkpoints
checkpoint-save: ## Save current Docker stack state as a named checkpoint (NAME=<name> required)
	@test -n "$(NAME)" || (echo "ERROR: NAME is required. Usage: make checkpoint-save NAME=<name>"; exit 1)
	@bash bin/checkpoint-save.sh "$(NAME)"

checkpoint-restore: ## Restore a named checkpoint — run make docker-up afterwards (NAME=<name> required)
	@test -n "$(NAME)" || (echo "ERROR: NAME is required. Usage: make checkpoint-restore NAME=<name>"; exit 1)
	@bash bin/checkpoint-restore.sh "$(NAME)"

docker-restart-from-checkpoint: ## Restore a checkpoint and restart the full Docker stack (NAME=<name> required)
	@test -n "$(NAME)" || (echo "ERROR: NAME is required. Usage: make docker-restart-from-checkpoint NAME=<name>"; exit 1)
	@bash bin/checkpoint-restore.sh "$(NAME)"
	$(MAKE) docker-up

checkpoint-list: ## List all saved checkpoints
	@bash bin/checkpoint-list.sh

checkpoint-delete: ## Delete a named checkpoint (NAME=<name> required)
	@test -n "$(NAME)" || (echo "ERROR: NAME is required. Usage: make checkpoint-delete NAME=<name>"; exit 1)
	@test -d "checkpoints/$(NAME)" || (echo "ERROR: Checkpoint '$(NAME)' not found in checkpoints/"; exit 1)
	rm -rf "checkpoints/$(NAME)"
	@echo "Checkpoint '$(NAME)' deleted."

##@ Validation
# The auth/isolation validation harness (pytest scenarios, black-box
# release gate) lives in `fred`'s own `validation/` now - run it there:
#   cd ../fred && make validation-report
# This repo only ships infrastructure; it keeps just the pure-infrastructure
# regression guard below.

check-pure-infrastructure: ## Offline guard: fail if a tracked artifact carries business/demo data, or dangling local validation/ wiring
	@echo "▶ Keycloak realm templates must ship zero users/groups and only the app:service_agent client role"
	@for template in docker/keycloak/app-realm.json.template k3d/files/keycloak/app-realm.json.template; do \
	  users="$$(jq '.users | length' "$$template")"; \
	  groups="$$(jq '.groups | length' "$$template")"; \
	  extra_roles="$$(jq -r '[(.roles.client.app // [])[].name] - ["service_agent"] | length' "$$template")"; \
	  has_service_agent="$$(jq -r '([(.roles.client.app // [])[].name] | index("service_agent")) != null' "$$template")"; \
	  [ "$$users" = "0" ] || { echo "✗ $$template: .users is not empty ($$users)"; exit 1; }; \
	  [ "$$groups" = "0" ] || { echo "✗ $$template: .groups is not empty ($$groups)"; exit 1; }; \
	  [ "$$extra_roles" = "0" ] || { echo "✗ $$template: .roles.client.app carries a role other than service_agent (legacy admin/editor/viewer?)"; exit 1; }; \
	  [ "$$has_service_agent" = "true" ] || { echo "✗ $$template: app:service_agent client role is missing"; exit 1; }; \
	done
	@echo "✓ docker and k3d realm templates: zero users, zero groups, only app:service_agent"
	@echo "▶ fred-preflight.sh must not require legacy app:admin/editor/viewer roles"
	@! grep -qE '^REQUIRED_APP_CLIENT_ROLES=' bin/fred-preflight.sh || { echo "✗ bin/fred-preflight.sh reintroduces REQUIRED_APP_CLIENT_ROLES - admin/editor/viewer must never be required, only flagged as legacy"; exit 1; }
	@grep -qE '^LEGACY_APP_CLIENT_ROLES=\(admin editor viewer\)' bin/fred-preflight.sh || { echo "✗ bin/fred-preflight.sh must flag admin/editor/viewer as legacy via LEGACY_APP_CLIENT_ROLES"; exit 1; }
	@grep -qE '^EXPECTED_SERVICE_APP_ROLE="service_agent"' bin/fred-preflight.sh || { echo "✗ bin/fred-preflight.sh must still require app:service_agent via EXPECTED_SERVICE_APP_ROLE"; exit 1; }
	@echo "✓ fred-preflight.sh requires service_agent and forbids admin/editor/viewer as legacy"
	@echo "▶ no Makefile wiring left pointing at the removed local validation/ harness"
	@! grep -qE '^(VALIDATION_DIR|VALIDATION_VENV|VALIDATION_REPORT|VALIDATION_JUNIT_XML)[[:space:]]*\??=|^(validation-unit-tests|validate-auth-isolation-localhost|validate-auth-isolation-k3d|validation-report):' Makefile || { echo "✗ Makefile still defines local validation/ harness targets/vars - that harness moved to fred/validation"; exit 1; }
	@echo "✓ no local validation/ harness wiring left in the Makefile"
	@echo "✓ check-pure-infrastructure passed"

BRANCH ?= swift
ecosystem-audit: ## Do the sibling checkouts agree on Fred's libraries? Branch, constraints, locks, npm: make ecosystem-audit [BRANCH=swift]
	@bin/ecosystem-audit --branch "$(BRANCH)" --fetch

.PHONY: docker-app help network-create env-setup keycloak-post-install postgres-up keycloak-up seaweedfs-up opensearch-up clickhouse-up langfuse-up prometheus-up grafana-up temporal-up preflight-check docker-up docker-start docker-stop docker-down all-down docker-wipe docker-destroy checkpoint-save checkpoint-restore docker-restart-from-checkpoint checkpoint-list checkpoint-delete check-pure-infrastructure ecosystem-audit keycloak-token-short keycloak-token-normal keycloak-token-status

##@ Optional ZITADEL identity-provider test
ZITADEL_COMPOSE = docker compose --env-file docker/zitadel/.env -f docker/zitadel/compose.yaml -p fred-zitadel
FRED_IDP_CONFIG_DIR ?= /tmp/fred-idp-tests/zitadel

.PHONY: zitadel-env zitadel-up zitadel-down zitadel-status zitadel-configure
zitadel-env: ## Generate ignored local ZITADEL credentials once
	python3 docker/zitadel/env.py

zitadel-up: zitadel-env ## Start isolated ZITADEL on localhost:8091 (keeps Keycloak)
	$(ZITADEL_COMPOSE) up -d --wait --wait-timeout 180

zitadel-down: ## Stop ZITADEL, preserving its users and volumes
	$(ZITADEL_COMPOSE) down

zitadel-status: ## Show ZITADEL containers
	$(ZITADEL_COMPOSE) ps

zitadel-configure: zitadel-up ## Provision SPA/services and generate complete Fred configs
	@set -eu; umask 077; mkdir -p docker/zitadel/state; $(ZITADEL_COMPOSE) cp api:/bootstrap/operator.pat docker/zitadel/state/operator.pat; chmod 600 docker/zitadel/state/operator.pat
	/usr/bin/python3 docker/zitadel/provision.py --fred-root "$(SWIFT_SRC)" --output-dir "$(FRED_IDP_CONFIG_DIR)"

.PHONY: k3d-app k3d-app-validate k3d-app-uninstall k3d-up k3d-validate k3d-start k3d-stop k3d-status k3d-health k3d-wipe
