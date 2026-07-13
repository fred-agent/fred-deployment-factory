.DEFAULT_GOAL := help
SHELL := /bin/bash

DOCKER_COMPOSE_BASE := docker compose -f docker-compose/docker-compose-

WITH_KEA ?= false
export WITH_KEA

ifeq ($(WITH_KEA),true)
AUTHZ_MODE ?= kea-legacy
DEFAULT_DEMO_IDENTITY_CONFIG_FILE := $(CURDIR)/config/configuration.kea.yaml
DEFAULT_OPENFGA_MODEL_FILE := $(CURDIR)/docker-compose/openfga/openfga-model.kea.json
else
AUTHZ_MODE ?= swift-clean
DEFAULT_DEMO_IDENTITY_CONFIG_FILE := $(CURDIR)/config/configuration.yaml
DEFAULT_OPENFGA_MODEL_FILE := $(CURDIR)/docker-compose/openfga/openfga-model.json
endif
DEMO_IDENTITY_CONFIG_FILE ?= $(DEFAULT_DEMO_IDENTITY_CONFIG_FILE)
OPENFGA_MODEL_FILE ?= $(DEFAULT_OPENFGA_MODEL_FILE)
export AUTHZ_MODE
export DEMO_IDENTITY_CONFIG_FILE
export OPENFGA_MODEL_FILE

# SEED_DEMO=false brings the stack up EMPTY (the "freshly deployed s3ns" state):
#   - Keycloak realm `app` gets clients + service accounts ONLY (no alice/bob/phil, no demo groups)
#   - Keycloak/OpenFGA post-install seed NO demo users/groups/tuples (store + model still created)
#   - preflight-check is skipped (there are no demo users to verify)
# Postgres `fred_kea` and the buckets come up empty either way. Used by `migration-reset`
# so the identity/data restore populates a genuinely empty target.
SEED_DEMO ?= true
export SEED_DEMO
ifeq ($(SEED_DEMO),false)
KC_REALM_TEMPLATE := app-realm.empty.json.template
DEMO_IDENTITY_CONFIG_FILE := $(CURDIR)/config/configuration.empty.yaml
export KC_REALM_TEMPLATE
export DEMO_IDENTITY_CONFIG_FILE
endif

# STACK selects which services are launched (Docker Compose and Helm):
#   base (default) → minimal stack: drops ClickHouse, Langfuse (+ its Redis),
#                    Prometheus and Grafana
#   extended       → the full stack (everything)
STACK ?= base
export STACK
ifeq ($(filter $(STACK),base extended),)
$(error Invalid STACK '$(STACK)'. Use STACK=base or STACK=extended)
endif

# Service groups for `docker-up`. The base group is always launched; the
# extended group is appended only when STACK=extended.
DOCKER_BASE_SERVICES := postgres-up keycloak-up seaweedfs-up opensearch-up openfga-up temporal-up
DOCKER_EXTENDED_SERVICES := clickhouse-up langfuse-up prometheus-up grafana-up
ifeq ($(STACK),extended)
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES) $(DOCKER_EXTENDED_SERVICES)
else
DOCKER_UP_SERVICES := $(DOCKER_BASE_SERVICES)
endif

K3D_CLUSTER ?= fred
K3D_NAMESPACE ?= fred
HELM_RELEASE ?= fred-stack
HELM_CHART_DIR ?= ./helm/fred-stack
HELM_TIMEOUT ?= 20m
HELM_HISTORY_MAX ?= 10
IMAGE_REGISTRY_HOST ?= registry-1.docker.io
K3D_PREFETCH_IMAGES ?= true
K3D_PREFETCH_SYSTEM_IMAGES ?= true
K3D_IMAGE_IMPORT_MODE ?= tools-node
IMAGE_PULL_RETRIES ?= 3
IMAGE_PULL_RETRY_DELAY ?= 5
K3D_USE_CILIUM ?= false
CILIUM_VERSION ?= 1.16.5
# Mount a host CA bundle into k3d nodes — required in corporate SSL-inspection environments (e.g. Zscaler).
# Set to your system CA bundle, e.g.: K3D_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
K3D_CA_BUNDLE ?=
ifneq ($(K3D_CA_BUNDLE),)
K3D_CA_VOLUME_ARG := --volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@server:* --volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@agent:*
else
K3D_CA_VOLUME_ARG :=
endif

K3D_HOST_PORT_KEYCLOAK ?= 8080
K3D_HOST_PORT_POSTGRES ?= 5432
K3D_HOST_PORT_SEAWEEDFS_S3 ?= 8333
K3D_HOST_PORT_CLICKHOUSE_HTTP ?= 8123
K3D_HOST_PORT_CLICKHOUSE_NATIVE ?= 9002
K3D_HOST_PORT_OPENSEARCH ?= 9200
K3D_HOST_PORT_OPENSEARCH_DASHBOARDS ?= 5601
K3D_HOST_PORT_OPENFGA_HTTP ?= 9080
K3D_HOST_PORT_OPENFGA_GRPC ?= 9081
K3D_HOST_PORT_TEMPORAL_FRONTEND ?= 7233
K3D_HOST_PORT_TEMPORAL_UI ?= 8233
K3D_HOST_PORT_PROMETHEUS ?= 9090
K3D_HOST_PORT_GRAFANA ?= 3002
K3D_HOST_PORT_FRONTEND ?= 8088

