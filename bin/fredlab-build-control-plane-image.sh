#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
IMAGE="${IMAGE:-control-plane-backend}"
FRED_REPO_DIR="${FRED_REPO_DIR:-${HOME}/fred}"

if [[ ! -f "${FRED_REPO_DIR}/apps/control-plane-backend/dockerfiles/Dockerfile-prod" ]]; then
  echo "Cannot find Control Plane Dockerfile in ${FRED_REPO_DIR}."
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
    args:
      - build
      - -f
      - apps/control-plane-backend/dockerfiles/Dockerfile-prod
      - -t
      - ${IMAGE_URI}
      - .
images:
  - ${IMAGE_URI}
EOF

echo "Building ${IMAGE_URI}"
echo "Fred source repository: ${FRED_REPO_DIR}"

gcloud builds submit "${FRED_REPO_DIR}" \
  --region="${REGION}" \
  --config="${BUILD_CONFIG}"

echo "Image pushed: ${IMAGE_URI}"
echo "Use with Helm:"
echo "  repository=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}"
echo "  tag=${TAG}"
