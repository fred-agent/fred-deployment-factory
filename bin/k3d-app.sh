#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy an application on the k3d instance.
#
#   bin/k3d-app.sh [deploy|validate|uninstall]     (run by `make k3d-app*`)
#
# APP names one of this repository's application definitions, k3d-apps/<APP>/:
# its published release (RELEASE, or the version its helmfile pins), or, with
# DIR, the checkout it develops (the helmfile reads K3D_APP_CHECKOUT for the
# chart; the checkout's deploy/k3d/build makes the images). If that checkout
# supplies deploy/k3d/helmfile.yaml.gotmpl, its definition and hooks take precedence.
# DIR alone names an
# application defined in its own repository: a checkout whose deploy/k3d/ holds a
# helmfile.yaml.gotmpl, or that directory itself. Either directory is the
# application's whole contract with this instance (docs/LOCAL-DEVELOPMENT.md →
# "The k3d application contract"):
#   helmfile.yaml.gotmpl  its releases: its charts and its k3d values, ordinary Helmfile
#   identities.yaml       optional: its service identities in Keycloak (bin/k3d-identities)
#   build                 optional: builds its images, writes $K3D_APP_OUT/images.txt
#                         (one reference per line) and $K3D_APP_OUT/images.yaml (Helm values)
#   registration.yaml     optional: what it registers with Fred, stored in the cluster;
#                         every registration reaches the helmfiles as K3D_REGISTRATIONS,
#                         and a changed one redeploys Fred, as last deployed, first
#   prepare, finish       optional: run before and after its releases are synced
# This script owns the cluster side: the context, the identities, the image
# import, release recovery and the sync. It never changes the current kubectl context.
#
# Environment: ENV (swift by default), APP, RELEASE, DIR; VALUES, extra values files applied
# last to every release (space-separated); FRED_LIBS (pypi | local) and FRED_REPO,
# which fred the hooks and the helmfile build against; K3D_CLUSTER, K3D_NAMESPACE,
# HELM_TIMEOUT and the selected profile's ports and URLs (passed on to the hooks).

c_step='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'
step() { printf "%b[STEP]%b %s\n" "$c_step" "$c_reset" "$1"; }
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
info() { printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }
# Never stop without saying where: any unexpected failure names its line and command.
trap 'fail "unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

here="$(cd "$(dirname "$0")/.." && pwd)"
source "$here/bin/k3d-environment.sh"
export K3D_FACTORY_ROOT="$here"
mode="${1:-deploy}"
[[ "$mode" =~ ^(deploy|validate|uninstall)$ ]] || fail "usage: $0 [deploy|validate|uninstall]"
for tool in helm helmfile jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done