K3D_CLUSTER_CREATE_BASE_ARGS := \
	--servers 1 \
	--agents 1 \
	--wait \
	-p "$(K3D_HOST_PORT_POSTGRES):30432@server:0" \
	-p "$(K3D_HOST_PORT_KEYCLOAK):30080@server:0" \
	-p "$(K3D_HOST_PORT_SEAWEEDFS_S3):30833@server:0" \
	-p "$(K3D_HOST_PORT_CLICKHOUSE_HTTP):30823@server:0" \
	-p "$(K3D_HOST_PORT_CLICKHOUSE_NATIVE):30902@server:0" \
	-p "$(K3D_HOST_PORT_OPENSEARCH):30920@server:0" \
	-p "$(K3D_HOST_PORT_OPENSEARCH_DASHBOARDS):30561@server:0" \
	-p "$(K3D_HOST_PORT_OPENFGA_HTTP):30908@server:0" \
	-p "$(K3D_HOST_PORT_OPENFGA_GRPC):30981@server:0" \
	-p "$(K3D_HOST_PORT_TEMPORAL_FRONTEND):30723@server:0" \
	-p "$(K3D_HOST_PORT_TEMPORAL_UI):30233@server:0" \
	-p "$(K3D_HOST_PORT_PROMETHEUS):30090@server:0" \
	-p "$(K3D_HOST_PORT_GRAFANA):30300@server:0" \
	-p "$(K3D_HOST_PORT_FRONTEND):80@server:0"

##@ Help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1mAvailable targets:\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Docker
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

postgres-up: network-create env-setup
	@echo "Launching PostgreSQL..."
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres up -d --force-recreate
	@echo "Waiting for PostgreSQL post-install job..."
	@set -euo pipefail; \
		rc="$$(docker wait app-postgres-post-install-job)"; \
		if [ "$$rc" != "0" ]; then \
			echo "PostgreSQL post-install job failed (exit $$rc). Showing logs:"; \
			docker logs app-postgres-post-install-job || true; \
			exit 1; \
		fi

keycloak-up: postgres-up
	@echo "Launching Keycloak..."
	@if [ "$(SEED_DEMO)" = "false" ]; then \
	  echo "[SEED_DEMO=false] generating empty realm template (clients + service accounts only)..."; \
	  jq '.users |= map(select(.username | startswith("service-account-"))) | .groups = []' \
	    docker-compose/keycloak/app-realm.json.template \
	    > docker-compose/keycloak/app-realm.empty.json.template; \
	fi
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

docker-up: $(DOCKER_UP_SERVICES) ## Launch the Docker stack (default Swift clean authz; WITH_KEA=true for legacy Kea migration rehearsal)
	@echo "Authz mode: $(AUTHZ_MODE)"
	@echo "Demo identity config: $(DEMO_IDENTITY_CONFIG_FILE)"
	@echo "OpenFGA model file: $(OPENFGA_MODEL_FILE)"
	@if [ "$(AUTHZ_MODE)" = "swift-clean" ]; then \
	  echo "Swift clean seed: alice=platform_admin, gabriel=platform_observer, team roles live only in OpenFGA."; \
	else \
	  echo "Kea legacy seed: old app/team roles, intended for migration-script rehearsal."; \
	fi
	@if [ "$(SEED_DEMO)" = "false" ]; then \
	  echo "[SEED_DEMO=false] empty mode — skipping preflight (no demo users to verify)."; \
	else \
	  $(MAKE) preflight-check; \
	fi
	@echo "All Docker stack services are running."

docker-down: all-down ## Stop the Docker stack

all-down:
	@echo "Stopping Docker stack services..."
	$(DOCKER_COMPOSE_BASE)grafana.yml -p grafana down
	$(DOCKER_COMPOSE_BASE)prometheus.yml -p prometheus down
	$(DOCKER_COMPOSE_BASE)langfuse.yml -p langfuse down
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down
	$(DOCKER_COMPOSE_BASE)clickhouse.yml -p clickhouse down
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga down
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
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga down -v
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
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga down -v --rmi all
	$(DOCKER_COMPOSE_BASE)seaweedfs.yml -p seaweedfs down -v --rmi all
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down -v --rmi all
	$(DOCKER_COMPOSE_BASE)postgres.yml -p postgres down -v --rmi all
	docker network rm fred-shared-network || true
	@echo -e "\n--- destroy COMPLETE ---"

