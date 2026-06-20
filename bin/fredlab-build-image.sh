#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
FRED_REPO_DIR="${FRED_REPO_DIR:-${HOME}/fred}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"

IMAGE="${IMAGE:-}"
DOCKERFILE="${DOCKERFILE:-}"

if [[ -z "${IMAGE}" ]]; then
  echo "Missing IMAGE, for example: IMAGE=control-plane-backend"
  exit 1
fi

if [[ -z "${DOCKERFILE}" ]]; then
  echo "Missing DOCKERFILE, for example: DOCKERFILE=apps/control-plane-backend/dockerfiles/Dockerfile-prod"
  exit 1
fi

if [[ ! -f "${FRED_REPO_DIR}/${DOCKERFILE}" ]]; then
  echo "Cannot find Dockerfile: ${FRED_REPO_DIR}/${DOCKERFILE}"
  echo "Set FRED_REPO_DIR to the root of the Fred source repository."
  exit 1
fi

TAG="${1:-${TAG:-}}"
if [[ -z "${TAG}" ]]; then
  TAG="$(git -C "${FRED_REPO_DIR}" rev-parse --short HEAD)"
fi

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}"
BUILD_CONFIG="$(mktemp)"
trap 'rm -f "${BUILD_CONFIG}"' EXIT

cat > "${BUILD_CONFIG}" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    env:
      - DOCKER_BUILDKIT=1
    args:
      - build
      - -f
      - ${DOCKERFILE}
      - -t
      - ${IMAGE_URI}
      - ${BUILD_CONTEXT}
images:
  - ${IMAGE_URI}
EOF

echo "Building ${IMAGE_URI}"
echo "Fred source repository: ${FRED_REPO_DIR}"
echo "Dockerfile: ${DOCKERFILE}"
echo "Build context: ${BUILD_CONTEXT}"

gcloud builds submit "${FRED_REPO_DIR}" \
  --region="${REGION}" \
  --config="${BUILD_CONFIG}"

echo "Image pushed: ${IMAGE_URI}"