# ── The application ──────────────────────────────────────────────────────────
defined="$( { cd "$here/k3d-apps" 2>/dev/null && ls -d -- */ 2>/dev/null; } | tr -d / | tr '\n' ' ' || true)"
checkout=""
if [[ -n "${APP:-}" ]]; then
  app="$here/k3d-apps/$APP"
  [[ "$APP" != */* && -f "$app/helmfile.yaml.gotmpl" ]] || fail "APP=$APP is not defined here; defined: $defined"
  if [[ -n "${DIR:-}" ]]; then
    [[ -z "${RELEASE:-}" ]] || fail "RELEASE deploys a published release and DIR a checkout: choose one"
    checkout="$(cd "$DIR" 2>/dev/null && pwd)" || fail "DIR=$DIR: no such directory"
    [[ -x "$checkout/deploy/k3d/build" ]] || fail "DIR=$DIR has no executable deploy/k3d/build"
    # A checkout may own its complete deployment, not only its image build.
    if [[ -f "$checkout/deploy/k3d/helmfile.yaml.gotmpl" ]]; then
      app="$checkout/deploy/k3d"
    fi
  fi
else
  [[ -n "${DIR:-}" ]] || fail "APP or DIR is required: make k3d-app APP=<one of: $defined>, or DIR=<checkout>"
  dir="$(cd "$DIR" 2>/dev/null && pwd)" || fail "DIR=$DIR: no such directory"
  if [[ -f "$dir/deploy/k3d/helmfile.yaml.gotmpl" ]]; then app="$dir/deploy/k3d"
  elif [[ -f "$dir/helmfile.yaml.gotmpl" ]]; then app="$dir"
  else fail "DIR=$DIR has neither deploy/k3d/helmfile.yaml.gotmpl nor helmfile.yaml.gotmpl (defined here, with APP: $defined)"; fi
fi
[[ -z "${RELEASE:-}" || "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || fail "RELEASE must be a release version such as 3.6.0, not '$RELEASE'"
export K3D_APP_CHECKOUT="$checkout" RELEASE="${RELEASE:-}"
# The checkout's build, when APP develops one; otherwise the application's own.
build_dir="${checkout:+$checkout/deploy/k3d}"; build_dir="${build_dir:-$app}"
values=()
value_files=()
for f in ${VALUES:-}; do
  [[ -f "$f" ]] || fail "values file not found: $f"
  values+=(--values "$(realpath "$f")")
  value_files+=("$(realpath "$f")")
done
export K3D_APP_VALUES="$(printf '%s\n' "${value_files[@]}")"

timeout="${HELM_TIMEOUT:-20m}"
case "$timeout" in
  *m) timeout_s=$(( ${timeout%m} * 60 )) ;;
  *s) timeout_s="${timeout%s}" ;;
  *) timeout_s="$timeout"; timeout="${timeout}s" ;;
esac

# Isolate generated values and logs by cluster, namespace, definition and checkout.
repo="$(git -C "$app" rev-parse --show-toplevel 2>/dev/null || echo "$app")"
build_key="$(printf '%s\n' "$app" "$build_dir" | sha256sum | cut -c1-12)"
export K3D_APP_OUT="$here/.cache/k3d-apps/$K3D_CLUSTER/$K3D_NAMESPACE/${APP:-$(basename "$repo")}-$build_key"
mkdir -p "$K3D_APP_OUT"
# Without a build, the charts' own images, never those of an earlier build.
if [[ ! -e "$build_dir/build" || ! -f "$K3D_APP_OUT/images.yaml" ]]; then
  echo '{}' >"$K3D_APP_OUT/images.yaml"
fi
export K3D_IMAGE_VALUES="$K3D_APP_OUT/images.yaml"

# Registrations with Fred: one ConfigMap per application, so none restates another.
# K3D_REGISTRATIONS is a JSON object, registration name → registration.yaml text:
# those stored in the namespace (none when validating), this application's own file
# in place of its stored one.
registration="$app/registration.yaml"
# Named after APP, or the application's directory (the checkout's, for its deploy/k3d).
registration_name="${APP:-$(basename "${app%/deploy/k3d}")}"
registration_name="$(printf '%s' "$registration_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
registration_label="fred-deployment-factory/registration"
export K3D_REGISTRATIONS="$K3D_APP_OUT/registrations.json"
stored='{}'
write_registrations() {
  if [[ -f "$registration" ]]; then
    jq --arg name "$registration_name" --rawfile text "$registration" '.[$name] = $text' <<<"$stored" >"$K3D_REGISTRATIONS"
  else
    printf '%s\n' "$stored" >"$K3D_REGISTRATIONS"
  fi
}
write_registrations

info "Environment: $ENV, context: $KUBE_CONTEXT, namespace: $K3D_NAMESPACE"

describe() {
  local branch commit dirty
  branch="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  commit="$(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?')"
  dirty="$(git -C "$1" status --porcelain 2>/dev/null | grep -qv '^??' && echo ' + uncommitted changes' || true)"
  echo "$branch @ $commit$dirty"
}
if [[ -n "$checkout" ]]; then info "Application: $APP, from $checkout ($(describe "$checkout"))"
elif [[ -n "${APP:-}" ]]; then info "Application: $APP, published release ${RELEASE:-pinned in k3d-apps/$APP/helmfile.yaml.gotmpl}"
else info "Application: $app ($(describe "$app"))"; fi

# Which fred the application builds against: its hooks and its helmfile read both.
export FRED_LIBS="${FRED_LIBS:-pypi}"
case "$FRED_LIBS" in
  pypi) info "Fred: the released libraries and charts (FRED_LIBS=pypi)" ;;
  local)
    [[ -n "${FRED_REPO:-}" ]] || fail "FRED_LIBS=local needs FRED_REPO, the path of YOUR fred checkout, e.g.
         export FRED_REPO=/path/to/your/fred
       or use the released fred: FRED_LIBS=pypi"
    FRED_REPO="$(cd "$FRED_REPO" 2>/dev/null && pwd)" \
      || fail "FRED_REPO=${FRED_REPO}: no such directory. Set FRED_REPO to the path of your fred checkout."
    [[ -d "$FRED_REPO/libs" && -d "$FRED_REPO/deploy/charts" ]] \
      || fail "FRED_REPO=$FRED_REPO is not a fred checkout (no libs/ and deploy/charts/). Set FRED_REPO to the path of your fred checkout."
    export FRED_REPO
    info "Fred: libraries and charts from $FRED_REPO ($(describe "$FRED_REPO"))" ;;
  *) fail "FRED_LIBS must be pypi or local, not '$FRED_LIBS'" ;;
esac

state=(helmfile --file "$app/helmfile.yaml.gotmpl" --kube-context "$KUBE_CONTEXT" --namespace "$K3D_NAMESPACE")
render() {
  # Helm lint keeps null deletion markers the schema refuses; template validates the merged values.
  "${state[@]}" lint --skip-deps --args "--skip-schema-validation" "${values[@]}" >/dev/null \
    || fail "helm lint failed (rerun: ${state[*]} lint)"
  "${state[@]}" template --skip-deps "${values[@]}" >/dev/null \
    || fail "rendering failed (rerun: ${state[*]} template)"
}
hook() {
  local dir="${2:-$app}"
  [[ -e "$dir/$1" ]] || return 0
  [[ -x "$dir/$1" ]] || fail "$dir/$1 is not executable"
  step "Run $1"
  (cd "$dir" && "./$1") || fail "$1 failed"
}
releases() {
  "${state[@]}" list --output json | jq -r --arg ns "$K3D_NAMESPACE" \
    '.[] | select(.enabled) | "\(.name) \(if .namespace == "" then $ns else .namespace end)"'
}

identities() {
  [[ -f "$app/identities.yaml" ]] || return 0
  "$here/bin/k3d-identities" "$@" "$app/identities.yaml" || fail "identities.yaml refused"
}

# ── Validate: no build, no cluster change ───────────────────────────────────
if [[ "$mode" == validate ]]; then
  identities --check
  render
  if [[ "$(cat "$K3D_IMAGE_VALUES")" == '{}' ]]; then
    ok "Lint and render passed, with the charts' own images (no build)"
  else
    ok "Lint and render passed, with the images of the last build ($K3D_IMAGE_VALUES)"
  fi
  exit 0
fi

command -v kubectl >/dev/null || fail "kubectl is required"
kubectl --context "$KUBE_CONTEXT" get secret fred-secrets -n "$K3D_NAMESPACE" -o name >/dev/null 2>&1 \
  || fail "no Secret fred-secrets in context '$KUBE_CONTEXT', namespace '$K3D_NAMESPACE': run 'make k3d-up ENV=$ENV' first"
stored="$(kubectl --context "$KUBE_CONTEXT" get configmap -n "$K3D_NAMESPACE" -l "$registration_label" -o json \
  | jq -c --arg label "$registration_label" \
    'reduce .items[] as $c ({}; .[$c.metadata.labels[$label]] = $c.data["registration.yaml"])')" \
  || fail "cannot read the registrations with Fred in namespace '$K3D_NAMESPACE'"
[[ -n "$stored" ]] || stored='{}'
write_registrations
# Fred's definition serves the registrations (its helmfile reads K3D_REGISTRATIONS). How it
# was last deployed is kept in the cluster, so a changed registration redeploys it the
# same way, without a build (the images of its last one).
server_config="fred-registrations-server"
serves_registrations() { grep -qs K3D_REGISTRATIONS "$app"/*.gotmpl; }
serve_registrations() {
  local how
  how="$(kubectl --context "$KUBE_CONTEXT" get configmap "$server_config" -n "$K3D_NAMESPACE" -o json 2>/dev/null \
    | jq -r '.data | to_entries[] | "\(.key)=\(.value)"')" || how=""
  if [[ -z "$how" ]]; then
    warn "Fred serves it from its next deploy: make k3d-app APP=fred (as you deploy it)"
    return 0
  fi
  local -a deployed
  mapfile -t deployed <<<"$how"
  step "Redeploy Fred as last deployed (${deployed[*]}), without a build, to serve the registrations"
  env "${deployed[@]}" K3D_REUSE_IMAGES=1 "$here/bin/k3d-app.sh" deploy || fail "Fred could not serve the registrations"
}

# ── Uninstall: the releases go, the data stays in the infrastructure ─────────
if [[ "$mode" == uninstall ]]; then
  while read -r release ns; do
    claims="$(kubectl --context "$KUBE_CONTEXT" get pvc -n "$ns" -o json | jq -r --arg r "$release" \
      '[.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $r) | .metadata.name] | join(" ")')"
    [[ -z "$claims" ]] || fail "release '$release' owns volumes ($claims): uninstalling it deletes their data. Decide by hand."
  done < <(releases)
  step "Uninstall the releases of $app"
  "${state[@]}" destroy --skip-deps
  if serves_registrations; then
    kubectl --context "$KUBE_CONTEXT" delete configmap "$server_config" -n "$K3D_NAMESPACE" --ignore-not-found >/dev/null
  fi
  if [[ "$(jq --arg name "$registration_name" 'has($name)' <<<"$stored")" == true ]]; then
    step "Unregister '$registration_name' from Fred"
    kubectl --context "$KUBE_CONTEXT" delete configmap "fred-registration-$registration_name" -n "$K3D_NAMESPACE" >/dev/null
    serves_registrations || serve_registrations
  fi
  ok "Uninstalled; the data stays in the infrastructure"
  exit 0
fi

# ── Deploy ───────────────────────────────────────────────────────────────────
# Check and render before building: a mistake costs seconds, not a build.
identities --check
render
if [[ -n "${K3D_REUSE_IMAGES:-}" && -e "$build_dir/build" ]]; then
  [[ "$(cat "$K3D_IMAGE_VALUES")" != '{}' ]] \
    || fail "no earlier build to redeploy without one: run make k3d-app with the same APP and DIR"
elif [[ -e "$build_dir/build" ]]; then
  rm -f "$K3D_APP_OUT/images.txt" "$K3D_APP_OUT/images.yaml"
  # Product Makefiles accept IMAGE_TAG. Avoid sharing mutable build tags across checkouts.
  IMAGE_TAG="k3d-$K3D_CLUSTER-$build_key" hook build "$build_dir"
  [[ -s "$K3D_APP_OUT/images.txt" && -s "$K3D_APP_OUT/images.yaml" ]] \
    || fail "build wrote no images.txt and images.yaml in \$K3D_APP_OUT ($K3D_APP_OUT)"
  render
  mapfile -t images < <(grep -v '^[[:space:]]*$' "$K3D_APP_OUT/images.txt")
  step "Copy the images into the cluster"
  "$here/bin/k3d-prefetch-images.sh" "$K3D_CLUSTER" "${images[@]}"
fi
if [[ -f "$app/identities.yaml" ]]; then
  step "Provision the service identities (identities.yaml)"
  identities
fi
hook prepare
# Registered and served before the sync: a Knowledge Base's publish Job needs Fred to
# know its client already.
if [[ -f "$registration" \
    && "$(jq -r --arg name "$registration_name" '.[$name] // ""' <<<"$stored")" != "$(cat "$registration")" ]]; then
  step "Register '$registration_name' with Fred (registration.yaml)"
  kubectl --context "$KUBE_CONTEXT" create configmap "fred-registration-$registration_name" -n "$K3D_NAMESPACE" \
    --from-file=registration.yaml="$registration" --dry-run=client -o json \
    | jq --arg label "$registration_label" --arg name "$registration_name" '.metadata.labels[$label] = $name' \
    | kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null
  serves_registrations || serve_registrations
fi
# A release left pending (Ctrl+C) or a first install that failed: Helm refuses
# both. Go back to the last deployed revision, or start over when there is none.
while read -r release ns; do
  "$here/bin/k3d-helm-recover.sh" "$release" "$ns" "$timeout"
done < <(releases)
# While the sync waits, say every 30 s which pods are not ready yet and what each is
# doing (pulling an image, crashing, failing a probe): a long pull is not a hang.
watch_pods() {
  local start=$SECONDS pods pod reason event
  while sleep 30; do
    pods="$(kubectl --context "$KUBE_CONTEXT" get pods -n "$K3D_NAMESPACE" -o json 2>/dev/null | jq -r '
      .items[] | select(.status.phase != "Succeeded")
      | ([.status.initContainerStatuses[]?, .status.containerStatuses[]?] | map(select(.ready | not))) as $waiting
      | select(($waiting | length) > 0 or (.status.containerStatuses == null))
      | "\(.metadata.name) \($waiting[0].state.waiting.reason // (if $waiting[0].state.running then "started, not ready yet" else .status.phase end))"' \
      || true)"
    if [[ -z "$pods" ]]; then
      info "$(( (SECONDS - start) / 60 ))m$(printf %02d $(( (SECONDS - start) % 60 ))): every pod ready, Helm is finishing"
      continue
    fi
    info "$(( (SECONDS - start) / 60 ))m$(printf %02d $(( (SECONDS - start) % 60 ))): $(wc -l <<<"$pods") pod(s) not ready yet"
    while read -r pod reason; do
      event="$(kubectl --context "$KUBE_CONTEXT" get events -n "$K3D_NAMESPACE" -o json \
        --field-selector "involvedObject.name=$pod" 2>/dev/null \
        | jq -r '.items | sort_by(.lastTimestamp // .eventTime) | last | .message // ""' || true)"
      printf '         %s: %s%s\n' "$pod" "$reason" "${event:+ — ${event:0:140}}"
    done <<<"$pods"
  done
}
watch_pods &
watcher=$!
trap 'kill "$watcher" 2>/dev/null || true' EXIT
step "Sync the releases (waits until every pod is ready, up to $timeout; progress every 30 s)"
if ! "${state[@]}" sync --skip-deps --wait --timeout "$timeout_s" "${values[@]}" >/dev/null; then
  kill "$watcher" 2>/dev/null || true
  warn "Pods not ready in namespace '$K3D_NAMESPACE':"
  kubectl --context "$KUBE_CONTEXT" get pods -n "$K3D_NAMESPACE" --no-headers \
    | awk '$3 != "Completed" && $2 !~ /^([0-9]+)\/\1$/' >&2 || true
  kubectl --context "$KUBE_CONTEXT" get events -n "$K3D_NAMESPACE" --field-selector type=Warning \
    --sort-by=.lastTimestamp | tail -n 15 >&2 || true
  fail "Sync failed (details: ${state[*]} sync)"
fi
kill "$watcher" 2>/dev/null || true
ok "Releases synced"
if serves_registrations; then
  kubectl --context "$KUBE_CONTEXT" create configmap "$server_config" -n "$K3D_NAMESPACE" \
    --from-literal=APP="${APP:-}" --from-literal=DIR="${checkout:-${dir:-}}" --from-literal=RELEASE="${RELEASE:-}" \
    --from-literal=VALUES="${value_files[*]}" --from-literal=FRED_LIBS="$FRED_LIBS" \
    --from-literal=FRED_REPO="${FRED_REPO:-}" --dry-run=client -o json \
    | kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null
fi
hook finish
