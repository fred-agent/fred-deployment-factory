#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-knowledge-flow-deploy.sh migrate <tag>
  bin/fredlab-knowledge-flow-deploy.sh start <tag>
  bin/fredlab-knowledge-flow-deploy.sh disable

Environment overrides:
  PROJECT_ID, REGION, REPOSITORY, IMAGE, NAMESPACE, SECRET_VALUES_FILE
  GCP_SERVICE_ACCOUNT   (default: fredlab-knowledge-flow-gcs@<project>.iam.gserviceaccount.com)
  VERTEX_PROJECT        (default: PROJECT_ID) — Vertex AI project for the models
EOF
}

ACTION="${1:-}"
TAG="${2:-${TAG:-}}"

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
IMAGE="${IMAGE:-knowledge-flow-backend}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}}"
GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT:-fredlab-knowledge-flow-gcs@${PROJECT_ID}.iam.gserviceaccount.com}"
VERTEX_PROJECT="${VERTEX_PROJECT:-${PROJECT_ID}}"

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
      --set knowledgeFlow.migration.enabled=true \
      --set knowledgeFlow.enabled=false \
      --set knowledgeFlow.image.repository="${IMAGE_REPOSITORY}" \
      --set knowledgeFlow.image.tag="${TAG}"
    ;;
  start)
    if [[ -z "${TAG}" ]]; then
      echo "Missing image tag for start."
      usage
      exit 1
    fi
    helm_upgrade \
      --set knowledgeFlow.migration.enabled=false \
      --set knowledgeFlow.enabled=true \
      --set knowledgeFlow.image.repository="${IMAGE_REPOSITORY}" \
      --set knowledgeFlow.image.tag="${TAG}" \
      --set knowledgeFlow.serviceAccount.gcpServiceAccount="${GCP_SERVICE_ACCOUNT}" \
      --set knowledgeFlow.config.models.project="${VERTEX_PROJECT}"
    ;;
  disable)
    helm_upgrade --set knowledgeFlow.enabled=false
    ;;
  *)
    echo "Unknown action: ${ACTION}"
    usage
    exit 1
    ;;
esac