##@ k3d
k3d-create: ## Create a local k3d cluster (set K3D_USE_CILIUM=true for air-gap/Cilium policies)
	@set -euo pipefail; \
		c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'; \
		step() { printf "%b[STEP]%b %s\n" "$$c_step" "$$c_reset" "$$1"; }; \
		ok() { printf "%b[OK]%b %s\n" "$$c_ok" "$$c_reset" "$$1"; }; \
		warn() { printf "%b[WARN]%b %s\n" "$$c_warn" "$$c_reset" "$$1"; }; \
		info() { printf "%b[INFO]%b %s\n" "$$c_info" "$$c_reset" "$$1"; }; \
		fail() { local msg="$$1"; local rc="$${2:-1}"; printf "%b[FAIL]%b %s\n" "$$c_err" "$$c_reset" "$$msg"; exit "$$rc"; }; \
		run_step() { local title="$$1"; shift; step "$$title"; if "$$@"; then ok "$$title"; else local rc=$$?; fail "$$title (exit $$rc)" "$$rc"; fi; }; \
	command -v k3d >/dev/null 2>&1 || fail "k3d is required"; \
	if k3d cluster get "$(K3D_CLUSTER)" >/dev/null 2>&1; then \
	  warn "Cluster '$(K3D_CLUSTER)' already exists, skipping creation."; \
	  exit 0; \
	fi; \
	if [ "$(K3D_USE_CILIUM)" = "true" ] || [ "$(K3D_USE_CILIUM)" = "1" ]; then \
	  command -v cilium >/dev/null 2>&1 || fail "cilium CLI is required when K3D_USE_CILIUM=true"; \
	  run_step "Create k3d cluster '$(K3D_CLUSTER)' (Cilium-ready networking)" \
	    k3d cluster create "$(K3D_CLUSTER)" \
	    $(K3D_CLUSTER_CREATE_BASE_ARGS) \
	    $(K3D_CA_VOLUME_ARG) \
	    --k3s-arg '--flannel-backend=none@server:*' \
	    --k3s-arg '--disable-network-policy@server:*'; \
	  run_step "Install Cilium $(CILIUM_VERSION)" cilium install --version "$(CILIUM_VERSION)"; \
	  run_step "Wait for Cilium readiness" cilium status --wait --wait-duration 5m; \
	else \
	  run_step "Create k3d cluster '$(K3D_CLUSTER)' (default k3s networking)" \
	    k3d cluster create "$(K3D_CLUSTER)" \
	    $(K3D_CLUSTER_CREATE_BASE_ARGS) \
	    $(K3D_CA_VOLUME_ARG); \
	fi

