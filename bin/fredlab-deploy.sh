#!/usr/bin/env bash
set -Eeuo pipefail

# Generic Fredlab app deploy. One shared helm_upgrade(), one per-component flag map.
# Replaces the former per-app scripts (control-plane / frontend / agents /
# knowledge-flow / evaluation), which were ~95% identical boilerplate.

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-deploy.sh <component> <action> [tag] [-fast]

Components and their actions:
  control-plane     migrate | start | disable
  frontend          start | disable
  agents            start | disable
  knowledge-flow    migrate | start | worker | disable
  evaluation        migrate | start | worker | disable

Actions:
  migrate  run the alembic migration job only (app pods scaled down)
  start    deploy the component (backend + worker where applicable) off <tag>
  worker   deploy ONLY the worker off <tag>, leaving the running backend untouched
  disable  scale the component down

Flags:
  -fast    skip the keycloak-provision hook for a fast app-only redeploy (identity is
           already provisioned). Same effect as SKIP_PROVISION=1. Position-independent,
           e.g. `start -fast <tag>` or `start <tag> -fast`.

Environment overrides:
  PROJECT_ID, REGION, REPOSITORY, NAMESPACE, SECRET_VALUES_FILE, IMAGE
  GCP_SERVICE_ACCOUNT   (agents / knowledge-flow; default: fredlab-knowledge-flow-gcs@<project>.iam.gserviceaccount.com)
  VERTEX_PROJECT        (knowledge-flow; default: PROJECT_ID)
  API_IMAGE, WORKER_IMAGE  (evaluation; defaults: fred-evaluation-api / fred-evaluation-worker)
  REGISTRY_BASE         override the image registry+namespace prefix entirely (default:
                        <REGION>-docker.pkg.dev/<PROJECT_ID>/<REPOSITORY>, i.e. Artifact
                        Registry). Each component still appends its own image short name.
                        e.g. REGISTRY_BASE=ghcr.io/thalesgroup/fred-agent to pull public
                        CI-built images directly instead of Artifact Registry.
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
COMPONENT="${POSITIONAL[0]:-}"
ACTION="${POSITIONAL[1]:-}"
TAG="${POSITIONAL[2]:-${TAG:-}}"

