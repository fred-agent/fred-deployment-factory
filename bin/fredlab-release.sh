#!/usr/bin/env bash
set -Eeuo pipefail
# Build app image(s) from ~/fred HEAD (or reuse a given tag) and write that tag into
# values-fredlab.yaml. Prints the tag. Does NOT commit/push and does NOT touch the cluster.
#
# Steady-state loop:
#   bin/fredlab-release.sh all -> git commit+push -> bin/fredlab-argocd-sync.sh -> fredlab-status.sh
#
#   bin/fredlab-release.sh all                 # build + bump all four app images
#   bin/fredlab-release.sh control-plane       # one app: build + bump its tag
#   bin/fredlab-release.sh frontend <tag>      # already built: just bump values to <tag>
#
# component | build-name (config/fredlab-images.tsv) | release-tag marker (values-fredlab.yaml)
COMPONENTS=(
  "control-plane  control-plane-backend   control-plane-backend"
  "frontend       frontend                fred-frontend"
  "fred-agents    fred-agents             fred-agents"
  "knowledge-flow knowledge-flow-backend  knowledge-flow-backend"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES="${REPO_ROOT}/argocd/fred-apps/values-fredlab.yaml"
# THE single knob for "where is the Fred monorepo" — used here for the tag AND, via the
# `$FRED_REPO_DIR` catalog sentinel (config/fredlab-images.tsv), for the build source.
# Default ~/fred; export FRED_REPO_DIR to point elsewhere. Set it in ONE place only.
FRED_REPO_DIR="${FRED_REPO_DIR:-${HOME}/fred}"

usage() {
  echo "Usage: bin/fredlab-release.sh <all|control-plane|frontend|fred-agents|knowledge-flow> [tag]"
}

# Echo "build-name marker" for a component name; non-zero if unknown.
resolve() {
  local target="$1" comp build marker
  for row in "${COMPONENTS[@]}"; do
    read -r comp build marker <<<"${row}"
    [[ "${comp}" == "${target}" ]] && { echo "${build} ${marker}"; return 0; }
  done
  return 1
}

# Rewrite the `# release-tag: <marker>` line(s) in values-fredlab.yaml to <tag>.
# The knowledge-flow-backend marker tags both the backend and the worker line.
bump_marker() {
  local marker="$1" tag="$2"
  sed -i -E "s|^( *tag: ).*(# release-tag: ${marker} *)\$|\1\"${tag}\" \2|" "${VALUES}"
}

# YYYYMMDD-swift-<shortsha> from ~/fred HEAD. Warning goes to stderr so stdout stays the tag.
compute_tag() {
  if ! git -C "${FRED_REPO_DIR}" diff --quiet || ! git -C "${FRED_REPO_DIR}" diff --cached --quiet; then
    echo "⚠ ${FRED_REPO_DIR} is dirty — the tag will not match the built content." >&2
  fi
  echo "$(date -u +%Y%m%d)-swift-$(git -C "${FRED_REPO_DIR}" rev-parse --short HEAD)"
}

COMPONENT="${1:-}"
TAG_ARG="${2:-}"
[[ -z "${COMPONENT}" ]] && { usage; exit 1; }

if [[ "${COMPONENT}" == "all" ]]; then
  if [[ -n "${TAG_ARG}" ]]; then
    TAG="${TAG_ARG}"
  else
    TAG="$(compute_tag)"
    "${SCRIPT_DIR}/fredlab-build" all "${TAG}"
  fi
  for row in "${COMPONENTS[@]}"; do
    read -r _comp _build marker <<<"${row}"
    bump_marker "${marker}" "${TAG}"
  done
  echo "${TAG}"
  exit 0
fi

MAP="$(resolve "${COMPONENT}" || true)"
[[ -z "${MAP}" ]] && { usage; exit 1; }
read -r BUILD_NAME MARKER <<<"${MAP}"

if [[ -n "${TAG_ARG}" ]]; then
  TAG="${TAG_ARG}"
else
  TAG="$(compute_tag)"
  "${SCRIPT_DIR}/fredlab-build" "${BUILD_NAME}" "${TAG}"
fi
bump_marker "${MARKER}" "${TAG}"
echo "${TAG}"
