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

DOCKER_COMPOSE_BASE := docker compose -f docker/docker-compose-

# `make docker-up` prepares the backing services of Fred Weaver; `make docker-app` runs Fred
# on the host from a Weaver checkout, as `make k3d-up` and `make k3d-app` on k3d. One mode: a
# fresh, empty deployment (empty Keycloak realm: clients and service accounts only, no
# demo users or groups). The database `fred_weaver` is created empty: its SQL owners and
# schemas are Fred's bootstrap, as on k3d. Swift on Docker Compose stays on branch swift.

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
DOCKER_EXTENDED_SERVICES := clickhouse-up langfuse-up prometheus-up grafana-up
ifeq ($(STACK),extended)
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES) $(DOCKER_EXTENDED_SERVICES)
else
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES)
endif

# Compose projects for `docker-start` / `docker-stop`, in dependency order.
# postgres and keycloak are started first and awaited individually, so they are
# not repeated here.
DOCKER_REST_PROJECTS_BASE := seaweedfs opensearch temporal
DOCKER_REST_PROJECTS_EXTENDED := clickhouse langfuse prometheus grafana
ifeq ($(STACK),extended)
DOCKER_REST_PROJECTS := $(DOCKER_REST_PROJECTS_BASE) $(DOCKER_REST_PROJECTS_EXTENDED)
else
DOCKER_REST_PROJECTS := $(DOCKER_REST_PROJECTS_BASE)
endif

# `docker-stop` ignores STACK and stops every project, mirroring `all-down`:
# stopping something that is already stopped is free, and a half-stopped stack
# is worse than an over-stopped one.
DOCKER_ALL_PROJECTS := postgres keycloak $(DOCKER_REST_PROJECTS_BASE) $(DOCKER_REST_PROJECTS_EXTENDED)

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

##@ Docker Compose: backing services of Fred Weaver, run on the host
docker-up docker-start docker-stop preflight-check: export STACK := $(STACK)
network-create:
	@echo "Creating 'fred-shared-network'..."
	docker network create fred-shared-network --driver bridge || echo "Network already exists or error occurred."

env-setup:
	@echo "Setting up .env file..."
	cp docker/.env.template docker/.env
	@echo "NOTE: Remember to customize docker/.env if needed."

keycloak-post-install:
	@echo "Running Keycloak post-install..."
	bash docker/keycloak/keycloak-post-install.sh

postgres-up: network-create env-setup
	@echo "Launching PostgreSQL..."
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres up -d --wait postgres
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres up -d --no-deps --force-recreate postgres-post-install-job
	@echo "Waiting for PostgreSQL post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait app-postgres-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "PostgreSQL post-install job failed (exit $$rc). Showing logs:"; \
			docker logs app-postgres-post-install-job || true; \
			exit 1; \
		fi

mock-oidc-up: ## Start the opt-in local generic OIDC test provider
	docker compose -f docker/docker-compose-mock-oidc.yml -p mock-oidc up -d

mock-oidc-down: ## Stop the local generic OIDC test provider
	docker compose -f docker/docker-compose-mock-oidc.yml -p mock-oidc down

keycloak-generic-oidc: ## Opt in to generic OIDC token claims on the local Keycloak realm
	STRICT="$(STRICT)" bash docker/keycloak/generic-oidc-profile.sh apply

keycloak-generic-oidc-revert: ## Restore the local Keycloak baseline claims and admin roles
	bash docker/keycloak/generic-oidc-profile.sh revert

keycloak-up: postgres-up
	@echo "Launching Keycloak..."
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak up -d
	$(MAKE) keycloak-post-install

seaweedfs-up: keycloak-up
	@echo "Launching SeaweedFS..."
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p seaweedfs up -d
	@echo "Waiting for SeaweedFS post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait app-seaweedfs-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "SeaweedFS post-install job failed (exit $$rc). Showing logs:"; \
			docker logs app-seaweedfs-post-install-job || true; \
			exit 1; \
		fi

opensearch-up: keycloak-up
	@echo "Launching OpenSearch..."
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch up -d

clickhouse-up: network-create env-setup
	@echo "Launching ClickHouse..."
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p clickhouse up -d
	@echo "Waiting for ClickHouse post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait app-clickhouse-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "ClickHouse post-install job failed (exit $$rc). Showing logs:"; \
			docker logs app-clickhouse-post-install-job || true; \
			exit 1; \
		fi

langfuse-up: postgres-up clickhouse-up
	@echo "Launching Langfuse..."
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p langfuse up -d

prometheus-up: network-create env-setup
	@echo "Launching Prometheus..."
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p prometheus up -d

grafana-up: prometheus-up
	@echo "Launching Grafana..."
	$(DOCKER_COMPOSE_BASE)grafana.yml -p grafana up -d