k3d-up: k3d-create ## Deploy the full stack into k3d with Helm
	@set -euo pipefail; \
		c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'; \
		step() { printf "%b[STEP]%b %s\n" "$$c_step" "$$c_reset" "$$1"; }; \
		ok() { printf "%b[OK]%b %s\n" "$$c_ok" "$$c_reset" "$$1"; }; \
		warn() { printf "%b[WARN]%b %s\n" "$$c_warn" "$$c_reset" "$$1"; }; \
		info() { printf "%b[INFO]%b %s\n" "$$c_info" "$$c_reset" "$$1"; }; \
		fail() { local msg="$$1"; local rc="$${2:-1}"; printf "%b[FAIL]%b %s\n" "$$c_err" "$$c_reset" "$$msg"; exit "$$rc"; }; \
		run_step() { local title="$$1"; shift; step "$$title"; if "$$@"; then ok "$$title"; else local rc=$$?; fail "$$title (exit $$rc)" "$$rc"; fi; }; \
		run_step_retry() { \
		  local title="$$1"; local retries="$$2"; local delay="$$3"; shift 3; \
		  local attempt=1; \
		  step "$$title"; \
		  while true; do \
		    if "$$@"; then \
		      ok "$$title"; \
		      return 0; \
		    fi; \
		    local rc=$$?; \
		    if [ "$$attempt" -ge "$$retries" ]; then \
		      fail "$$title (exit $$rc after $$attempt attempt(s))" "$$rc"; \
		    fi; \
		    warn "$$title failed (attempt $$attempt/$$retries). Retrying in $${delay}s..."; \
		    sleep "$$delay"; \
		    attempt=$$((attempt + 1)); \
		  done; \
		}; \
		helm_pid=""; \
		on_interrupt() { \
		  warn "Interrupted (Ctrl+C). Stopping running subprocesses..."; \
		  if [ -n "$$helm_pid" ] && kill -0 "$$helm_pid" >/dev/null 2>&1; then \
		    kill "$$helm_pid" >/dev/null 2>&1 || true; \
		    wait "$$helm_pid" >/dev/null 2>&1 || true; \
		  fi; \
		  exit 130; \
		}; \
		trap on_interrupt INT TERM; \
	command -v helm >/dev/null 2>&1 || fail "helm is required"; \
	command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"; \
	command -v docker >/dev/null 2>&1 || fail "docker is required"; \
	command -v k3d >/dev/null 2>&1 || fail "k3d is required"; \
	if docker ps --format '{{.Names}}' | grep -Eq '^k3d-$(K3D_CLUSTER)-server-0$$'; then \
	  info "Cluster '$(K3D_CLUSTER)' is already running."; \
	else \
	  run_step "Start k3d cluster '$(K3D_CLUSTER)'" \
	    k3d cluster start "$(K3D_CLUSTER)"; \
	fi; \
	run_step "Switch kubectl context to k3d-$(K3D_CLUSTER)" \
	  kubectl config use-context "k3d-$(K3D_CLUSTER)"; \
	if [ "$(K3D_PREFETCH_IMAGES)" = "true" ] || [ "$(K3D_PREFETCH_IMAGES)" = "1" ]; then \
	  step "Resolve chart images from $(HELM_CHART_DIR)"; \
	  helm_images=(); \
	  while IFS= read -r image; do \
	    [ -n "$$image" ] && helm_images+=("$$image"); \
	  done < <(helm template "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" --set withKea=$(WITH_KEA) --set stack=$(STACK) | awk '/image:[[:space:]]*/ {print $$2}' | tr -d '"' | sort -u); \
	  if [ "$${#helm_images[@]}" -eq 0 ]; then \
	    fail "No images found in chart template for prefetch."; \
	  fi; \
	  ok "Resolve chart images from $(HELM_CHART_DIR) ($${#helm_images[@]} images)"; \
	  all_images=("$${helm_images[@]}"); \
	  if [ "$(K3D_PREFETCH_SYSTEM_IMAGES)" = "true" ] || [ "$(K3D_PREFETCH_SYSTEM_IMAGES)" = "1" ]; then \
	    step "Resolve kube-system images"; \
	    k3s_system_images=(); \
	    while IFS= read -r image; do \
	      [ -n "$$image" ] && k3s_system_images+=("$$image"); \
	    done < <(kubectl get deploy,daemonset -n kube-system -o jsonpath='{..image}' 2>/dev/null | tr -s '[:space:]' '\n' | sed '/^$$/d' | sort -u || true); \
	    if [ "$${#k3s_system_images[@]}" -gt 0 ]; then \
	      ok "Resolve kube-system images ($${#k3s_system_images[@]} images)"; \
	      merged_images=(); \
	      while IFS= read -r image; do \
	        [ -n "$$image" ] && merged_images+=("$$image"); \
	      done < <(printf "%s\n" "$${all_images[@]}" "$${k3s_system_images[@]}" | sed '/^$$/d' | sort -u); \
	      all_images=("$${merged_images[@]}"); \
	      ok "Prepared prefetch image set ($${#all_images[@]} unique images)"; \
	    else \
	      warn "Could not resolve kube-system images; continuing with chart images only."; \
	    fi; \
	  fi; \
		  for image in "$${all_images[@]}"; do \
		    run_step_retry "Pre-pull image $$image" "$(IMAGE_PULL_RETRIES)" "$(IMAGE_PULL_RETRY_DELAY)" docker pull "$$image"; \
		  done; \
	  run_step "Import $${#all_images[@]} images into k3d cluster $(K3D_CLUSTER)" \
	    k3d image import -c "$(K3D_CLUSTER)" --mode "$(K3D_IMAGE_IMPORT_MODE)" "$${all_images[@]}"; \
	else \
	  k3d_server_container="$$(docker ps --format '{{.Names}}' | awk '$$0 ~ /^k3d-$(K3D_CLUSTER)-server-0$$/ {print; exit}')"; \
	  if [ -n "$$k3d_server_container" ]; then \
	    step "Preflight: DNS resolution from $$k3d_server_container to $(IMAGE_REGISTRY_HOST)"; \
	    if docker exec "$$k3d_server_container" sh -lc "nslookup $(IMAGE_REGISTRY_HOST) >/dev/null 2>&1"; then \
	      ok "Preflight: DNS resolution from $$k3d_server_container to $(IMAGE_REGISTRY_HOST)"; \
	    else \
	      warn "DNS preflight failed in $$k3d_server_container. Current /etc/resolv.conf:"; \
	      docker exec "$$k3d_server_container" cat /etc/resolv.conf || true; \
	      fail "k3d node cannot resolve $(IMAGE_REGISTRY_HOST). Enable K3D_PREFETCH_IMAGES=true (default) or fix Docker DNS and recreate cluster."; \
	    fi; \
	  else \
	    warn "Could not find k3d server container for DNS preflight; continuing."; \
	  fi; \
	fi; \
		release_status="$$(helm status "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)" 2>/dev/null | awk '/^STATUS:/ {print $$2}' || true)"; \
	if [[ "$$release_status" == pending-* ]]; then \
	  warn "Helm release '$(HELM_RELEASE)' is in status '$$release_status'; attempting automatic recovery."; \
	  last_deployed_rev="$$(helm history "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)" | awk '$$3 == "deployed" {rev = $$1} END {print rev}')"; \
	  if [ -n "$$last_deployed_rev" ]; then \
	    run_step "Rollback release $(HELM_RELEASE) to deployed revision $$last_deployed_rev" \
	      helm rollback "$(HELM_RELEASE)" "$$last_deployed_rev" -n "$(K3D_NAMESPACE)" --cleanup-on-fail; \
	  else \
	    run_step "Uninstall pending release $(HELM_RELEASE)" \
	      helm uninstall "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)"; \
	  fi; \
	fi; \
	run_step "Validate Helm chart $(HELM_CHART_DIR)" \
	  helm lint "$(HELM_CHART_DIR)"; \
		step "Deploy Helm release '$(HELM_RELEASE)' into namespace '$(K3D_NAMESPACE)'"; \
		helm upgrade --install "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" \
		  --namespace "$(K3D_NAMESPACE)" \
		  --create-namespace \
		  --set withKea=$(WITH_KEA) \
		  --set stack=$(STACK) \
		  --wait \
		  --wait-for-jobs \
		  --rollback-on-failure \
		  --history-max "$(HELM_HISTORY_MAX)" \
		  --timeout "$(HELM_TIMEOUT)" & \
		helm_pid=$$!; \
		helm_wait_secs=0; \
		while kill -0 "$$helm_pid" >/dev/null 2>&1; do \
		  sleep 10; \
		  helm_wait_secs=$$((helm_wait_secs + 10)); \
		  pods_ready="$$(kubectl get pods -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk '{total+=1; split($$2,a,"/"); if (a[1]==a[2]) ready+=1} END {if (total==0) print "0/0"; else printf "%d/%d", ready, total}' || true)"; \
		  jobs_done="$$(kubectl get jobs -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk '{total+=1; split($$2,a,"/"); if (a[1]==a[2]) done+=1} END {if (total==0) print "0/0"; else printf "%d/%d", done, total}' || true)"; \
		  [ -n "$$pods_ready" ] || pods_ready="0/0"; \
		  [ -n "$$jobs_done" ] || jobs_done="0/0"; \
		  info "Helm in progress ($${helm_wait_secs}s elapsed) - pods ready: $$pods_ready, jobs complete: $$jobs_done"; \
		  if [ $$((helm_wait_secs % 40)) -eq 0 ]; then \
		    kubectl get pods -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk 'NR<=8 {printf "  - %s: %s (%s)\n", $$1, $$3, $$2}' || true; \
		  fi; \
		done; \
		rc=0; \
		if wait "$$helm_pid"; then \
		  rc=0; \
		else \
		  rc=$$?; \
		fi; \
		if [ "$$rc" -eq 0 ]; then \
		  ok "Deploy Helm release '$(HELM_RELEASE)' into namespace '$(K3D_NAMESPACE)'"; \
		else \
		  printf "%b[FAIL]%b Deploy Helm release '%s' into namespace '%s' (exit %s)\n" "$$c_err" "$$c_reset" "$(HELM_RELEASE)" "$(K3D_NAMESPACE)" "$$rc"; \
		  warn "Collecting diagnostics from namespace '$(K3D_NAMESPACE)'"; \
		  kubectl get pods -n "$(K3D_NAMESPACE)" -o wide || true; \
	  kubectl get jobs -n "$(K3D_NAMESPACE)" || true; \
	  kubectl get events -n "$(K3D_NAMESPACE)" --sort-by=.metadata.creationTimestamp | tail -n 40 || true; \
	  helm status "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)" || true; \
	  fail "Helm deployment failed. Review diagnostics above." "$$rc"; \
	fi; \
	run_step "Show namespace status $(K3D_NAMESPACE)" \
	  kubectl get pods,svc -n "$(K3D_NAMESPACE)"