if [[ -z "${COMPONENT}" || -z "${ACTION}" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${CHART_DIR:-${REPO_ROOT}/gcp-c1/helm}"
SECRET_VALUES_FILE="${SECRET_VALUES_FILE:-${CHART_DIR}/fredlab-secrets.values.yaml}"
NAMESPACE="${NAMESPACE:-default}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT:-fredlab-knowledge-flow-gcs@${PROJECT_ID}.iam.gserviceaccount.com}"
VERTEX_PROJECT="${VERTEX_PROJECT:-${PROJECT_ID}}"

if [[ ! -f "${SECRET_VALUES_FILE}" ]]; then
  echo "Missing secret values file: ${SECRET_VALUES_FILE}"
  exit 1
fi

# REGISTRY_BASE lets a caller point every image at a different registry+namespace
# (e.g. ghcr.io/thalesgroup/fred-agent) instead of this project's Artifact Registry —
# see `usage()`. Default behaviour (Artifact Registry) is unchanged when unset.
img_repo() { printf '%s/%s\n' "${REGISTRY_BASE:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}}" "$1"; }

need_tag() {
  if [[ -z "${TAG}" ]]; then
    echo "Missing image tag for ${COMPONENT} ${ACTION}."
    usage
    exit 1
  fi
}

bad_action() {
  echo "Unknown action '${ACTION}' for component '${COMPONENT}'."
  usage
  exit 1
}

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

case "${COMPONENT}" in
  control-plane)
    IMAGE="${IMAGE:-control-plane-backend}"
    REPO="$(img_repo "${IMAGE}")"
    case "${ACTION}" in
      migrate)
        need_tag
        helm_upgrade \
          --set controlPlane.migration.enabled=true \
          --set controlPlane.enabled=false \
          --set controlPlane.image.repository="${REPO}" \
          --set controlPlane.image.tag="${TAG}"
        ;;
      start)
        need_tag
        helm_upgrade \
          --set controlPlane.migration.enabled=false \
          --set controlPlane.enabled=true \
          --set controlPlane.image.repository="${REPO}" \
          --set controlPlane.image.tag="${TAG}"
        ;;
      disable)
        helm_upgrade \
          --set controlPlane.migration.enabled=false \
          --set controlPlane.enabled=false
        ;;
      *) bad_action ;;
    esac
    ;;

  frontend)
    IMAGE="${IMAGE:-fred-frontend}"
    REPO="$(img_repo "${IMAGE}")"
    case "${ACTION}" in
      start)
        need_tag
        helm_upgrade \
          --set fredFrontend.enabled=true \
          --set fredFrontend.image.repository="${REPO}" \
          --set fredFrontend.image.tag="${TAG}" \
          --set fredFrontend.upstreams.fredAgents="http://fred-agents:8080" \
          --set fredFrontend.upstreams.knowledgeFlow="http://knowledge-flow-backend:8080"
        ;;
      disable)
        helm_upgrade --set fredFrontend.enabled=false
        ;;
      *) bad_action ;;
    esac
    ;;

  agents)
    IMAGE="${IMAGE:-fred-agents}"
    REPO="$(img_repo "${IMAGE}")"
    case "${ACTION}" in
      start)
        need_tag
        helm_upgrade \
          --set fredAgents.enabled=true \
          --set fredAgents.image.repository="${REPO}" \
          --set fredAgents.image.tag="${TAG}" \
          --set fredAgents.serviceAccount.gcpServiceAccount="${GCP_SERVICE_ACCOUNT}"
        ;;
      disable)
        helm_upgrade --set fredAgents.enabled=false
        ;;
      *) bad_action ;;
    esac
    ;;

  knowledge-flow)
    IMAGE="${IMAGE:-knowledge-flow-backend}"
    REPO="$(img_repo "${IMAGE}")"
    case "${ACTION}" in
      migrate)
        need_tag
        helm_upgrade \
          --set knowledgeFlow.migration.enabled=true \
          --set knowledgeFlow.enabled=false \
          --set knowledgeFlow.image.repository="${REPO}" \
          --set knowledgeFlow.image.tag="${TAG}"
        ;;
      start)
        need_tag
        # Backend submits ingestion workflows to the `ingestion` Temporal queue; the
        # worker drains it. Deploy both off the SAME image/tag/GSA so ingestion actually
        # completes — a backend with no worker just queues work forever.
        helm_upgrade \
          --set knowledgeFlow.migration.enabled=false \
          --set knowledgeFlow.enabled=true \
          --set knowledgeFlow.image.repository="${REPO}" \
          --set knowledgeFlow.image.tag="${TAG}" \
          --set knowledgeFlow.serviceAccount.gcpServiceAccount="${GCP_SERVICE_ACCOUNT}" \
          --set knowledgeFlow.config.models.project="${VERTEX_PROJECT}" \
          --set knowledgeFlowWorker.enabled=true \
          --set knowledgeFlowWorker.image.repository="${REPO}" \
          --set knowledgeFlowWorker.image.tag="${TAG}" \
          --set knowledgeFlowWorker.serviceAccount.gcpServiceAccount="${GCP_SERVICE_ACCOUNT}"
        ;;
      worker)
        need_tag
        # Enable ONLY the worker; helm_upgrade reuses existing release values, so the
        # running backend is left as-is. The worker reuses the knowledge-flow-config
        # ConfigMap, so its Temporal/GCS/model settings match the backend automatically.
        helm_upgrade \
          --set knowledgeFlowWorker.enabled=true \
          --set knowledgeFlowWorker.image.repository="${REPO}" \
          --set knowledgeFlowWorker.image.tag="${TAG}" \
          --set knowledgeFlowWorker.serviceAccount.gcpServiceAccount="${GCP_SERVICE_ACCOUNT}"
        ;;
      disable)
        helm_upgrade \
          --set knowledgeFlow.enabled=false \
          --set knowledgeFlowWorker.enabled=false
        ;;
      *) bad_action ;;
    esac
    ;;

  evaluation)
    # The evaluator uses TWO distinct images built at the SAME tag:
    #   fred-evaluation-api (backend + migration job) and fred-evaluation-worker.
    API_IMAGE="${API_IMAGE:-fred-evaluation-api}"
    WORKER_IMAGE="${WORKER_IMAGE:-fred-evaluation-worker}"
    API_REPO="$(img_repo "${API_IMAGE}")"
    WORKER_REPO="$(img_repo "${WORKER_IMAGE}")"
    case "${ACTION}" in
      migrate)
        need_tag
        helm_upgrade \
          --set fredEvaluation.migration.enabled=true \
          --set fredEvaluation.enabled=false \
          --set fredEvaluationWorker.enabled=false \
          --set fredEvaluation.image.repository="${API_REPO}" \
          --set fredEvaluation.image.tag="${TAG}"
        ;;
      start)
        need_tag
        # Backend submits campaign workflows to the `evaluation` Temporal queue; the
        # worker drains it. Deploy both off the SAME tag — note the two DISTINCT images.
        helm_upgrade \
          --set fredEvaluation.migration.enabled=false \
          --set fredEvaluation.enabled=true \
          --set fredEvaluation.image.repository="${API_REPO}" \
          --set fredEvaluation.image.tag="${TAG}" \
          --set fredEvaluationWorker.enabled=true \
          --set fredEvaluationWorker.image.repository="${WORKER_REPO}" \
          --set fredEvaluationWorker.image.tag="${TAG}"
        ;;
      worker)
        need_tag
        helm_upgrade \
          --set fredEvaluationWorker.enabled=true \
          --set fredEvaluationWorker.image.repository="${WORKER_REPO}" \
          --set fredEvaluationWorker.image.tag="${TAG}"
        ;;
      disable)
        helm_upgrade \
          --set fredEvaluation.enabled=false \
          --set fredEvaluationWorker.enabled=false
        ;;
      *) bad_action ;;
    esac
    ;;

  *)
    echo "Unknown component: ${COMPONENT}"
    usage
    exit 1
    ;;
esac
