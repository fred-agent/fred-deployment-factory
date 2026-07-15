#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-infra-deploy.sh

Environment overrides:
  NAMESPACE, SECRET_VALUES_FILE, CHART_DIR

This is the safe default command for upgrading the fredlab-infra release.
On an existing release it preserves currently enabled application components
such as Control Plane and Fred frontend.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${CHART_DIR:-${REPO_ROOT}/gcp-c1/helm}"
SECRET_VALUES_FILE="${SECRET_VALUES_FILE:-${CHART_DIR}/fredlab-secrets.values.yaml}"
NAMESPACE="${NAMESPACE:-default}"

if [[ ! -f "${SECRET_VALUES_FILE}" ]]; then
  echo "Missing secret values file: ${SECRET_VALUES_FILE}"
  exit 1
fi

current_values_file=""
args=(
  upgrade --install fredlab-infra "${CHART_DIR}"
  --namespace "${NAMESPACE}"
  -f "${SECRET_VALUES_FILE}"
  --timeout 10m
)

if helm status fredlab-infra --namespace "${NAMESPACE}" >/dev/null 2>&1; then
  if helm upgrade --help | grep -q -- "--reset-then-reuse-values"; then
    args+=(--reset-then-reuse-values)
  else
    current_values_file="$(mktemp)"
    helm get values fredlab-infra --namespace "${NAMESPACE}" -o yaml > "${current_values_file}"
    args+=(-f "${current_values_file}")
  fi
fi

# Self-healing reconcile for immutable StatefulSet fields.
#
# Kubernetes forbids in-place updates to most StatefulSet spec fields (notably
# volumeClaimTemplates). When the rendered chart differs from the live object in
# such a field, helm fails with:
#   StatefulSet.apps "<name>" is invalid: spec: Forbidden: updates to statefulset
#   spec for fields other than ...
#
# The safe, data-preserving reconcile is to delete only the StatefulSet controller
# with --cascade=orphan: the running pods and their PVCs are kept, and the next
# helm upgrade recreates the controller, which immediately re-adopts the existing
# pods. This makes the deploy idempotent and replayable with no manual step.
reconcile_immutable_statefulsets() {
  local out_file="$1"
  grep -q "updates to statefulset spec for fields other than" "${out_file}" || return 1
  if ! command -v kubectl >/dev/null 2>&1; then
    echo ">> kubectl not found; cannot auto-reconcile immutable StatefulSet drift." >&2
    return 1
  fi
  local names
  names="$(grep -oE 'StatefulSet\.apps "[^"]+" is invalid' "${out_file}" \
    | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"
  [[ -z "${names}" ]] && return 1
  local n
  for n in ${names}; do
    echo ">> Reconciling immutable StatefulSet '${n}' (--cascade=orphan keeps pods and PVCs; no data loss)..."
    kubectl delete statefulset "${n}" \
      --namespace "${NAMESPACE}" --cascade=orphan --ignore-not-found
  done
  return 0
}

status=0
attempt=1
max_attempts=3
while :; do
  out_file="$(mktemp)"
  set +e
  helm "${args[@]}" 2>&1 | tee "${out_file}"
  status=${PIPESTATUS[0]}
  set -e

  if [[ ${status} -eq 0 ]]; then
    rm -f "${out_file}"
    break
  fi

  if (( attempt < max_attempts )) && reconcile_immutable_statefulsets "${out_file}"; then
    rm -f "${out_file}"
    attempt=$((attempt + 1))
    echo ">> Retrying helm upgrade (attempt ${attempt}/${max_attempts}) after reconcile..."
    continue
  fi

  rm -f "${out_file}"
  break
done

if [[ -n "${current_values_file}" ]]; then
  rm -f "${current_values_file}"
fi

exit "${status}"
