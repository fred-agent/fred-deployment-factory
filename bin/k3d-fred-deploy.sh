#!/usr/bin/env bash
set -Eeuo pipefail

# Build Fred's four images from a fred checkout and deploy the official fred
# chart on the k3d instance, with this repository's instance values.
#
#   bin/k3d-fred-deploy.sh            (run by `make k3d-fred`)
#
# Rerun it after any change. Each image is tagged with its content digest, so a
# changed image rolls out through a normal `helm upgrade`, with no forced restart.
#
# Environment (defaults in the Makefile):
#   FRED_DIR            the fred checkout to build from
#   FRED_CHART          chart directory, or an oci:// reference to a published chart
#   FRED_CHART_VERSION  chart version, with an oci:// chart
#   FRED_VALUES         values files, space-separated, applied in order
#   FRED_RELEASE, K3D_CLUSTER, K3D_NAMESPACE, HELM_TIMEOUT
#   OPENAI_API_KEY      the model API key; read from $FRED_DIR/apps/fred-agents/config/.env when unset

c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'
step() { printf "%b[STEP]%b %s\n" "$c_step" "$c_reset" "$1"; }
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
info() { printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }

here="$(cd "$(dirname "$0")/.." && pwd)"
fred_dir="$(cd "${FRED_DIR:?}" 2>/dev/null && pwd)" || fail "FRED_DIR=$FRED_DIR: no such directory (a fred checkout)"
chart="${FRED_CHART:-$fred_dir/deploy/charts/fred}"
release="${FRED_RELEASE:-fred-app}"
cluster="${K3D_CLUSTER:-fred}"
ns="${K3D_NAMESPACE:-fred}"
timeout="${HELM_TIMEOUT:-20m}"
read -r -a values_files <<<"${FRED_VALUES:-k3d-apps/fred/values.yaml}"

# ── Preflight ────────────────────────────────────────────────────────────────
kubectl config use-context "k3d-$cluster" >/dev/null 2>&1 \
  || fail "no k3d cluster '$cluster': run 'make k3d-up' first"
kubectl get secret fred-secrets -n "$ns" >/dev/null 2>&1 \
  || fail "no Secret fred-secrets in namespace '$ns': run 'make k3d-up' first"
for f in "${values_files[@]}"; do
  [[ -f "$here/$f" ]] || fail "values file not found: $f"
done
branch="$(git -C "$fred_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
commit="$(git -C "$fred_dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
dirty="$(git -C "$fred_dir" status --porcelain 2>/dev/null | grep -qv '^??' && echo ' + uncommitted changes' || true)"
info "Fred checkout: $fred_dir ($branch @ $commit$dirty)"
info "Chart: $chart${FRED_CHART_VERSION:+ $FRED_CHART_VERSION}"

# ── Images ───────────────────────────────────────────────────────────────────
# app directory in the fred checkout -> the chart applications running its image
declare -A chart_apps=(
  [fred-agents]="fred-agents"
  [knowledge-flow-backend]="knowledge-flow-backend knowledge-flow-worker"
  [control-plane-backend]="control-plane-backend control-plane-worker"
  [frontend]="frontend"
)
logs="$(mktemp -d "${TMPDIR:-/tmp}/k3d-fred-build.XXXXXX")"
image_sets=()
images=()
for app in fred-agents knowledge-flow-backend control-plane-backend frontend; do
  image="$(make -s -C "$fred_dir/apps/$app" --eval 'print-%: ; @echo $($*)' print-IMAGE_FULL)"
  [[ -n "$image" ]] || fail "cannot read IMAGE_FULL from $fred_dir/apps/$app"
  step "Build $app"
  # One retry: a dependency download cut mid-build is the usual failure.
  if ! make -C "$fred_dir/apps/$app" docker-build >"$logs/$app.log" 2>&1; then
    warn "Build $app failed; retrying once (log: $logs/$app.log)"
    make -C "$fred_dir/apps/$app" docker-build >"$logs/$app.log" 2>&1 \
      || { tail -n 30 "$logs/$app.log" >&2; fail "Build $app failed twice (log: $logs/$app.log)"; }
  fi
  id="$(docker image inspect --format '{{.Id}}' "$image")"
  repository="${image%:*}"
  tag="k3d-${id#sha256:}"; tag="${tag:0:16}"
  docker tag "$image" "$repository:$tag"
  images+=("$repository:$tag")
  for chart_app in ${chart_apps[$app]}; do
    image_sets+=(--set-string "applications.$chart_app.image.repository=$repository"
                 --set-string "applications.$chart_app.image.tag=$tag")
  done
  ok "Build $app -> $repository:$tag"
done
rm -rf "$logs"

step "Copy the images into the cluster"
"$here/bin/k3d-prefetch-images.sh" "$cluster" "${images[@]}"

