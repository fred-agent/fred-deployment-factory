#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster="${K3D_CLUSTER:?Set K3D_CLUSTER to the intended k3d cluster}"
context="${KUBE_CONTEXT:-k3d-$cluster}"
fred_repo="$(realpath "${FRED_REPO:-$repo_root/../fred}")"
cache="$repo_root/.cache/agent-sandbox/$cluster"
gvisor_version=20261012.0
gvisor_sha512=ce2e1aeb853c104e854dea6644333a1dba0fbc9dd1646af97e1d013fdf810da6d4176dd96f2139d7b055e5382117c0d7c4567ebd64ed9bef47fdd15f80fd67ab
sig_version=v1.0.6
sig_sha256=e6fa909d82392b201ef80003dd91390450266ba356caa9be04a1c89c3caa65dc
python_source=python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704
registry="$cluster-registry"

say() { printf '[sandbox] %s\n' "$*"; }
die() { printf '[sandbox] ERROR: %s\n' "$*" >&2; exit 1; }
kube() { kubectl --context "$context" "$@"; }

preflight() {
  [[ "$cluster" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid k3d cluster name: $cluster"
  [[ "$context" == "k3d-$cluster" ]] || die "Context must be k3d-$cluster"
  [[ "$(uname -m)" == x86_64 ]] || die "The pinned gVisor archive and Python image currently require x86_64"
  for command in docker kubectl k3d curl sha512sum sha256sum openssl tar git python3; do
    command -v "$command" >/dev/null || die "$command is required"
  done
  k3d cluster get "$cluster" >/dev/null 2>&1 || die "Cluster $cluster does not exist"
  kube get namespace kube-system >/dev/null || die "Context $context is unavailable"
  docker inspect "$registry" >/dev/null 2>&1 || die "Registry $registry is missing. Recreate the cluster with K3D_AGENT_SANDBOX=true."
  mkdir -p "$cache"
}

fetch_verified() {
  local url="$1" path="$2" checksum="$3" algorithm="$4"
  if ! printf '%s  %s\n' "$checksum" "$path" | "$algorithm" -c - >/dev/null 2>&1; then
    rm -f "$path"
    curl -fL --retry 3 --retry-delay 2 -o "$path" "$url"
    printf '%s  %s\n' "$checksum" "$path" | "$algorithm" -c - >/dev/null \
      || die "Checksum mismatch for $url"
  fi
}

install_gvisor() {
  local archive="$cache/gvisor.tar.zstd" runtime="$cache/gvisor-runtime"
  fetch_verified "https://storage.googleapis.com/gvisor/releases/release/$gvisor_version/$(uname -m)/gvisor.tar.zstd" \
    "$archive" "$gvisor_sha512" sha512sum
  mkdir -p "$runtime"
  tar --zstd -xf "$archive" -C "$runtime"
  local config_hash
  config_hash="$(sha256sum "$repo_root/k3d/agent-sandbox/config.toml.tmpl" | cut -d' ' -f1)"
  local nodes=()
  mapfile -t nodes < <(docker ps --format '{{.Names}}' | grep -E "^k3d-$cluster-(agent|server)-[0-9]+$" | sort)
  ((${#nodes[@]} > 0)) || die "No running k3d nodes for $cluster"
  for node in "${nodes[@]}"; do
    docker inspect "$node" --format '{{json .Config.Cmd}}' | grep -q -- '--kubelet-arg=pod-max-pids=64' \
      || die "$node lacks the required pod-max-pids=64 kubelet setting"
    local installed_version installed_hash
    installed_version="$(docker exec "$node" /usr/local/bin/runsc --version 2>/dev/null | head -1 || true)"
    installed_hash="$(docker exec "$node" sha256sum /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ "$installed_version" == "runsc version release-$gvisor_version" && "$installed_hash" == "$config_hash" ]]; then
      say "$node already has gVisor $gvisor_version"
      continue
    fi
    say "Install gVisor $gvisor_version on $node"
    docker exec "$node" mkdir -p /usr/local/bin
    docker cp "$runtime/runsc" "$node:/usr/local/bin/runsc"
    docker cp "$runtime/containerd-shim-runsc-v1" "$node:/usr/local/bin/containerd-shim-runsc-v1"
    docker cp "$runtime/gvisor-bin" "$node:/usr/local/bin/gvisor-bin"
    docker exec "$node" mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
    docker cp "$repo_root/k3d/agent-sandbox/config.toml.tmpl" \
      "$node:/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
    docker restart "$node" >/dev/null
  done
  kube wait node --all --for=condition=Ready --timeout=180s
  kube apply -f "$repo_root/k3d/agent-sandbox/runtimeclass.yaml"
}

registry_port() {
  local endpoint
  endpoint="$(docker port "$registry" 5000/tcp | head -1)"
  [[ "$endpoint" =~ :([0-9]+)$ ]] || die "Cannot find the host port of $registry"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

push_image() {
  local source="$1" name="$2" tag="$3" host_port="$4"
  local host_ref="127.0.0.1:$host_port/$name:$tag"
  docker tag "$source" "$host_ref"
  local push_output digest
  push_output="$(docker push "$host_ref")"
  digest="$(printf '%s\n' "$push_output" | sed -nE 's/.*digest: (sha256:[a-f0-9]{64}).*/\1/p' | tail -1)"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Cannot verify pushed digest for $host_ref"
  printf '%s/%s@%s\n' "$registry:5000" "$name" "$digest"
}

install_sig() {
  local manifest="$cache/agent-sandbox-with-extensions-$sig_version.yaml"
  fetch_verified "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$sig_version/sandbox-with-extensions.yaml" \
    "$manifest" "$sig_sha256" sha256sum
  kube apply -f "$manifest"
  kube rollout status deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=180s
  for crd in sandboxes.agents.x-k8s.io sandboxclaims.extensions.agents.x-k8s.io \
    sandboxtemplates.extensions.agents.x-k8s.io sandboxwarmpools.extensions.agents.x-k8s.io; do
    kube wait --for=condition=Established "crd/$crd" --timeout=120s
  done
}

create_credentials() {
  umask 077
  if [[ ! -s "$cache/broker-token" ]]; then openssl rand -hex 32 | tr -d '\n' > "$cache/broker-token"; fi
  tr -d '\r\n' < "$cache/broker-token" > "$cache/broker-token.clean"
  mv "$cache/broker-token.clean" "$cache/broker-token"
  local renew_broker=false
  if [[ ! -s "$cache/ca.crt" ]] \
    || ! openssl x509 -checkend 86400 -noout -in "$cache/ca.crt" >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -keyout "$cache/ca.key" -out "$cache/ca.crt" -subj "/CN=Fred sandbox local CA" >/dev/null 2>&1
    renew_broker=true
  fi
  if [[ "$renew_broker" == true || ! -s "$cache/broker.crt" ]] \
    || ! openssl x509 -checkend 86400 -noout -in "$cache/broker.crt" >/dev/null 2>&1; then
    openssl req -newkey rsa:2048 -nodes -keyout "$cache/broker.key" -out "$cache/broker.csr" \
      -subj "/CN=fred-sandbox-broker.fred-sandbox-system.svc.cluster.local" >/dev/null 2>&1
    printf 'subjectAltName=DNS:fred-sandbox-broker.fred-sandbox-system.svc.cluster.local,DNS:localhost\nextendedKeyUsage=serverAuth\n' \
      > "$cache/broker.ext"
    openssl x509 -req -in "$cache/broker.csr" -CA "$cache/ca.crt" -CAkey "$cache/ca.key" \
      -CAcreateserial -out "$cache/broker.crt" -days 30 -extfile "$cache/broker.ext" >/dev/null 2>&1
  fi
  kube -n fred-sandbox-system create secret generic fred-sandbox-broker-auth \
    --from-file=token="$cache/broker-token" --dry-run=client -o yaml | kube apply -f -
  kube -n fred-sandbox-system create secret tls fred-sandbox-broker-tls \
    --cert="$cache/broker.crt" --key="$cache/broker.key" --dry-run=client -o yaml | kube apply -f -
  if kube get namespace fred >/dev/null 2>&1; then
    local first_node="k3d-$cluster-server-0"
    docker cp "$first_node:/etc/ssl/certs/ca-certificates.crt" "$cache/node-ca.crt"
    cat "$cache/node-ca.crt" "$cache/ca.crt" > "$cache/combined-ca.crt"
    kube -n fred create secret generic fred-sandbox-broker-client \
      --from-file=token="$cache/broker-token" --dry-run=client -o yaml | kube apply -f -
    kube -n fred create configmap fred-sandbox-broker-ca \
      --from-file=ca.crt="$cache/combined-ca.crt" --dry-run=client -o yaml | kube apply -f -
  fi
}

install_workloads() {
  [[ -f "$fred_repo/deploy/sandbox/agent-sandbox.yaml" ]] \
    || die "FRED_REPO=$fred_repo does not contain deploy/sandbox/agent-sandbox.yaml"
  [[ -f "$fred_repo/apps/sandbox-broker/Dockerfile" ]] \
    || die "FRED_REPO=$fred_repo does not contain the broker Dockerfile"
  local port python_image broker_image broker_tag
  port="$(registry_port)"
  say "Pull and push the approved Python image"
  docker pull --platform linux/amd64 "$python_source" >/dev/null
  python_image="$(push_image "$python_source" python 3.12-slim "$port")"
  broker_tag="$(git -C "$fred_repo" rev-parse --short=12 HEAD)"
  say "Build and push the broker from $fred_repo"
  docker build -f "$fred_repo/apps/sandbox-broker/Dockerfile" \
    -t "fred-sandbox-broker:$broker_tag" "$fred_repo"
  broker_image="$(push_image "fred-sandbox-broker:$broker_tag" fred-sandbox-broker "$broker_tag" "$port")"
  printf '%s\n' "$python_image" > "$cache/python-image"
  printf '%s\n' "$broker_image" > "$cache/broker-image"

  kube apply -f "$repo_root/k3d/agent-sandbox/foundation.yaml"
  install_sig
  create_credentials
  sed "s|REPLACE_WITH_APPROVED_PYTHON_IMAGE_DIGEST|$python_image|g" \
    "$fred_repo/deploy/sandbox/agent-sandbox.yaml" | kube apply -f -
  sed -e "s|@BROKER_IMAGE@|$broker_image|g" \
      -e "s|@PYTHON_IMAGE@|$python_image|g" \
      "$repo_root/k3d/agent-sandbox/broker.yaml" | kube apply -f -
  kube rollout restart deployment/fred-sandbox-broker -n fred-sandbox-system
  kube rollout status deployment/fred-sandbox-broker -n fred-sandbox-system --timeout=180s
  say "Python image: $python_image"
  say "Broker image: $broker_image"
}

smoke() {
  [[ -s "$cache/broker-token" && -s "$cache/ca.crt" ]] || die "Run up first"
  local port=18443 session output
  session="$(openssl rand -hex 32)"
  kube -n fred-sandbox-system port-forward service/fred-sandbox-broker "$port:443" \
    > "$cache/port-forward.log" 2>&1 &
  local forward_pid=$!
  trap "kill $forward_pid 2>/dev/null || true" EXIT
  for _ in {1..30}; do
    if curl -fsS --cacert "$cache/ca.crt" https://localhost:$port/healthz > "$cache/health.json" 2>/dev/null; then break; fi
    sleep 1
  done
  grep -q '"allocated"' "$cache/health.json" || die "Broker health check failed"
  for language in python bash; do
    local code
    if [[ "$language" == python ]]; then code='print(7319)'; else code='printf 7319'; fi
    output="$(curl -fsS --cacert "$cache/ca.crt" \
      -H "Authorization: Bearer $(cat "$cache/broker-token")" \
      -H "X-Fred-Sandbox-Session: $session" \
      -H 'Content-Type: application/json' \
      -d "{\"language\":\"$language\",\"code\":\"$code\"}" \
      https://localhost:$port/v1/execute)"
    printf '%s' "$output" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["exit_code"] == 0 and r["stdout"].strip() == "7319", r' \
      || die "$language execution failed"
    say "$language execution passed"
  done
  kube -n fred-sandbox get sandboxwarmpool fred-code -o jsonpath='{.spec.replicas}' | grep -qx 0 \
    || die "Warm pool is not zero"
  local pod runtime image version
  pod="$(kube -n fred-sandbox get pods -o name --sort-by=.metadata.creationTimestamp | tail -1)"
  [[ -n "$pod" ]] || die "No sandbox Pod was created"
  runtime="$(kube -n fred-sandbox get "$pod" -o jsonpath='{.spec.runtimeClassName}')"
  image="$(kube -n fred-sandbox get "$pod" -o jsonpath='{.spec.containers[0].image}')"
  version="$(kube -n fred-sandbox exec "$pod" -- python -c 'print(open("/proc/version").read().strip())')"
  [[ "$runtime" == gvisor && "$image" == "$(cat "$cache/python-image")" && "$version" == *gvisor* ]] \
    || die "Sandbox Pod did not use the pinned registry image under gVisor"
  kube -n fred-sandbox exec "$pod" -- python -c \
    'from pathlib import Path; import shutil; assert not Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists(); assert shutil.which("kubectl") is None; assert shutil.which("docker") is None' \
    || die "Sandbox Pod exposes a Kubernetes token or cluster management binary"
  say "Sandbox Pod uses gVisor and the local registry image"
  say "Warm pool remains at zero"
}

render_fred_values() {
  command -v yq >/dev/null || die "yq v4 is required for the sandbox Fred values"
  mkdir -p "$cache"
  yq eval 'del(.applications."control-plane-backend".configuration.platform.application_sources, .applications."control-plane-backend".configuration.knowledge_bases.publishers) | .applications.frontend.env |= map(select(.name != "FRONTEND_APPLICATIONS_JSON"))' \
    "$repo_root/k3d-apps/fred/values.yaml" > "$cache/fred-values.yaml"
  say "Rendered current Fred values to $cache/fred-values.yaml"
}

case "${1:-}" in
  up) preflight; install_gvisor; install_workloads ;;
  smoke) preflight; smoke ;;
  render-fred-values) render_fred_values ;;
  *) die "Usage: $0 {up|smoke|render-fred-values}" ;;
esac
