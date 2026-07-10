#!/usr/bin/env bash
set -Eeuo pipefail

K3D_CLUSTER="${K3D_CLUSTER:-fred}"
K3D_NAMESPACE="${K3D_NAMESPACE:-fred}"
HELM_RELEASE="${HELM_RELEASE:-fred-stack}"
STACK_MODE="${STACK_MODE:-auto}"
TIMEOUT="${TIMEOUT:-0}"
INTERVAL="${INTERVAL:-5}"

K3D_HOST_PORT_KEYCLOAK="${K3D_HOST_PORT_KEYCLOAK:-8080}"
K3D_HOST_PORT_POSTGRES="${K3D_HOST_PORT_POSTGRES:-5432}"
K3D_HOST_PORT_SEAWEEDFS_S3="${K3D_HOST_PORT_SEAWEEDFS_S3:-8333}"
K3D_HOST_PORT_SEAWEEDFS_FILER="${K3D_HOST_PORT_SEAWEEDFS_FILER:-8888}"
K3D_HOST_PORT_SEAWEEDFS_MASTER="${K3D_HOST_PORT_SEAWEEDFS_MASTER:-9333}"
K3D_HOST_PORT_CLICKHOUSE_HTTP="${K3D_HOST_PORT_CLICKHOUSE_HTTP:-8123}"
K3D_HOST_PORT_CLICKHOUSE_NATIVE="${K3D_HOST_PORT_CLICKHOUSE_NATIVE:-9002}"
K3D_HOST_PORT_OPENSEARCH="${K3D_HOST_PORT_OPENSEARCH:-9200}"
K3D_HOST_PORT_OPENSEARCH_DASHBOARDS="${K3D_HOST_PORT_OPENSEARCH_DASHBOARDS:-5601}"
K3D_HOST_PORT_OPENFGA_HTTP="${K3D_HOST_PORT_OPENFGA_HTTP:-9080}"
K3D_HOST_PORT_OPENFGA_GRPC="${K3D_HOST_PORT_OPENFGA_GRPC:-9081}"
K3D_HOST_PORT_TEMPORAL_FRONTEND="${K3D_HOST_PORT_TEMPORAL_FRONTEND:-7233}"
K3D_HOST_PORT_TEMPORAL_UI="${K3D_HOST_PORT_TEMPORAL_UI:-8233}"
K3D_HOST_PORT_PROMETHEUS="${K3D_HOST_PORT_PROMETHEUS:-9090}"
K3D_HOST_PORT_GRAFANA="${K3D_HOST_PORT_GRAFANA:-3002}"

MODE="once"
for arg in "$@"; do
  case "$arg" in
    --wait) MODE="wait" ;;
    --stack=*) STACK_MODE="${arg#*=}" ;;
    --namespace=*) K3D_NAMESPACE="${arg#*=}" ;;
    --release=*) HELM_RELEASE="${arg#*=}" ;;
    --cluster=*) K3D_CLUSTER="${arg#*=}" ;;
    --timeout=*) TIMEOUT="${arg#*=}" ;;
    --interval=*) INTERVAL="${arg#*=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: check-k3d-services.sh [options]

Checks the services deployed by `make k3d-up` in fred-deployment-factory.

Options:
  --wait                 Poll until healthy or timeout
  --stack=auto|base|extended
  --cluster=<name>       Default: fred
  --namespace=<name>     Default: fred
  --release=<name>       Default: fred-stack
  --timeout=<seconds>    Default: 0 in once mode, 300 in wait mode
  --interval=<seconds>   Default: 5
  -h, --help             Show help

Environment overrides:
  K3D_CLUSTER, K3D_NAMESPACE, HELM_RELEASE, STACK_MODE
  K3D_HOST_PORT_* values matching the Makefile
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "wait" && "$TIMEOUT" == "0" ]]; then
  TIMEOUT=300
fi

for bin in kubectl k3d docker curl nc; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required tool: $bin" >&2
    exit 2
  }
done

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=""; R=""; Y=""; B=""; D=""; N=""
fi