##@ k3d service targets
k3d-deploy: ## Redeploy the full fred-stack Helm chart (no image prefetch)
	helm upgrade --install "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" \
		--namespace "$(K3D_NAMESPACE)" \
		--create-namespace \
		--set withKea=$(WITH_KEA) \
		--set stack=$(STACK) \
		--wait \
		--wait-for-jobs \
		--timeout "$(HELM_TIMEOUT)"

k3d-restart: ## Restart a k3d component: make k3d-restart COMPONENT=openfga
	@test -n "$(COMPONENT)" || (echo "ERROR: COMPONENT is required. Usage: make k3d-restart COMPONENT=<name>"; exit 1)
	kubectl rollout restart statefulset/$(COMPONENT) -n "$(K3D_NAMESPACE)" 2>/dev/null || \
		kubectl rollout restart deployment/$(COMPONENT) -n "$(K3D_NAMESPACE)"

k3d-redeploy: ## Restart a k3d component and re-run its post-install job: make k3d-redeploy COMPONENT=openfga
	@test -n "$(COMPONENT)" || (echo "ERROR: COMPONENT is required. Usage: make k3d-redeploy COMPONENT=<name>"; exit 1)
	kubectl delete job $(COMPONENT)-post-install -n "$(K3D_NAMESPACE)" --ignore-not-found
	kubectl rollout restart statefulset/$(COMPONENT) -n "$(K3D_NAMESPACE)" 2>/dev/null || \
		kubectl rollout restart deployment/$(COMPONENT) -n "$(K3D_NAMESPACE)"
	$(MAKE) k3d-deploy

