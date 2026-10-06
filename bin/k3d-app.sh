#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy an application on the k3d instance from its own repository.
#
#   bin/k3d-app.sh [deploy|validate|uninstall]     (run by `make k3d-app*`)
#
# DIR names the application: a checkout whose deploy/k3d/ holds a
# helmfile.yaml.gotmpl, or that directory itself. It is the application's whole
# contract with this instance (docs/LOCAL-DEVELOPMENT.md → "The k3d application
# contract"):
#   helmfile.yaml.gotmpl  its releases: its charts and its k3d values, ordinary Helmfile
#   build                 optional: builds its images, writes $K3D_APP_OUT/images.txt
#                         (one reference per line) and $K3D_APP_OUT/images.yaml (Helm values)
#   prepare, finish       optional: run before and after its releases are synced
# This script owns the cluster side: the context, the image import, release
# recovery and the sync. It never changes the current kubectl context.
#
# Environment (defaults in the Makefile): DIR; VALUES, extra values files applied
# last to every release (space-separated); K3D_CLUSTER, K3D_NAMESPACE, HELM_TIMEOUT,
# K3D_HOST_PORT_FRONTEND, K3D_HOST_PORT_GRAFANA (passed on to the hooks).

c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'
step() { printf "%b[STEP]%b %s\n" "$c_step" "$c_reset" "$1"; }
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
info() { printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }
# Never stop without saying where: any unexpected failure names its line and command.
trap 'fail "unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

here="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-deploy}"
[[ "$mode" =~ ^(deploy|validate|uninstall)$ ]] || fail "usage: $0 [deploy|validate|uninstall]"
for tool in helm helmfile jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done

# ── The application ──────────────────────────────────────────────────────────
[[ -n "${DIR:-}" ]] || fail "DIR is required: make k3d-app DIR=../fred"
dir="$(cd "$DIR" 2>/dev/null && pwd)" || fail "DIR=$DIR: no such directory"
if [[ -f "$dir/deploy/k3d/helmfile.yaml.gotmpl" ]]; then app="$dir/deploy/k3d"
elif [[ -f "$dir/helmfile.yaml.gotmpl" ]]; then app="$dir"
else fail "DIR=$DIR has neither deploy/k3d/helmfile.yaml.gotmpl nor helmfile.yaml.gotmpl"; fi
values=()
for f in ${VALUES:-}; do
  [[ -f "$f" ]] || fail "values file not found: $f"
  values+=(--values "$(realpath "$f")")
done

export KUBE_CONTEXT="k3d-${K3D_CLUSTER:-fred}"
export K3D_CLUSTER="${K3D_CLUSTER:-fred}" K3D_NAMESPACE="${K3D_NAMESPACE:-fred}"
export K3D_HOST_PORT_FRONTEND="${K3D_HOST_PORT_FRONTEND:-8088}" K3D_HOST_PORT_GRAFANA="${K3D_HOST_PORT_GRAFANA:-3002}"
timeout="${HELM_TIMEOUT:-20m}"
case "$timeout" in
  *m) timeout_s=$(( ${timeout%m} * 60 )) ;;
  *s) timeout_s="${timeout%s}" ;;
  *) timeout_s="$timeout"; timeout="${timeout}s" ;;
esac

# Build outputs live in this repository's cache, one directory per application.
repo="$(git -C "$app" rev-parse --show-toplevel 2>/dev/null || echo "$app")"
export K3D_APP_OUT="$here/.cache/k3d-apps/$(basename "$repo")-$(printf '%s' "$app" | sha256sum | cut -c1-8)"
mkdir -p "$K3D_APP_OUT"
[[ -f "$K3D_APP_OUT/images.yaml" ]] || echo '{}' >"$K3D_APP_OUT/images.yaml"
export K3D_IMAGE_VALUES="$K3D_APP_OUT/images.yaml"

branch="$(git -C "$app" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
commit="$(git -C "$app" rev-parse --short HEAD 2>/dev/null || echo '?')"
dirty="$(git -C "$app" status --porcelain 2>/dev/null | grep -qv '^??' && echo ' + uncommitted changes' || true)"
info "Application: $app ($branch @ $commit$dirty)"

