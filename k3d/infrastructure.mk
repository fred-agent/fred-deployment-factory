# Internal engine, invoked only by bin/k3d-local. No user-selected profiles.
SHELL := /bin/bash
.DEFAULT_GOAL := up
ifneq ($(K3D_FACTORY_INTERNAL),1)
$(error Use make k3d-up-swift, make k3d-up-weaver or make k3d-up-migration)
endif
include k3d/local.env
KUBE_CONTEXT := k3d-fred
K3D_NAMESPACE := fred
export KUBE_CONTEXT K3D_NAMESPACE
KUBECTL := kubectl --context "$(KUBE_CONTEXT)"
HELM := helm --kube-context "$(KUBE_CONTEXT)"
HELM_RELEASE := fred-stack
HELM_CHART_DIR := ./k3d
HELM_TIMEOUT := 20m
HELM_HISTORY_MAX := 10
IMAGE_REGISTRY_HOST := registry-1.docker.io
K3D_PREFETCH_IMAGES := true
# k3s nodes pull their own system images (coredns, traefik, ...) when the cluster
# is created; copying them from the host again only adds downloads.
K3D_PREFETCH_SYSTEM_IMAGES := false
IMAGE_PULL_RETRIES := 3
IMAGE_PULL_RETRY_DELAY := 5
# Carry the host trust bundle into the fixed local cluster when available.
K3D_CA_BUNDLE := $(firstword $(wildcard /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt))
ifneq ($(K3D_CA_BUNDLE),)
K3D_CA_VOLUME_ARG := --volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@server:* --volume $(K3D_CA_BUNDLE):/etc/ssl/certs/ca-certificates.crt@agent:*
endif

# One set of values for lint, prefetch rendering and the actual infrastructure release.
K3D_HELM_VALUES = --set stack=base --set-string host.fqdn="$(K3D_HOST_NAME)" \
	--set-string keycloak.hostname="$(K3D_KEYCLOAK_HOST)" --set keycloak.publicPort=$(K3D_HOST_PORT_KEYCLOAK) \
	--set host.frontendPort=$(K3D_HOST_PORT_FRONTEND) --set host.dashboardsPort=$(K3D_HOST_PORT_OPENSEARCH_DASHBOARDS) \
	--set temporal.uiPort=$(K3D_HOST_PORT_TEMPORAL_UI) \
	--set postgres.applicationBootstrap=false \
	--set openfga.enabled=$(K3D_OPENFGA_ENABLED)

# Kubelet disk thresholds in absolute sizes. The defaults are percentages of the
# host disk (image GC above 85% used, eviction under 15% free): on a developer
# laptop with a well-filled large disk they delete prefetched images and evict
# pods although hundreds of GiB are free.
K3D_KUBELET_DISK_ARGS := \
	--k3s-arg "--kubelet-arg=image-gc-high-threshold=100@server:*;agent:*" \
	--k3s-arg "--kubelet-arg=image-gc-low-threshold=99@server:*;agent:*" \
	--k3s-arg "--kubelet-arg=eviction-hard=memory.available<100Mi,nodefs.available<2Gi,imagefs.available<2Gi,nodefs.inodesFree<5%,imagefs.inodesFree<5%@server:*;agent:*"

K3D_CLUSTER_CREATE_BASE_ARGS := \
	--kubeconfig-switch-context=false \
	--servers 1 \
	--agents 1 \
	--wait \
	$(K3D_KUBELET_DISK_ARGS) \
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

create: disk-check
	@set -euo pipefail; \
		c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'; \
		step() { printf "%b[STEP]%b %s\n" "$$c_step" "$$c_reset" "$$1"; }; \
		ok() { printf "%b[OK]%b %s\n" "$$c_ok" "$$c_reset" "$$1"; }; \
		warn() { printf "%b[WARN]%b %s\n" "$$c_warn" "$$c_reset" "$$1"; }; \
		info() { printf "%b[INFO]%b %s\n" "$$c_info" "$$c_reset" "$$1"; }; \
		fail() { local msg="$$1"; local rc="$${2:-1}"; printf "%b[FAIL]%b %s\n" "$$c_err" "$$c_reset" "$$msg"; exit "$$rc"; }; \
		run_step() { local title="$$1"; shift; step "$$title"; if "$$@"; then ok "$$title"; else local rc=$$?; fail "$$title (exit $$rc)" "$$rc"; fi; }; \
	command -v k3d >/dev/null 2>&1 || fail "k3d is required"; \
	mkdir -p .cache; exec 9>.cache/k3d-create.lock; flock 9; \
	if k3d cluster get "$(K3D_CLUSTER)" >/dev/null 2>&1; then \
	  info "Cluster '$(K3D_CLUSTER)' already exists, skipping creation."; \
	  exit 0; \
	fi; \
	run_step "Create k3d cluster '$(K3D_CLUSTER)' (default k3s networking)" \
	  k3d cluster create "$(K3D_CLUSTER)" \
	  $(K3D_CLUSTER_CREATE_BASE_ARGS) \
	  $(K3D_CA_VOLUME_ARG)