k3d-logs: ## Show logs for a service: make k3d-logs SVC=openfga-post-install
	@if [ -z "$(SVC)" ]; then echo "Usage: make k3d-logs SVC=<name>"; exit 1; fi
	@kubectl logs -n "$(K3D_NAMESPACE)" -l app=$(SVC) --tail=100 2>/dev/null || \
		kubectl logs -n "$(K3D_NAMESPACE)" job/$(SVC) --tail=100 2>/dev/null || \
		echo "No logs found for '$(SVC)'"

k3d-uninstall: ## Uninstall the Helm release from k3d namespace
	@echo "Removing Helm release '$(HELM_RELEASE)' from namespace '$(K3D_NAMESPACE)'..."
	-helm uninstall "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)"

k3d-down: ## Turn off the k3d containers to release publicly allocated ports
	@echo "Turning the k3d cluster '$(K3D_CLUSTER)' down, and stopping k3d docker containers"
	-k3d cluster stop '$(K3D_CLUSTER)'

k3d-delete: ## Delete the k3d cluster
	@echo "Deleting k3d cluster '$(K3D_CLUSTER)'..."
	-k3d cluster delete "$(K3D_CLUSTER)"

k3d-wipe: ## Full k3d reset (uninstall Helm release and delete cluster)
	@echo -e "\n--- K3D WIPE IN PROGRESS ---"
	@$(MAKE) k3d-uninstall
	@$(MAKE) k3d-delete
	@echo -e "\n--- K3D WIPE COMPLETE ---"

k3d-status: ## Show pods and services in the k3d namespace
	@kubectl config use-context "k3d-$(K3D_CLUSTER)" >/dev/null
	@echo "Namespace: $(K3D_NAMESPACE)"
	kubectl get pods,svc -n "$(K3D_NAMESPACE)"

k3d-airgap-on: ## Enable air-gap mode (block internet except OpenAI API)
	@if ! kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then echo "Cilium CRDs not found; recreate with K3D_USE_CILIUM=true to use air-gap targets."; exit 1; fi
	@echo "🔒 Enabling air-gap mode in namespace '$(K3D_NAMESPACE)'..."
	kubectl apply -f helm/fred-stack/policies/cilium-airgap-policy.yaml
	@echo "Air-gap enabled. Only cluster-internal traffic and api.openai.com:443 are allowed."

k3d-airgap-off: ## Disable air-gap mode (restore full internet access)
	@if ! kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then echo "Cilium CRDs not found; nothing to disable."; exit 0; fi
	@echo "🔓 Disabling air-gap mode in namespace '$(K3D_NAMESPACE)'..."
	-kubectl delete -f helm/fred-stack/policies/cilium-airgap-policy.yaml
	@echo "Air-gap disabled. Full internet access restored."

k3d-airgap-status: ## Show active Cilium network policies
	@if ! kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then echo "Cilium CRDs not found; no Cilium policies available."; exit 0; fi
	@echo "📊 CiliumNetworkPolicies in namespace '$(K3D_NAMESPACE)':"
	kubectl get ciliumnetworkpolicies -n "$(K3D_NAMESPACE)"

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

# ─── Migration rehearsal — per-topic dump/restore (identity + data) ─────────────
# These mirror the production migration steps and, crucially, NEVER touch Postgres:
# after a wipe, fred_kea is empty so the METADATA import (step 3, in the app) is what
# repopulates it. Capture with docs loaded, then `migration-reset` to retest from scratch.

kea-identity-dump: ## [identity] Dump Keycloak realm (users+groups, IDs preserved) → dumps/identity/
	@bash bin/kea-identity-dump.sh

kea-identity-restore: ## [identity · step 1] Restore the Keycloak realm dump into the running stack
	@bash bin/kea-identity-restore.sh

kea-data-dump: ## [data] Dump all kea-* object-storage buckets, key-for-key → dumps/data/
	@bash bin/kea-data-dump.sh

kea-data-restore: ## [data · step 2] Restore the object-storage dump into the running stack
	@bash bin/kea-data-restore.sh

kea-snapshot: kea-identity-dump kea-data-dump ## Capture identity+data golden snapshot (run with docs loaded)
	@echo ""
	@echo "✓ Golden snapshot captured (identity + data)."
	@echo "  For step 3, also export the metadata .zip from the kea admin UI (Platform Migration · Export)."

migration-reset: ## Wipe → up EMPTY (no demo seed) → restore identity + data. fred_kea empty, ready for the metadata import (step 3)
	$(MAKE) docker-wipe
	$(MAKE) docker-up WITH_KEA=true SEED_DEMO=false
	$(MAKE) kea-identity-restore
	$(MAKE) kea-data-restore
	@echo ""
	@echo "============================================================"
	@echo " Ready for METADATA import (step 3)."
	@echo "   identity restored · data restored · fred_kea EMPTY"
	@echo "   → run the import in the app / kea admin UI."
	@echo "============================================================"

