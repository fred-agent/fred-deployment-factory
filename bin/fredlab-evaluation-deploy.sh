#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-evaluation-deploy.sh migrate <tag>
  bin/fredlab-evaluation-deploy.sh start <tag>
  bin/fredlab-evaluation-deploy.sh worker <tag>
  bin/fredlab-evaluation-deploy.sh disable

Actions:
  migrate  run the alembic migration job against the `evaluation` DB (no app pods)
  start    deploy backend + worker together off <tag>
  worker   deploy ONLY the worker off <tag>, leaving the running backend untouched
  disable  scale backend + worker down

The evaluator uses TWO distinct images built at the SAME tag:
  - fred-evaluation-api     (backend + migration job)
  - fred-evaluation-worker  (Temporal worker)
`start` deploys both — a backend with no worker just queues campaigns forever.

Environment overrides:
  PROJECT_ID, REGION, REPOSITORY, NAMESPACE, SECRET_VALUES_FILE
  API_IMAGE      (default: fred-evaluation-api)
  WORKER_IMAGE   (default: fred-evaluation-worker)
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
API_IMAGE="${API_IMAGE:-fred-evaluation-api}"
WORKER_IMAGE="${WORKER_IMAGE:-fred-evaluation-worker}"
API_IMAGE_REPOSITORY="${API_IMAGE_REPOSITORY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${API_IMAGE}}"
WORKER_IMAGE_REPOSITORY="${WORKER_IMAGE_REPOSITORY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_IMAGE}}"

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
      --set fredEvaluation.migration.enabled=true \
      --set fredEvaluation.enabled=false \
      --set fredEvaluationWorker.enabled=false \
      --set fredEvaluation.image.repository="${API_IMAGE_REPOSITORY}" \
      --set fredEvaluation.image.tag="${TAG}"
    ;;
  start)
    if [[ -z "${TAG}" ]]; then
      echo "Missing image tag for start."
      usage
      exit 1
    fi
    # Backend submits campaign workflows to the `evaluation` Temporal queue; the worker
    # drains it. Deploy both off the SAME tag so campaigns actually complete — a backend
    # with no worker just queues work forever. Note the two DISTINCT images.
    helm_upgrade \
      --set fredEvaluation.migration.enabled=false \
      --set fredEvaluation.enabled=true \
      --set fredEvaluation.image.repository="${API_IMAGE_REPOSITORY}" \
      --set fredEvaluation.image.tag="${TAG}" \
      --set fredEvaluationWorker.enabled=true \
      --set fredEvaluationWorker.image.repository="${WORKER_IMAGE_REPOSITORY}" \
      --set fredEvaluationWorker.image.tag="${TAG}"
    ;;
  worker)
    if [[ -z "${TAG}" ]]; then
      echo "Missing image tag for worker."
      usage
      exit 1
    fi
    # Enable ONLY the worker. helm_upgrade reuses existing release values, so the running
    # backend is left as-is; this adds the worker off <tag> (use the backend's tag). The
    # worker reuses the fred-evaluation-config ConfigMap, so its settings match the API.
    helm_upgrade \
      --set fredEvaluationWorker.enabled=true \
      --set fredEvaluationWorker.image.repository="${WORKER_IMAGE_REPOSITORY}" \
      --set fredEvaluationWorker.image.tag="${TAG}"
    ;;
  disable)
    helm_upgrade \
      --set fredEvaluation.enabled=false \
      --set fredEvaluationWorker.enabled=false
    ;;
  *)
    echo "Unknown action: ${ACTION}"
    usage
    exit 1
    ;;
esac
