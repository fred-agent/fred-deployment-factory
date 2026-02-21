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
HELM_HISTORY_MAX ?= 10
IMAGE_REGISTRY_HOST ?= registry-1.docker.io
K3D_PREFETCH_IMAGES ?= true
K3D_PREFETCH_SYSTEM_IMAGES ?= true
K3D_IMAGE_IMPORT_MODE ?= tools-node
IMAGE_PULL_RETRIES ?= 3
IMAGE_PULL_RETRY_DELAY ?= 5
K3D_USE_CILIUM ?= false
CILIUM_VERSION ?= 1.16.5

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
K3D_HOST_PORT_FRONTEND ?= 8088

K3D_CLUSTER_CREATE_BASE_ARGS := \
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
	-p "$(K3D_HOST_PORT_TEMPORAL_UI):30233@server:0" \
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

docker-up: keycloak-up minio-up opensearch-up openfga-up temporal-up ## Launch the Docker stack (Keycloak, MinIO, OpenSearch, OpenFGA, Temporal)
	$(MAKE) preflight-check
	@echo "All Docker stack services are running and preflight passed."

all-down:
	@echo "Stopping Docker stack services..."
	$(DOCKER_COMPOSE_BASE)temporal.yml -p temporal down
	$(DOCKER_COMPOSE_BASE)opensearch.yml -p opensearch down
	$(DOCKER_COMPOSE_BASE)openfga.yml -p openfga down
	$(DOCKER_COMPOSE_BASE)minio.yml -p minio down
	$(DOCKER_COMPOSE_BASE)keycloak.yml -p keycloak down

docker-wipe: all-down ## Stop Docker stack, delete volumes, remove network, and prune
	@echo -e "\n--- WIPE IN PROGRESS ---"
	@for file in $(CORE_COMPOSE_FILES); do \
		docker compose -f $$file down -v; \
	done
	docker network rm fred-shared-network || true
	docker system prune -f
	@echo -e "\n--- WIPE COMPLETE ---"

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
	    --k3s-arg '--flannel-backend=none@server:*' \
	    --k3s-arg '--disable-network-policy@server:*'; \
	  run_step "Install Cilium $(CILIUM_VERSION)" cilium install --version "$(CILIUM_VERSION)"; \
	  run_step "Wait for Cilium readiness" cilium status --wait --wait-duration 5m; \
	else \
	  run_step "Create k3d cluster '$(K3D_CLUSTER)' (default k3s networking)" \
	    k3d cluster create "$(K3D_CLUSTER)" \
	    $(K3D_CLUSTER_CREATE_BASE_ARGS); \
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
	run_step "Switch kubectl context to k3d-$(K3D_CLUSTER)" \
	  kubectl config use-context "k3d-$(K3D_CLUSTER)"; \
	if [ "$(K3D_PREFETCH_IMAGES)" = "true" ] || [ "$(K3D_PREFETCH_IMAGES)" = "1" ]; then \
	  step "Resolve chart images from $(HELM_CHART_DIR)"; \
	  mapfile -t helm_images < <(helm template "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" | awk '/image:[[:space:]]*/ {print $$2}' | tr -d '"' | sort -u); \
	  if [ "$${#helm_images[@]}" -eq 0 ]; then \
	    fail "No images found in chart template for prefetch."; \
	  fi; \
	  ok "Resolve chart images from $(HELM_CHART_DIR) ($${#helm_images[@]} images)"; \
	  all_images=("$${helm_images[@]}"); \
	  if [ "$(K3D_PREFETCH_SYSTEM_IMAGES)" = "true" ] || [ "$(K3D_PREFETCH_SYSTEM_IMAGES)" = "1" ]; then \
	    step "Resolve kube-system images"; \
	    mapfile -t k3s_system_images < <(kubectl get deploy,daemonset -n kube-system -o jsonpath='{..image}' 2>/dev/null | tr -s '[:space:]' '\n' | sed '/^$$/d' | sort -u || true); \
	    if [ "$${#k3s_system_images[@]}" -gt 0 ]; then \
	      ok "Resolve kube-system images ($${#k3s_system_images[@]} images)"; \
	      mapfile -t all_images < <(printf "%s\n" "$${all_images[@]}" "$${k3s_system_images[@]}" | sed '/^$$/d' | sort -u); \
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
		  --wait \
		  --wait-for-jobs \
		  --atomic \
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

k3d-down: ## Uninstall the Helm release from k3d namespace
	@echo "Removing Helm release '$(HELM_RELEASE)' from namespace '$(K3D_NAMESPACE)'..."
	-helm uninstall "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)"

k3d-delete: ## Delete the k3d cluster
	@echo "Deleting k3d cluster '$(K3D_CLUSTER)'..."
	-k3d cluster delete "$(K3D_CLUSTER)"

k3d-wipe: ## Full k3d reset (uninstall Helm release and delete cluster)
	@echo -e "\n--- K3D WIPE IN PROGRESS ---"
	@$(MAKE) k3d-down
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

.PHONY: help network-create env-setup keycloak-post-install keycloak-up minio-up opensearch-up openfga-post-install openfga-up temporal-up preflight-check docker-up all-down docker-wipe k3d-create k3d-up k3d-down k3d-delete k3d-wipe k3d-status k3d-airgap-on k3d-airgap-off k3d-airgap-status