temporal-up: keycloak-up
	@echo "Launching Temporal..."
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal up -d

preflight-check:
	@echo "Running FRED preflight..."
	bash bin/fred-preflight.sh

docker-up: $(DOCKER_UP_SERVICES) ## Launch the backing services of Fred Weaver (empty realm and database); no application
	$(MAKE) preflight-check
	@echo 'Backing services ready. Run Fred: make docker-app FRED=weaver APP=fred DIR=/path/to/fred [KEY_FILE=/path/to/key-file]'

docker-app: ## Run Fred from a checkout on the host: FRED=weaver APP=fred DIR=/path/to/fred [KEY_FILE=...]
	@bin/docker-app

# Resume an existing stack — after a reboot, a Docker daemon restart, or
# `make docker-stop`. Unlike `docker-up` this recreates nothing and re-runs no
# post-install job, so realm/volume state is left exactly as it was.
# Keycloak must answer OIDC discovery before opensearch-dashboards boots, or
# the dashboards security plugin exits with "Failed when trying to obtain the
# endpoints from your IdP".
docker-start: ## Resume the existing Docker stack in dependency order (no recreate, no re-provision)
	@set -uo pipefail; \
		compose_start() { $(DOCKER_COMPOSE_BASE)$$1.yml -p $$1 start >/dev/null 2>&1 || true; }; \
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
			for name in $$(docker ps -a --filter "label=com.docker.compose.project=$$1" --format '{{.Names}}'); do \
				case "$$name" in *-install-job|*-migrate|*-admin-tools) continue;; esac; \
				await "$$name" || rc=1; \
			done; \
			return $$rc; \
		}; \
		echo "Resuming PostgreSQL..."; compose_start postgres; await app-postgres || exit 1; \
		echo "Resuming Keycloak..."; compose_start keycloak; await app-keycloak || exit 1; \
		echo "Resuming $(DOCKER_REST_PROJECTS)..."; \
		for project in $(DOCKER_REST_PROJECTS); do compose_start "$$project"; done; \
		overall=0; \
		for project in $(DOCKER_REST_PROJECTS); do await_project "$$project" || overall=1; done; \
		if [ "$$overall" = 0 ]; then echo "Docker stack is up."; else \
			echo "Docker stack is up, but some services did not come back — see above."; fi; \
		exit $$overall

# Stop without deleting: the counterpart to `docker-start`. `docker-down`
# removes the containers, which would force a full re-provision on the next
# start; this keeps them so `docker-start` can resume them.
docker-stop: ## Stop the Docker stack but keep the containers (resume with `docker-start`)
	@echo "Stopping Docker stack services (containers kept)..."
	@for project in $(DOCKER_ALL_PROJECTS); do \
		$(DOCKER_COMPOSE_BASE)$$project.yml -p $$project stop 2>/dev/null || true; \
	done

docker-down: all-down ## Stop the Docker stack

all-down:
	@echo "Stopping Docker stack services..."
	$(DOCKER_COMPOSE_BASE)grafana.yml -p grafana down
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p prometheus down
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p langfuse down
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p clickhouse down
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p seaweedfs down
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres down

docker-wipe: all-down ## Stop Docker stack, delete containers & volumes
	@echo -e "\n--- WIPE IN PROGRESS ---"
	$(DOCKER_COMPOSE_BASE)grafana.yml -p grafana down -v
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p prometheus down -v
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p langfuse down -v
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down -v
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p clickhouse down -v
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down -v
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p seaweedfs down -v
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down -v
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres down -v
	@echo -e "\n--- WIPE COMPLETE ---"

docker-destroy: all-down ## Stop Docker stack, delete containers/volumes/network AND remove images
	@echo -e "\n--- destroy IN PROGRESS ---"
	$(DOCKER_COMPOSE_BASE)grafana.yml -p grafana down -v --rmi all
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p prometheus down -v --rmi all
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p langfuse down -v --rmi all
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down -v --rmi all
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p clickhouse down -v --rmi all
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down -v --rmi all
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p seaweedfs down -v --rmi all
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down -v --rmi all
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres down -v --rmi all
	docker network rm fred-shared-network || true
	@echo -e "\n--- destroy COMPLETE ---"

keycloak-token-short: ## Local Docker: use browser 60s and agentic M2M 120s access tokens
	bash local-testing/scripts/keycloak-token-lifetime.sh short

keycloak-token-normal: ## Local Docker: set browser and agentic M2M access tokens to 300s
	bash local-testing/scripts/keycloak-token-lifetime.sh normal

keycloak-token-status: ## Local Docker: show browser and agentic M2M access token lifetimes
	bash local-testing/scripts/keycloak-token-lifetime.sh status

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
