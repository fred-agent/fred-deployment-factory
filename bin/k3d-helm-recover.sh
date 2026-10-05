#!/usr/bin/env bash
set -Eeuo pipefail

# Bring a Helm release Helm refuses to upgrade back to a state it accepts.
#
#   bin/k3d-helm-recover.sh <release> <namespace> [timeout]
#
# - pending-* (an interrupted run, e.g. Ctrl+C): roll back to the last
#   revision that was deployed.
# - failed with a deployed revision behind it: nothing, Helm upgrades it.
# - pending-* or failed and never deployed: uninstall it, so it can be
#   installed again. Never when a PersistentVolumeClaim of the release exists:
#   uninstalling deletes the claims and the data in them. That case stops for a
#   person to decide.
#
# Statuses and revisions are read from Helm's JSON output: its table puts the
# date, several words long, before the status.

c_warn='\033[1;33m'; c_err='\033[1;31m'; c_reset='\033[0m'
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }

# Existing callers may keep their current context; Helmfile callers provide one.
helm() { command helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} "$@"; }
kubectl() { command kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

release="${1:?release}"; ns="${2:?namespace}"; timeout="${3:-20m}"

status="$(helm status "$release" -n "$ns" -o json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || true)"
[[ "$status" == pending-* || "$status" == failed ]] || exit 0

last_deployed="$(helm history "$release" -n "$ns" -o json 2>/dev/null | python3 -c '
import json, sys
revisions = [h["revision"] for h in json.load(sys.stdin) if h["status"] in ("deployed", "superseded")]
print(revisions[-1] if revisions else "")')"

if [[ "$status" == failed && -n "$last_deployed" ]]; then
  exit 0
elif [[ -n "$last_deployed" ]]; then
  warn "Release '$release' is $status: rolling back to revision $last_deployed"
  helm rollback "$release" "$last_deployed" -n "$ns" --wait --timeout "$timeout" >/dev/null
  exit 0
fi

claims="$(kubectl get pvc -n "$ns" -o json | python3 -c '
import json, sys
release = sys.argv[1]
print(" ".join(p["metadata"]["name"] for p in json.load(sys.stdin)["items"]
               if (p["metadata"].get("annotations") or {}).get("meta.helm.sh/release-name") == release))' "$release")"
if [[ -n "$claims" ]]; then
  fail "Release '$release' is $status and has no deployed revision, but it owns volumes ($claims):
       uninstalling it would delete their data. Decide by hand: 'helm history $release -n $ns',
       then 'helm rollback' to a revision, or 'helm uninstall' if the data can go."
fi
warn "Release '$release' is $status and was never deployed: uninstalling it first"
helm uninstall "$release" -n "$ns" --wait >/dev/null
