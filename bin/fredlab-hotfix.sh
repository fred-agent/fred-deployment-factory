#!/usr/bin/env bash
set -Eeuo pipefail
# Build one app-layer component from ANY branch of the fred monorepo (not just swift) and
# point gcp-c1/argocd/fred-apps/values-fredlab.yaml at that build — to test an unmerged
# fix live on fredlab before it ships in a real swift -> ghcr.io release.
#
# Wraps bin/fredlab-release.sh (worktree + Cloud Build + `tag:` bump) and additionally
# swaps `repository:` to Artifact Registry, since fred's own Build-and-push-docker.yml
# only triggers on push to swift / code/v* tags and will never build a feature branch —
# this local Cloud Build path is the only way to get an image from one. Like
# fredlab-release.sh, this script does NOT commit/push/sync — review the diff, then run
# the usual steady-state loop yourself.
#
# Rollback is plain git: `git revert` the commit you make from this script's diff. No
# extra state file to track — the ghcr.io repository + real release tag it replaced are
# right there in git history (and echoed in the HOTFIX comment this script writes).
#
# Usage:
#   bin/fredlab-hotfix.sh <control-plane|frontend|fred-agents|knowledge-flow> <branch>
#
# Example:
#   bin/fredlab-hotfix.sh knowledge-flow fix/memory-leak-1
#
# One worktree per branch, under WORKTREE_ROOT (default /tmp/fredlab-hotfix-worktrees) —
# created once, then fetched + reset to origin/<branch> on every subsequent call. Want to
# test several fixes together? Make a local integration branch that merges them
# (`git checkout -b test-integration && git merge fix/a fix/b`) and pass THAT branch name
# here — no special-casing needed, this script only ever cares about a branch name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES="${REPO_ROOT}/gcp-c1/argocd/fred-apps/values-fredlab.yaml"
WORKTREE_ROOT="${WORKTREE_ROOT:-/tmp/fredlab-hotfix-worktrees}"
MONOREPO_DIR="${FRED_REPO_DIR:-${HOME}/Fred/fred}"
REGION="${REGION:-europe-west1}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"

# component -> release-tag marker, matching bin/fredlab-release.sh's own table.
COMPONENTS=(
  "control-plane  control-plane-backend"
  "frontend       fred-frontend"
  "fred-agents    fred-agents"
  "knowledge-flow knowledge-flow-backend"
)

usage() {
  echo "Usage: bin/fredlab-hotfix.sh <control-plane|frontend|fred-agents|knowledge-flow> <branch>"
}

COMPONENT="${1:-}"
BRANCH="${2:-}"
[[ -z "${COMPONENT}" || -z "${BRANCH}" ]] && { usage; exit 1; }

MARKER=""
for row in "${COMPONENTS[@]}"; do
  read -r c m <<<"${row}"
  [[ "${c}" == "${COMPONENT}" ]] && MARKER="${m}"
done
[[ -z "${MARKER}" ]] && { usage; exit 1; }

if [[ ! -f "${VALUES}" ]]; then
  echo "Missing ${VALUES}"
  exit 1
fi

# --- one worktree per branch: create once, fetch + reset to origin on every call.
#     If the branch is ALREADY checked out somewhere else (e.g. you're actively
#     coding the fix in your own worktree), reuse that path instead of trying to
#     create a second one — git refuses to check out the same branch twice, and
#     without this, this script fails with "already used by worktree at ...". ---
SAFE_BRANCH="$(echo "${BRANCH}" | tr '/' '-')"
WORKTREE="${WORKTREE_ROOT}/${SAFE_BRANCH}"
mkdir -p "${WORKTREE_ROOT}"

git -C "${MONOREPO_DIR}" fetch origin "${BRANCH}"

EXISTING_WORKTREE="$(git -C "${MONOREPO_DIR}" worktree list --porcelain | awk -v b="refs/heads/${BRANCH}" '
  /^worktree / { wt=$2 }
  $0 == "branch " b { print wt }
