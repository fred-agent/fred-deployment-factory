#!/usr/bin/env bash
set -Eeuo pipefail
# Build a fresh image from ~/fred HEAD (or use a given tag) and write that tag into
# values-fredlab.yaml. Prints the tag. Does NOT commit/push and does NOT touch the cluster.
# Loop: fredlab-release.sh <component> -> commit+push -> Sync in ArgoCD.
#
#   bin/fredlab-release.sh control-plane          # compute tag, build+push, bump values
#   bin/fredlab-release.sh control-plane <tag>     # already built: just bump values to <tag>

COMPONENT="${1:-}"
TAG_ARG="${2:-}"
case "${COMPONENT}" in
  control-plane) BUILD_NAME="control-plane-backend" ;;
  *) echo "Usage: bin/fredlab-release.sh <control-plane> [tag]"; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES="${REPO_ROOT}/argocd/fred-apps/values-fredlab.yaml"
FRED_REPO_DIR="${FRED_REPO_DIR:-${HOME}/fred}"

if [[ -n "${TAG_ARG}" ]]; then
  TAG="${TAG_ARG}"
else
  if ! git -C "${FRED_REPO_DIR}" diff --quiet || ! git -C "${FRED_REPO_DIR}" diff --cached --quiet; then
    echo "⚠ ${FRED_REPO_DIR} is dirty — the tag will not match the built content."
  fi
  TAG="$(date -u +%Y%m%d)-swift-$(git -C "${FRED_REPO_DIR}" rev-parse --short HEAD)"
  "${SCRIPT_DIR}/fredlab-build" "${BUILD_NAME}" "${TAG}"
fi

sed -i -E "s|^( *tag: ).*(# release-tag: ${BUILD_NAME} *)$|\1\"${TAG}\" \2|" "${VALUES}"

echo "${TAG}"
