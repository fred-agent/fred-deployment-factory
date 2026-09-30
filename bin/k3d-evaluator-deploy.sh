#!/usr/bin/env bash
set -Eeuo pipefail

# Build the evaluation application's three images (API, worker, UI) from a
# fred-agent-evaluator checkout and deploy its chart on the k3d instance, with
# this repository's instance values. Fred must already run (`make k3d-fred`).
#
#   bin/k3d-evaluator-deploy.sh       (run by `make k3d-evaluator`)
#
# Environment (defaults in the Makefile):
#   EVALUATOR_DIR           the fred-agent-evaluator checkout to build from
#   EVALUATOR_CHART         chart directory, or an oci:// reference to a published chart
#   EVALUATOR_CHART_VERSION chart version, with an oci:// chart
#   EVALUATOR_VALUES        values files, space-separated, applied in order
#   EVALUATOR_RELEASE, K3D_CLUSTER, K3D_NAMESPACE, HELM_TIMEOUT

c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'
step() { printf "%b[STEP]%b %s\n" "$c_step" "$c_reset" "$1"; }
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
info() { printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }
# Never stop without saying where: any unexpected failure names its line and command.
trap 'fail "unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

here="$(cd "$(dirname "$0")/.." && pwd)"
evaluator_dir="$(cd "${EVALUATOR_DIR:?}" 2>/dev/null && pwd)" \
  || fail "EVALUATOR_DIR=$EVALUATOR_DIR: no such directory (a fred-agent-evaluator checkout)"
chart="${EVALUATOR_CHART:-$evaluator_dir/deploy/charts/fred-evaluator}"
release="${EVALUATOR_RELEASE:-fred-evaluator}"
cluster="${K3D_CLUSTER:-fred}"
ns="${K3D_NAMESPACE:-fred}"
timeout="${HELM_TIMEOUT:-20m}"
read -r -a values_files <<<"${EVALUATOR_VALUES:-k3d-apps/fred-evaluator/values.yaml}"

# ── Preflight ────────────────────────────────────────────────────────────────
kubectl config use-context "k3d-$cluster" >/dev/null 2>&1 \
  || fail "no k3d cluster '$cluster': run 'make k3d-up' first"
kubectl get deployment control-plane-backend -n "$ns" >/dev/null 2>&1 \
  || fail "Fred is not deployed in namespace '$ns': run 'make k3d-fred' first"
for f in "${values_files[@]}"; do
  [[ -f "$here/$f" ]] || fail "values file not found: $f"
done
branch="$(git -C "$evaluator_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
commit="$(git -C "$evaluator_dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
dirty="$(git -C "$evaluator_dir" status --porcelain 2>/dev/null | grep -qv '^??' && echo ' + uncommitted changes' || true)"
info "Evaluator checkout: $evaluator_dir ($branch @ $commit$dirty)"
info "Chart: $chart${EVALUATOR_CHART_VERSION:+ $EVALUATOR_CHART_VERSION}"

# ── Images ───────────────────────────────────────────────────────────────────
# chart value -> "<app directory> <make target> <image suffix>"
declare -A builds=(
  [api]="fred-evaluation-backend docker-build-api "
  [worker]="fred-evaluation-backend docker-build-worker -worker"
  [ui]="fred-evaluation-frontend docker-build "
)
logs="$(mktemp -d "${TMPDIR:-/tmp}/k3d-evaluator-build.XXXXXX")"
image_sets=()
images=()
for component in api worker ui; do
  read -r app target suffix <<<"${builds[$component]}"
  image="$(make -s -C "$evaluator_dir/apps/$app" --eval 'print-%: ; @echo $($*)' print-IMAGE_FULL)${suffix}"
  step "Build $component"
  # One retry: a dependency download cut mid-build is the usual failure.
  if ! make -C "$evaluator_dir/apps/$app" "$target" >"$logs/$component.log" 2>&1; then
    warn "Build $component failed; retrying once (log: $logs/$component.log)"
    make -C "$evaluator_dir/apps/$app" "$target" >"$logs/$component.log" 2>&1 \
      || { tail -n 30 "$logs/$component.log" >&2; fail "Build $component failed twice (log: $logs/$component.log)"; }
  fi
  id="$(docker image inspect --format '{{.Id}}' "$image")"
  repository="${image%:*}"
  tag="k3d-${id#sha256:}"; tag="${tag:0:16}"
  docker tag "$image" "$repository:$tag"
  images+=("$repository:$tag")
  image_sets+=(--set-string "$component.image.repository=$repository" --set-string "$component.image.tag=$tag")
  ok "Build $component -> $repository:$tag"
done
rm -rf "$logs"

step "Copy the images into the cluster"
"$here/bin/k3d-prefetch-images.sh" "$cluster" "${images[@]}"

# ── Helm ─────────────────────────────────────────────────────────────────────
# A release left pending (Ctrl+C) or a first install that failed: Helm refuses
# both. Go back to the last deployed revision, or start over when there is none.
"$here/bin/k3d-helm-recover.sh" "$release" "$ns" "$timeout"
helm_args=(upgrade --install "$release" "$chart" --namespace "$ns" --wait --timeout "$timeout")
[[ -n "${EVALUATOR_CHART_VERSION:-}" ]] && helm_args+=(--version "$EVALUATOR_CHART_VERSION")
for f in "${values_files[@]}"; do helm_args+=(-f "$here/$f"); done
step "Deploy release '$release' (waits until every pod is ready, up to $timeout)"
if ! helm "${helm_args[@]}" "${image_sets[@]}" >/dev/null; then
  warn "Pods not ready in namespace '$ns':"
  kubectl get pods -n "$ns" -l "app.kubernetes.io/instance=$release" --no-headers >&2 || true
  kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 15 >&2 || true
  fail "Deploy release '$release' failed"
fi
ok "Deploy release '$release'"
info "Fred shows it at http://localhost:${K3D_HOST_PORT_FRONTEND:-8088}/apps/evaluation/ once a platform admin"
info "enables the 'evaluation' application for a team (Admin > Features, filter 'app')."