STACK="$STACK_MODE"
detect_stack() {
  if [[ "$STACK_MODE" == "base" || "$STACK_MODE" == "extended" ]]; then
    STACK="$STACK_MODE"
    return
  fi

  if command -v helm >/dev/null 2>&1; then
    local helm_values
    helm_values="$(helm get values "$HELM_RELEASE" -n "$K3D_NAMESPACE" 2>/dev/null || true)"
    if grep -Eq '^stack:[[:space:]]*extended([[:space:]]|$)' <<<"$helm_values"; then
      STACK="extended"
      return
    fi
    if grep -Eq '^stack:[[:space:]]*base([[:space:]]|$)' <<<"$helm_values"; then
      STACK="base"
      return
    fi
  fi

  if kubectl get deploy clickhouse -n "$K3D_NAMESPACE" >/dev/null 2>&1 \
    || kubectl get deploy prometheus -n "$K3D_NAMESPACE" >/dev/null 2>&1 \
    || kubectl get deploy grafana -n "$K3D_NAMESPACE" >/dev/null 2>&1; then
    STACK="extended"
  else
    STACK="base"
  fi
}

BASE_DEPLOYMENTS=(
  postgres
  keycloak
  seaweedfs
  openfga
  opensearch
  opensearch-dashboards
  temporal
  temporal-ui
)

EXTENDED_DEPLOYMENTS=(
  clickhouse
  prometheus
  grafana
)

BASE_JOBS=(
  opensearch-post-install
  openfga-post-install
  temporal-post-install
)

EXTENDED_JOBS=(
  clickhouse-post-install
)

SERVICE_RESULTS=()
WORKLOAD_RESULTS=()
JOB_RESULTS=()
CONTAINER_RESULTS=()
CLUSTER_RESULTS=()

record_ok() {
  local kind="$1" name="$2" detail="$3"
  printf "%s%-12s%s %-24s %sOK%s %s\n" "$D" "$kind" "$N" "$name" "$G" "$N" "$detail"
}

record_fail() {
  local kind="$1" name="$2" detail="$3"
  printf "%s%-12s%s %-24s %sFAIL%s %s\n" "$D" "$kind" "$N" "$name" "$R" "$N" "$detail"
}

http_code() {
  local url="$1"
  shift
  curl -ksS -o /dev/null -m 5 -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

check_http() {
  local label="$1" url="$2"
  shift 2
  local code
  code="$(http_code "$url" "$@")"
  if [[ -n "$code" && "$code" != "000" ]]; then
    SERVICE_RESULTS+=("ok|$label|$url -> HTTP $code")
  else
    SERVICE_RESULTS+=("fail|$label|$url unreachable")
  fi
}

check_tcp() {
  local label="$1" host="$2" port="$3"
  if nc -z -G 3 "$host" "$port" >/dev/null 2>&1; then
    SERVICE_RESULTS+=("ok|$label|$host:$port accepting TCP")
  else
    SERVICE_RESULTS+=("fail|$label|$host:$port closed")
  fi
}

cluster_checks() {
  if ! k3d cluster get "$K3D_CLUSTER" >/dev/null 2>&1; then
    CLUSTER_RESULTS+=("fail|cluster|${K3D_CLUSTER}|cluster does not exist")
    return 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -Eq "^k3d-${K3D_CLUSTER}-server-0$"; then
    CLUSTER_RESULTS+=("fail|cluster|${K3D_CLUSTER}|server container is not running")
    return 1
  fi

  kubectl config use-context "k3d-${K3D_CLUSTER}" >/dev/null 2>&1 || {
    CLUSTER_RESULTS+=("fail|cluster|${K3D_CLUSTER}|cannot switch kubectl context to k3d-${K3D_CLUSTER}")
    return 1
  }

  kubectl get namespace "$K3D_NAMESPACE" >/dev/null 2>&1 || {
    CLUSTER_RESULTS+=("fail|namespace|${K3D_NAMESPACE}|namespace not found")
    return 1
  }

  CLUSTER_RESULTS+=("ok|cluster|${K3D_CLUSTER}|context k3d-${K3D_CLUSTER}, namespace ${K3D_NAMESPACE} reachable")
  return 0
}

render_k3d_containers() {
  local name status restart_count started_at
  local expected=(
    "k3d-${K3D_CLUSTER}-server-0"
    "k3d-${K3D_CLUSTER}-agent-0"
    "k3d-${K3D_CLUSTER}-serverlb"
  )

  for name in "${expected[@]}"; do
    if ! docker inspect "$name" >/dev/null 2>&1; then
      CONTAINER_RESULTS+=("fail|container|$name|missing")
      continue
    fi

    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo unknown)"
    restart_count="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo '?')"
    started_at="$(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null || echo unknown)"
    if [[ "$status" == "running" ]]; then
      CONTAINER_RESULTS+=("ok|container|$name|status=${status}, restarts=${restart_count}, started=${started_at}")
    else
      CONTAINER_RESULTS+=("fail|container|$name|status=${status}, restarts=${restart_count}, started=${started_at}")
    fi
  done
}