state=(helmfile --file "$app/helmfile.yaml.gotmpl" --kube-context "$KUBE_CONTEXT" --namespace "$K3D_NAMESPACE")
render() {
  # Helm lint keeps null deletion markers the schema refuses; template validates the merged values.
  "${state[@]}" lint --skip-deps --args "--skip-schema-validation" "${values[@]}" >/dev/null \
    || fail "helm lint failed (rerun: ${state[*]} lint)"
  "${state[@]}" template --skip-deps "${values[@]}" >/dev/null \
    || fail "rendering failed (rerun: ${state[*]} template)"
}
hook() {
  [[ -e "$app/$1" ]] || return 0
  [[ -x "$app/$1" ]] || fail "$app/$1 is not executable"
  step "Run $1"
  (cd "$app" && "./$1") || fail "$1 failed"
}
releases() {
  "${state[@]}" list --output json | jq -r --arg ns "$K3D_NAMESPACE" \
    '.[] | select(.enabled) | "\(.name) \(if .namespace == "" then $ns else .namespace end)"'
}

# ── Validate: no build, no cluster change ───────────────────────────────────
if [[ "$mode" == validate ]]; then
  render
  if [[ "$(cat "$K3D_IMAGE_VALUES")" == '{}' ]]; then
    ok "Lint and render passed, with the charts' default images (no build yet)"
  else
    ok "Lint and render passed, with the images of the last build ($K3D_IMAGE_VALUES)"
  fi
  exit 0
fi

command -v kubectl >/dev/null || fail "kubectl is required"
kubectl --context "$KUBE_CONTEXT" get secret fred-secrets -n "$K3D_NAMESPACE" -o name >/dev/null 2>&1 \
  || fail "no Secret fred-secrets in context '$KUBE_CONTEXT', namespace '$K3D_NAMESPACE': run 'make k3d-up' first"

# ── Uninstall: the releases go, the data stays in the infrastructure ─────────
if [[ "$mode" == uninstall ]]; then
  while read -r release ns; do
    claims="$(kubectl --context "$KUBE_CONTEXT" get pvc -n "$ns" -o json | jq -r --arg r "$release" \
      '[.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $r) | .metadata.name] | join(" ")')"
    [[ -z "$claims" ]] || fail "release '$release' owns volumes ($claims): uninstalling it deletes their data. Decide by hand."
  done < <(releases)
  step "Uninstall the releases of $app"
  "${state[@]}" destroy --skip-deps
  ok "Uninstalled; the data stays in the infrastructure"
  exit 0
fi

# ── Deploy ───────────────────────────────────────────────────────────────────
# Render before building: a values mistake costs seconds, not a build.
render
if [[ -e "$app/build" ]]; then
  rm -f "$K3D_APP_OUT/images.txt" "$K3D_APP_OUT/images.yaml"
  hook build
  [[ -s "$K3D_APP_OUT/images.txt" && -s "$K3D_APP_OUT/images.yaml" ]] \
    || fail "build wrote no images.txt and images.yaml in \$K3D_APP_OUT ($K3D_APP_OUT)"
  render
  mapfile -t images < <(grep -v '^[[:space:]]*$' "$K3D_APP_OUT/images.txt")
  step "Copy the images into the cluster"
  "$here/bin/k3d-prefetch-images.sh" "$K3D_CLUSTER" "${images[@]}"
fi
hook prepare
# A release left pending (Ctrl+C) or a first install that failed: Helm refuses
# both. Go back to the last deployed revision, or start over when there is none.
while read -r release ns; do
  "$here/bin/k3d-helm-recover.sh" "$release" "$ns" "$timeout"
done < <(releases)
step "Sync the releases (waits until every pod is ready, up to $timeout)"
if ! "${state[@]}" sync --skip-deps --wait --timeout "$timeout_s" "${values[@]}" >/dev/null; then
  warn "Pods not ready in namespace '$K3D_NAMESPACE':"
  kubectl --context "$KUBE_CONTEXT" get pods -n "$K3D_NAMESPACE" --no-headers \
    | awk '$3 != "Completed" && $2 !~ /^([0-9]+)\/\1$/' >&2 || true
  kubectl --context "$KUBE_CONTEXT" get events -n "$K3D_NAMESPACE" --field-selector type=Warning \
    --sort-by=.lastTimestamp | tail -n 15 >&2 || true
  fail "Sync failed (details: ${state[*]} sync)"
fi
ok "Releases synced"
hook finish