# ── Model API key ────────────────────────────────────────────────────────────
env_file="$fred_dir/apps/fred-agents/config/.env"
key="${OPENAI_API_KEY:-}"
if [[ -z "$key" && -f "$env_file" ]]; then
  key="$(sed -n 's/^OPENAI_API_KEY=//p' "$env_file" | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
fi
current="$(kubectl get secret fred-secrets -n "$ns" -o jsonpath='{.data.OPENAI_API_KEY}')"
key_changed=false
if [[ -z "$key" ]]; then
  warn "No model API key (OPENAI_API_KEY in $env_file, see 'make setup-env' in fred): Fred starts, every chat fails"
elif [[ "$(printf '%s' "$key" | base64 -w0)" != "$current" ]]; then
  patch="$(mktemp)"; trap 'rm -f "$patch"' EXIT
  printf '{"data":{"OPENAI_API_KEY":"%s"}}' "$(printf '%s' "$key" | base64 -w0)" >"$patch"
  kubectl patch secret fred-secrets -n "$ns" --type merge --patch-file "$patch" >/dev/null
  rm -f "$patch"
  key_changed=true
  ok "Model API key written to fred-secrets"
fi

# ── Helm ─────────────────────────────────────────────────────────────────────
# An interrupted run (Ctrl+C) leaves the release pending, and a failed first
# install leaves it without any deployed revision: Helm refuses both. Go back
# to the last deployed revision, or start over when there is none.
status="$(helm status "$release" -n "$ns" 2>/dev/null | awk '/^STATUS:/ {print $2}' || true)"
if [[ "$status" == pending-* || "$status" == failed ]]; then
  last_deployed="$(helm history "$release" -n "$ns" 2>/dev/null | awk '$3 == "deployed" || $3 == "superseded" {rev = $1} END {print rev}')"
  if [[ "$status" == failed && -n "$last_deployed" ]]; then
    :  # a failed upgrade: Helm upgrades it as it is
  elif [[ -n "$last_deployed" ]]; then
    warn "Release '$release' is $status: rolling back to revision $last_deployed"
    helm rollback "$release" "$last_deployed" -n "$ns" --wait --timeout "$timeout" >/dev/null
  else
    warn "Release '$release' is $status and was never deployed: uninstalling it first"
    helm uninstall "$release" -n "$ns" --wait >/dev/null
  fi
fi
installed=false
helm status "$release" -n "$ns" >/dev/null 2>&1 && installed=true
helm_args=(upgrade --install "$release" "$chart" --namespace "$ns" --wait --timeout "$timeout")
[[ -n "${FRED_CHART_VERSION:-}" ]] && helm_args+=(--version "$FRED_CHART_VERSION")
for f in "${values_files[@]}"; do helm_args+=(-f "$here/$f"); done
step "Deploy release '$release' (waits until every pod is ready, up to $timeout)"
if ! helm "${helm_args[@]}" "${image_sets[@]}" >/dev/null; then
  warn "Pods not ready in namespace '$ns':"
  kubectl get pods -n "$ns" --no-headers | awk '$3 != "Completed" && $2 !~ /^([0-9]+)\/\1$/' >&2 || true
  kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 15 >&2 || true
  fail "Deploy release '$release' failed"
fi
ok "Deploy release '$release'"

# A new key is read at start: pods already running keep the old one.
if $installed && $key_changed; then
  step "Restart the applications that read the model API key"
  kubectl rollout restart deployment -n "$ns" fred-agents knowledge-flow-backend knowledge-flow-worker >/dev/null
  kubectl rollout status deployment -n "$ns" fred-agents knowledge-flow-backend knowledge-flow-worker --timeout "$timeout" >/dev/null
  ok "Restart the applications that read the model API key"
fi

ok "Fred is running: http://localhost:${K3D_HOST_PORT_FRONTEND:-8088}"
if ! getent hosts keycloak >/dev/null; then
  warn "'keycloak' does not resolve on this machine: the browser cannot log in. Once, with sudo:"
  printf '       grep -qw keycloak /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts\n'
fi
# Until someone becomes platform_admin, Fred asks for the root bootstrap token
# right after the first login: show it only as long as it is needed.
if curl -fsS "http://localhost:${K3D_HOST_PORT_FRONTEND:-8088}/control-plane/v1/frontend/config" 2>/dev/null \
    | grep -Eq '"root_bootstrap_required": ?true'; then
  info "First login: open Fred, create your account with Register on the login page,"
  info "then paste this token where Fred asks for it; it makes you platform_admin:"
  printf '       %s\n' "$(kubectl get secret fred-secrets -n "$ns" -o jsonpath='{.data.CONTROL_PLANE_BOOTSTRAP_TOKEN}' | base64 -d)"
fi
