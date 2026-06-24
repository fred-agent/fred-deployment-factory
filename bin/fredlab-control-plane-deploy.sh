#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-control-plane-deploy.sh migrate <tag>
  bin/fredlab-control-plane-deploy.sh start <tag>
  bin/fredlab-control-plane-deploy.sh disable

Flags:
  -fast   skip the keycloak-provision hook for a fast app-only redeploy (identity is
          already provisioned). Same effect as SKIP_PROVISION=1. Position-independent,
          e.g. `start -fast <tag>` or `start <tag> -fast`.

Environment overrides:
  PROJECT_ID, REGION, REPOSITORY, IMAGE, NAMESPACE, SECRET_VALUES_FILE
EOF
}

FAST=0
POSITIONAL=()
for _arg in "$@"; do
  case "$_arg" in
    -fast|--fast) FAST=1 ;;
    *) POSITIONAL+=("$_arg") ;;
  esac
done
ACTION="${POSITIONAL[0]:-}"
TAG="${POSITIONAL[1]:-${TAG:-}}"

if [[ -z "${ACTION}" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${CHART_DIR:-${REPO_ROOT}/helm/fredlab-infra}"
SECRET_VALUES_FILE="${SECRET_VALUES_FILE:-${CHART_DIR}/fredlab-secrets.values.yaml}"
NAMESPACE="${NAMESPACE:-default}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
IMAGE="${IMAGE:-control-plane-backend}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}}"

if [[ ! -f "${SECRET_VALUES_FILE}" ]]; then
  echo "Missing secret values file: ${SECRET_VALUES_FILE}"
  exit 1
fi

helm_upgrade() {
  local current_values_file=""
  local args=(
    upgrade --install fredlab-infra "${CHART_DIR}"
    --namespace "${NAMESPACE}"
    -f "${SECRET_VALUES_FILE}"
    --timeout 10m
  )

  # -fast (or SKIP_PROVISION=1) skips the keycloak-provision hook for a fast app-only
  # redeploy: the realm/clients/temporal-ui auth flow already exist after the first deploy,
  # and helm blocks on that (now heavy) hook on every upgrade. Without it the hook is
  # re-enabled, so a normal deploy always (re)provisions — set explicitly so a prior skip
  # never sticks via --reset-then-reuse-values.
  if [[ "${FAST:-0}" == "1" || "${SKIP_PROVISION:-0}" == "1" ]]; then
    args+=(--set keycloak.provision.enabled=false)
  else
    args+=(--set keycloak.provision.enabled=true)
  fi

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
  helm "${args[@]}" "$@"
  local status=$?
  set -e

  if [[ -n "${current_values_file}" ]]; then
    rm -f "${current_values_file}"
  fi

  return "${status}"
}

case "${ACTION}" in
  migrate)
    if [[ -z "${TAG}" ]]; then
      echo "Missing image tag for migrate."
      usage
      exit 1
    fi
    helm_upgrade \
      --set controlPlane.migration.enabled=true \
      --set controlPlane.enabled=false \
      --set controlPlane.image.repository="${IMAGE_REPOSITORY}" \
      --set controlPlane.image.tag="${TAG}"
    ;;
  start)
    if [[ -z "${TAG}" ]]; then
      echo "Missing image tag for start."
      usage
      exit 1
    fi
    helm_upgrade \
      --set controlPlane.migration.enabled=false \
      --set controlPlane.enabled=true \
      --set controlPlane.image.repository="${IMAGE_REPOSITORY}" \
      --set controlPlane.image.tag="${TAG}"
    ;;
  disable)
    helm_upgrade \
      --set controlPlane.migration.enabled=false \
      --set controlPlane.enabled=false
    ;;
  *)
    echo "Unknown action: ${ACTION}"
    usage
    exit 1
    ;;
esac
