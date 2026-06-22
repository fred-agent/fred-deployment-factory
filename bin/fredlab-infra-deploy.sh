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
CHART_DIR="${CHART_DIR:-${REPO_ROOT}/helm/fredlab-infra}"
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

set +e
helm "${args[@]}"
status=$?
set -e

if [[ -n "${current_values_file}" ]]; then
  rm -f "${current_values_file}"
fi

exit "${status}"