##@ Validation
VALIDATION_DIR  ?= validation
VALIDATION_VENV ?= $(VALIDATION_DIR)/.venv
PYTHON_BIN      ?= python3
# Shared Fred libraries live on the local `fred` checkout, expected as a sibling
# directory of this repo (../fred). Override if yours lives elsewhere.
SWIFT_SRC       ?= ../fred
FRED_CORE_SRC   ?= $(SWIFT_SRC)/libs/fred-core
FRED_SDK_SRC    ?= $(SWIFT_SRC)/libs/fred-sdk
FRED_RUNTIME_SRC ?= $(SWIFT_SRC)/libs/fred-runtime

# Fails fast with a precise, actionable message instead of pip's generic
# "not a valid editable requirement" (which doesn't say WHICH path is wrong or
# how to fix it). Checks for pyproject.toml specifically, since a directory can
# exist but not be a valid Python project (e.g. an empty/wrong checkout).
define require_swift_lib
	@test -f "$(1)/pyproject.toml" || { \
	  echo "✗ Not a valid Python project: $(1)/pyproject.toml not found."; \
	  echo "  SWIFT_SRC is currently: $(SWIFT_SRC)"; \
	  echo "  Fix: pass the path to your 'fred' checkout, e.g.:"; \
	  echo "    make $@ SWIFT_SRC=/path/to/fred"; \
	  exit 1; \
	}
endef

check-swift-src: ## Verify SWIFT_SRC points at a real fred checkout with fred-core/fred-sdk/fred-runtime
	$(call require_swift_lib,$(FRED_CORE_SRC))
	$(call require_swift_lib,$(FRED_SDK_SRC))
	$(call require_swift_lib,$(FRED_RUNTIME_SRC))
	@echo "✓ SWIFT_SRC resolves to a valid fred checkout ($(SWIFT_SRC))"

# Localhost auth/isolation validation expects Docker infra plus manually started Fred apps.
FRED_CONTROL_PLANE_URL ?= http://localhost:8222/control-plane/v1
FRED_RUNTIME_PUBLIC_BASE ?= http://localhost:8000
# Default: stop at the first failure (fast release-gate signal - one break is
# enough to say "not ready"). Override to see the full pass/fail picture in one
# run, e.g. when comparing an unfixed checkout against a fixed one:
#   make validate-auth-isolation-localhost PYTEST_ARGS=""
PYTEST_ARGS ?= -x

sync-openfga-model: check-swift-src ## Regenerate BOTH Swift OpenFGA model copies (docker-compose + helm/fred-stack) from the swift fred-core schema (manual - run after any fred-core rebac/schema.fga change). Never touches the Kea model.
	@python3 -m json.tool $(FRED_CORE_SRC)/fred_core/security/rebac/schema.fga.json docker-compose/openfga/openfga-model.json
	@python3 -m json.tool $(FRED_CORE_SRC)/fred_core/security/rebac/schema.fga.json helm/fred-stack/files/openfga/openfga-model.json
	@echo "✓ synced docker-compose/openfga/openfga-model.json and helm/fred-stack/files/openfga/openfga-model.json"
	@echo "  from $(FRED_CORE_SRC)/fred_core/security/rebac/schema.fga.json"
	@echo "  (docker-compose/openfga/openfga-model.kea.json is untouched - Kea stays on the legacy model)"
	@echo "  Re-run 'make openfga-post-install' (or 'make docker-up') to push the updated model to the running store."

check-openfga-model-sync: check-swift-src ## Fail fast if either Swift OpenFGA model copy has drifted from the fred-core canonical schema (normalized JSON compare)
	@canonical="$$(python3 -c "import json,sys; print(json.dumps(json.load(open('$(FRED_CORE_SRC)/fred_core/security/rebac/schema.fga.json')), sort_keys=True))")"; \
	for copy in docker-compose/openfga/openfga-model.json helm/fred-stack/files/openfga/openfga-model.json; do \
	  actual="$$(python3 -c "import json; print(json.dumps(json.load(open('$$copy')), sort_keys=True))")"; \
	  if [ "$$canonical" != "$$actual" ]; then \
	    echo "✗ $$copy has drifted from $(FRED_CORE_SRC)/fred_core/security/rebac/schema.fga.json"; \
	    echo "  Fix: make sync-openfga-model SWIFT_SRC=$(SWIFT_SRC)"; \
	    exit 1; \
	  fi; \
	done
	@echo "✓ docker-compose and helm Swift OpenFGA models match the fred-core canonical schema"