render_workloads() {
  local deployment desired ready available
  local workloads=("${BASE_DEPLOYMENTS[@]}")
  if [[ "$STACK" == "extended" ]]; then
    workloads+=("${EXTENDED_DEPLOYMENTS[@]}")
  fi

  for deployment in "${workloads[@]}"; do
    if ! kubectl get deploy "$deployment" -n "$K3D_NAMESPACE" >/dev/null 2>&1; then
      WORKLOAD_RESULTS+=("fail|deployment|$deployment|missing")
      continue
    fi
    desired="$(kubectl get deploy "$deployment" -n "$K3D_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="$(kubectl get deploy "$deployment" -n "$K3D_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    available="$(kubectl get deploy "$deployment" -n "$K3D_NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
    if [[ "$ready" == "$desired" && "$available" == "$desired" ]]; then
      WORKLOAD_RESULTS+=("ok|deployment|$deployment|ready ${ready}/${desired}")
    else
      WORKLOAD_RESULTS+=("fail|deployment|$deployment|ready ${ready}/${desired}, available ${available}/${desired}")
    fi
  done
}

render_jobs() {
  local jobs=("${BASE_JOBS[@]}")
  if [[ "$STACK" == "extended" ]]; then
    jobs+=("${EXTENDED_JOBS[@]}")
  fi

  local job succeeded failed active
  for job in "${jobs[@]}"; do
    if ! kubectl get job "$job" -n "$K3D_NAMESPACE" >/dev/null 2>&1; then
      JOB_RESULTS+=("fail|job|$job|missing")
      continue
    fi
    succeeded="$(kubectl get job "$job" -n "$K3D_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
    failed="$(kubectl get job "$job" -n "$K3D_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)"
    active="$(kubectl get job "$job" -n "$K3D_NAMESPACE" -o jsonpath='{.status.active}' 2>/dev/null || echo 0)"
    succeeded="${succeeded:-0}"
    failed="${failed:-0}"
    active="${active:-0}"
    if [[ "$succeeded" -ge 1 ]]; then
      JOB_RESULTS+=("ok|job|$job|completed")
    elif [[ "$active" -ge 1 ]]; then
      JOB_RESULTS+=("fail|job|$job|still running")
    elif [[ "$failed" -ge 1 ]]; then
      JOB_RESULTS+=("fail|job|$job|failed ${failed} time(s)")
    else
      JOB_RESULTS+=("fail|job|$job|not completed")
    fi
  done
}

render_services() {
  check_tcp "postgres" "127.0.0.1" "$K3D_HOST_PORT_POSTGRES"
  check_http "keycloak" "http://127.0.0.1:${K3D_HOST_PORT_KEYCLOAK}/realms/master"
  check_http "seaweedfs-s3" "http://127.0.0.1:${K3D_HOST_PORT_SEAWEEDFS_S3}/"
  check_http "seaweedfs-filer" "http://127.0.0.1:${K3D_HOST_PORT_SEAWEEDFS_FILER}/"
  check_http "seaweedfs-master" "http://127.0.0.1:${K3D_HOST_PORT_SEAWEEDFS_MASTER}/dir/status"
  check_http "opensearch" "https://127.0.0.1:${K3D_HOST_PORT_OPENSEARCH}/"
  check_http "opensearch-dashboards" "http://127.0.0.1:${K3D_HOST_PORT_OPENSEARCH_DASHBOARDS}/login"
  check_http "openfga-http" "http://127.0.0.1:${K3D_HOST_PORT_OPENFGA_HTTP}/healthz"
  check_tcp "openfga-grpc" "127.0.0.1" "$K3D_HOST_PORT_OPENFGA_GRPC"
  check_tcp "temporal-frontend" "127.0.0.1" "$K3D_HOST_PORT_TEMPORAL_FRONTEND"
  check_http "temporal-ui" "http://127.0.0.1:${K3D_HOST_PORT_TEMPORAL_UI}/"

  if [[ "$STACK" == "extended" ]]; then
    check_http "clickhouse-http" "http://127.0.0.1:${K3D_HOST_PORT_CLICKHOUSE_HTTP}/ping"
    check_tcp "clickhouse-native" "127.0.0.1" "$K3D_HOST_PORT_CLICKHOUSE_NATIVE"
    check_http "prometheus" "http://127.0.0.1:${K3D_HOST_PORT_PROMETHEUS}/-/healthy"
    check_http "grafana" "http://127.0.0.1:${K3D_HOST_PORT_GRAFANA}/api/health"
  fi
}