')"

if [[ -n "${EXISTING_WORKTREE}" ]]; then
  WORKTREE="${EXISTING_WORKTREE}"
  echo "Branch already checked out at ${WORKTREE} — reusing it."
  git -C "${WORKTREE}" reset --hard "origin/${BRANCH}"
elif [[ -d "${WORKTREE}" ]]; then
  git -C "${WORKTREE}" checkout "${BRANCH}"
  git -C "${WORKTREE}" reset --hard "origin/${BRANCH}"
else
  git -C "${MONOREPO_DIR}" worktree add "${WORKTREE}" "${BRANCH}"
fi

SHORT_SHA="$(git -C "${WORKTREE}" rev-parse --short HEAD)"
TAG="$(date -u +%Y%m%d)-${SAFE_BRANCH}-${SHORT_SHA}"
STAMP="$(date -u +%Y-%m-%d)"

echo "=== Building ${COMPONENT} from ${BRANCH}@${SHORT_SHA} (worktree: ${WORKTREE}) ==="
# NOTE: call fredlab-build directly, NOT fredlab-release.sh with an explicit tag —
# fredlab-release.sh treats a supplied tag as "already built, just bump the values
# file" and skips the actual `gcloud builds submit` round entirely. MARKER doubles as
# the image/build-name here: every row in fredlab-release.sh's own COMPONENTS table
# uses the same string for both.
FRED_REPO_DIR="${WORKTREE}" "${SCRIPT_DIR}/fredlab-build" "${MARKER}" "${TAG}"
sed -i -E "s|^( *tag: ).*(# release-tag: ${MARKER} *)\$|\1\"${TAG}\" \2|" "${VALUES}"

NEW_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MARKER}"

# --- swap `repository:` for every values-fredlab.yaml block sharing this marker, and
#     stamp a HOTFIX comment recording provenance right above it. fredlab-release.sh
#     already bumped `tag:` above; this is the one piece it deliberately never touches. ---
awk -v marker="${MARKER}" \
    -v newrepo="    repository: ${NEW_REPO}" \
    -v comment="    # HOTFIX ${STAMP}: built from ${BRANCH}@${SHORT_SHA} via bin/fredlab-hotfix.sh, not a real release. Revert to ghcr.io/thalesgroup/fred-agent/${MARKER} + the last real vX.Y.Z tag once this ships on swift." '
{
  lines[NR] = $0
}
END {
  for (i = 1; i <= NR; i++) {
    if (lines[i] ~ /^ *tag: / && lines[i] ~ ("# release-tag: " marker "$")) {
      j = i - 1
      while (j > 0 && lines[j] !~ /^ *repository: /) j--
      if (j > 0) {
        # Re-running this script against an already-hotfixed block: overwrite the
        # previous HOTFIX comment in place instead of stacking a new one above it.
        if (j > 1 && lines[j - 1] ~ /^ *# HOTFIX /) {
          lines[j - 1] = comment
          lines[j] = newrepo
        } else {
          lines[j] = comment "\n" newrepo
        }
      }
    }
  }
  for (i = 1; i <= NR; i++) print lines[i]
}
' "${VALUES}" > "${VALUES}.tmp" && mv "${VALUES}.tmp" "${VALUES}"

echo
echo "Hotfix image ready: ${NEW_REPO}:${TAG}"
echo "values-fredlab.yaml updated (repository + tag, marker '${MARKER}'). Review the diff:"
echo "  git -C ${REPO_ROOT} diff gcp-c1/argocd/fred-apps/values-fredlab.yaml"
echo
echo "Then the usual steady-state loop:"
echo "  git commit -am 'hotfix(${COMPONENT}): test ${BRANCH}@${SHORT_SHA} on fredlab'"
echo "  git push"
echo "  bin/fredlab-argocd-sync.sh"
echo
echo "To roll back later: git revert <that commit>, then push + sync again."