validate-auth-isolation-localhost: check-swift-src ## Black-box auth/security team-isolation validation against localhost Fred apps + Docker infra
	@test -x $(VALIDATION_VENV)/bin/python || { \
	  echo "▶ creating venv $(VALIDATION_VENV) (python3 -m venv)"; \
	  $(PYTHON_BIN) -m venv $(VALIDATION_VENV) && \
	  $(VALIDATION_VENV)/bin/pip install -q --upgrade pip; \
	}
	@echo "▶ installing deps (shared Fred libs editable + test app)"
	@$(VALIDATION_VENV)/bin/pip install -q -e $(FRED_CORE_SRC) -e $(FRED_SDK_SRC) -e $(FRED_RUNTIME_SRC) -e $(VALIDATION_DIR)
	@echo "▶ running black-box auth/security team-isolation scenarios on localhost"
	@echo "  control-plane: $(FRED_CONTROL_PLANE_URL)"
	@echo "  runtime base : $(FRED_RUNTIME_PUBLIC_BASE)"
	cd $(VALIDATION_DIR) && \
	  FRED_CONTROL_PLANE_URL="$(FRED_CONTROL_PLANE_URL)" \
	  FRED_RUNTIME_PUBLIC_BASE="$(FRED_RUNTIME_PUBLIC_BASE)" \
	  .venv/bin/pytest $(PYTEST_ARGS)

validation-unit-tests: ## Offline unit tests for the validation harness itself (factory_config.py) - no running stack required
	@test -x $(VALIDATION_VENV)/bin/python || { \
	  echo "▶ creating venv $(VALIDATION_VENV) (python3 -m venv)"; \
	  $(PYTHON_BIN) -m venv $(VALIDATION_VENV) && \
	  $(VALIDATION_VENV)/bin/pip install -q --upgrade pip; \
	}
	@echo "▶ installing deps (shared Fred libs editable + test app)"
	@$(VALIDATION_VENV)/bin/pip install -q -e $(FRED_CORE_SRC) -e $(FRED_SDK_SRC) -e $(FRED_RUNTIME_SRC) -e $(VALIDATION_DIR)
	@echo "▶ running offline unit tests (no live stack)"
	cd $(VALIDATION_DIR) && .venv/bin/pytest tests -q

validate-auth-isolation-k3d: ## Black-box auth/security team-isolation validation against full k3d deployment (not implemented)
	@echo "validate-auth-isolation-k3d is not yet implemented."
	@echo "It will run the same black-box auth/security team-isolation suite against a full k3d deployment through ingress."
	@echo "Current release gate: make validate-auth-isolation-localhost"
	@exit 2

VALIDATION_REPORT ?= $(VALIDATION_DIR)/report.md
VALIDATION_JUNIT_XML ?= $(VALIDATION_DIR)/report.xml

validation-report: check-swift-src ## Run the full validation suite (no -x) and write a short claims-grouped Markdown report
	@test -x $(VALIDATION_VENV)/bin/python || { \
	  echo "▶ creating venv $(VALIDATION_VENV) (python3 -m venv)"; \
	  $(PYTHON_BIN) -m venv $(VALIDATION_VENV) && \
	  $(VALIDATION_VENV)/bin/pip install -q --upgrade pip; \
	}
	@echo "▶ installing deps (shared Fred libs editable + test app)"
	@$(VALIDATION_VENV)/bin/pip install -q -e $(FRED_CORE_SRC) -e $(FRED_SDK_SRC) -e $(FRED_RUNTIME_SRC) -e $(VALIDATION_DIR)
	@echo "▶ running the full suite (no -x, so one failure doesn't hide the rest)"
	@set +e; \
	  cd $(VALIDATION_DIR) && \
	    FRED_CONTROL_PLANE_URL="$(FRED_CONTROL_PLANE_URL)" \
	    FRED_RUNTIME_PUBLIC_BASE="$(FRED_RUNTIME_PUBLIC_BASE)" \
	    .venv/bin/pytest --junitxml=report.xml; \
	  rc=$$?; \
	  cd "$(CURDIR)" || exit $$rc; \
	  $(VALIDATION_VENV)/bin/python $(VALIDATION_DIR)/generate_report.py $(VALIDATION_JUNIT_XML) | tee $(VALIDATION_REPORT); \
	  echo ""; \
	  echo "✓ Report written to $(VALIDATION_REPORT)"; \
	  exit $$rc

.PHONY: help network-create env-setup keycloak-post-install postgres-up keycloak-up seaweedfs-up opensearch-up clickhouse-up langfuse-up prometheus-up grafana-up openfga-post-install openfga-up temporal-up preflight-check docker-up docker-down all-down docker-wipe docker-destroy k3d-create k3d-up k3d-deploy k3d-restart k3d-redeploy k3d-logs k3d-down k3d-uninstall k3d-delete k3d-wipe k3d-status k3d-airgap-on k3d-airgap-off k3d-airgap-status checkpoint-save checkpoint-restore docker-restart-from-checkpoint checkpoint-list checkpoint-delete kea-identity-dump kea-identity-restore kea-data-dump kea-data-restore kea-snapshot migration-reset check-swift-src sync-openfga-model check-openfga-model-sync validation-unit-tests validate-auth-isolation-localhost validate-auth-isolation-k3d validation-report