up: create
	@set -euo pipefail; \
		c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'; \
		step() { printf "%b[STEP]%b %s\n" "$$c_step" "$$c_reset" "$$1"; }; \
		ok() { printf "%b[OK]%b %s\n" "$$c_ok" "$$c_reset" "$$1"; }; \
		warn() { printf "%b[WARN]%b %s\n" "$$c_warn" "$$c_reset" "$$1"; }; \
		info() { printf "%b[INFO]%b %s\n" "$$c_info" "$$c_reset" "$$1"; }; \
		fail() { local msg="$$1"; local rc="$${2:-1}"; printf "%b[FAIL]%b %s\n" "$$c_err" "$$c_reset" "$$msg"; exit "$$rc"; }; \
		run_step() { local title="$$1"; shift; step "$$title"; if "$$@"; then ok "$$title"; else local rc=$$?; fail "$$title (exit $$rc)" "$$rc"; fi; }; \
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
	info "Context $(KUBE_CONTEXT), infrastructure namespace $(K3D_NAMESPACE)"; \
	if [ "$(K3D_PREFETCH_IMAGES)" = "true" ] || [ "$(K3D_PREFETCH_IMAGES)" = "1" ]; then \
	  step "Resolve chart images from $(HELM_CHART_DIR)"; \
	  helm_images=(); \
	  while IFS= read -r image; do \
	    [ -n "$$image" ] && helm_images+=("$$image"); \
	  done < <($(HELM) template "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" $(K3D_HELM_VALUES) | awk '/image:[[:space:]]*/ {print $$2}' | tr -d '"' | sort -u); \
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
	    done < <($(KUBECTL) get deploy,daemonset -n kube-system -o jsonpath='{..image}' 2>/dev/null | tr -s '[:space:]' '\n' | sed '/^$$/d' | sort -u || true); \
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
	  run_step "Prefetch $${#all_images[@]} images into k3d cluster $(K3D_CLUSTER)" \
	    env IMAGE_PULL_RETRIES="$(IMAGE_PULL_RETRIES)" IMAGE_PULL_RETRY_DELAY="$(IMAGE_PULL_RETRY_DELAY)" \
	    bin/k3d-prefetch-images.sh "$(K3D_CLUSTER)" "$${all_images[@]}"; \
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
	run_step "Recover release $(HELM_RELEASE) if an earlier run left it pending or failed" \
	  bin/k3d-helm-recover.sh "$(HELM_RELEASE)" "$(K3D_NAMESPACE)" "$(HELM_TIMEOUT)"; \
	run_step "Validate Helm chart $(HELM_CHART_DIR)" \
	  $(HELM) lint "$(HELM_CHART_DIR)" $(K3D_HELM_VALUES); \
		if $(HELM) upgrade --help | grep -q -- "--rollback-on-failure"; then \
		  rollback_flag="--rollback-on-failure"; \
		else \
		  rollback_flag="--atomic"; \
		fi; \
		step "Deploy Helm release '$(HELM_RELEASE)' into namespace '$(K3D_NAMESPACE)'"; \
		$(HELM) upgrade --install "$(HELM_RELEASE)" "$(HELM_CHART_DIR)" \
		  --namespace "$(K3D_NAMESPACE)" \
		  --create-namespace \
		  $(K3D_HELM_VALUES) \
		  --wait \
		  --wait-for-jobs \
		  "$$rollback_flag" \
		  --history-max "$(HELM_HISTORY_MAX)" \
		  --timeout "$(HELM_TIMEOUT)" & \
		helm_pid=$$!; \
		helm_wait_secs=0; \
		while kill -0 "$$helm_pid" >/dev/null 2>&1; do \
		  sleep 10; \
		  helm_wait_secs=$$((helm_wait_secs + 10)); \
		  pods_ready="$$($(KUBECTL) get pods -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk '{total+=1; split($$2,a,"/"); if (a[1]==a[2]) ready+=1} END {if (total==0) print "0/0"; else printf "%d/%d", ready, total}' || true)"; \
		  jobs_done="$$($(KUBECTL) get jobs -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk '{total+=1; split($$2,a,"/"); if (a[1]==a[2]) done+=1} END {if (total==0) print "0/0"; else printf "%d/%d", done, total}' || true)"; \
		  [ -n "$$pods_ready" ] || pods_ready="0/0"; \
		  [ -n "$$jobs_done" ] || jobs_done="0/0"; \
		  info "Helm in progress ($${helm_wait_secs}s elapsed) - pods ready: $$pods_ready, jobs complete: $$jobs_done"; \
		  if [ $$((helm_wait_secs % 40)) -eq 0 ]; then \
		    $(KUBECTL) get pods -n "$(K3D_NAMESPACE)" --no-headers 2>/dev/null | awk 'NR<=8 {printf "  - %s: %s (%s)\n", $$1, $$3, $$2}' || true; \
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
		  $(KUBECTL) get pods -n "$(K3D_NAMESPACE)" -o wide || true; \
	  $(KUBECTL) get jobs -n "$(K3D_NAMESPACE)" || true; \
	  $(KUBECTL) get events -n "$(K3D_NAMESPACE)" --sort-by=.metadata.creationTimestamp | tail -n 40 || true; \
	  $(HELM) status "$(HELM_RELEASE)" -n "$(K3D_NAMESPACE)" || true; \
	  fail "Helm deployment failed. Review diagnostics above." "$$rc"; \
	fi; \
	run_step "Show namespace status $(K3D_NAMESPACE)" \
	  $(KUBECTL) get pods,svc -n "$(K3D_NAMESPACE)"

disk-check:
	@bin/k3d-disk-check.sh
.PHONY: up create disk-check