render_summary() {
  local elapsed="$1"
  local failures=0
  local row status kind name detail

  printf "%sFred k3d service check%s\n" "$B" "$N"
  printf "cluster=%s namespace=%s release=%s stack=%s elapsed=%ss\n" \
    "$K3D_CLUSTER" "$K3D_NAMESPACE" "$HELM_RELEASE" "$STACK" "$elapsed"

  printf "\n%sk3d containers%s\n" "$B" "$N"
  for row in "${CONTAINER_RESULTS[@]}"; do
    IFS='|' read -r status kind name detail <<<"$row"
    if [[ "$status" == "ok" ]]; then
      record_ok "$kind" "$name" "$detail"
    else
      record_fail "$kind" "$name" "$detail"
      failures=$((failures + 1))
    fi
  done

  printf "\n%sCluster access%s\n" "$B" "$N"
  for row in "${CLUSTER_RESULTS[@]}"; do
    IFS='|' read -r status kind name detail <<<"$row"
    if [[ "$status" == "ok" ]]; then
      record_ok "$kind" "$name" "$detail"
    else
      record_fail "$kind" "$name" "$detail"
      failures=$((failures + 1))
    fi
  done

  printf "\n%sWorkloads%s\n" "$B" "$N"
  for row in "${WORKLOAD_RESULTS[@]}"; do
    IFS='|' read -r status kind name detail <<<"$row"
    if [[ "$status" == "ok" ]]; then
      record_ok "$kind" "$name" "$detail"
    else
      record_fail "$kind" "$name" "$detail"
      failures=$((failures + 1))
    fi
  done

  printf "\n%sPost-install jobs%s\n" "$B" "$N"
  for row in "${JOB_RESULTS[@]}"; do
    IFS='|' read -r status kind name detail <<<"$row"
    if [[ "$status" == "ok" ]]; then
      record_ok "$kind" "$name" "$detail"
    else
      record_fail "$kind" "$name" "$detail"
      failures=$((failures + 1))
    fi
  done

  printf "\n%sLocal endpoints%s\n" "$B" "$N"
  for row in "${SERVICE_RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"$row"
    if [[ "$status" == "ok" ]]; then
      record_ok "endpoint" "$name" "$detail"
    else
      record_fail "endpoint" "$name" "$detail"
      failures=$((failures + 1))
    fi
  done

  printf "\n"
  if [[ "$failures" -eq 0 ]]; then
    printf "%sAll checks passed.%s\n" "$G" "$N"
    return 0
  fi

  printf "%s%d check(s) failed.%s\n" "$R" "$failures" "$N"
  return 1
}

run_once() {
  SERVICE_RESULTS=()
  WORKLOAD_RESULTS=()
  JOB_RESULTS=()
  CONTAINER_RESULTS=()
  CLUSTER_RESULTS=()

  render_k3d_containers
  if cluster_checks; then
    detect_stack
    render_workloads
    render_jobs
  else
    STACK="unknown"
    WORKLOAD_RESULTS+=("fail|deployment|kubernetes|skipped because cluster is not reachable")
    JOB_RESULTS+=("fail|job|post-install-jobs|skipped because cluster is not reachable")
  fi
  render_services
}

main() {
  local start_ts now elapsed
  start_ts="$(date +%s)"

  while true; do
    run_once
    now="$(date +%s)"
    elapsed=$((now - start_ts))
    if render_summary "$elapsed"; then
      exit 0
    fi

    if [[ "$MODE" != "wait" ]]; then
      exit 1
    fi

    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
      printf "%sTimed out after %ss.%s\n" "$R" "$TIMEOUT" "$N" >&2
      exit 1
    fi

    sleep "$INTERVAL"
    printf "\n"
  done
}

main
