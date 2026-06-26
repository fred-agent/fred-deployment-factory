#!/usr/bin/env bash
set -Eeuo pipefail
# Trigger an ArgoCD sync of the fred-apps Application to the current main HEAD.
# No `argocd` CLI required — drives the Application via kubectl in the argocd namespace.
# This is step 3 of the steady-state loop:
#   bin/fredlab-release.sh all -> git push -> bin/fredlab-argocd-sync.sh -> bin/fredlab-status.sh
#
#   bin/fredlab-argocd-sync.sh            # sync fred-apps to origin/main HEAD
#   bin/fredlab-argocd-sync.sh <app>      # sync a different Application by name

APP="${1:-fred-apps}"
BRANCH="${BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

REV="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

# ArgoCD deploys from the remote, not your working tree. Warn if HEAD isn't pushed yet.
if ! git -C "${REPO_ROOT}" merge-base --is-ancestor "${REV}" "origin/${BRANCH}" 2>/dev/null; then
  echo "⚠ HEAD ${REV:0:7} is not on origin/${BRANCH}. Run 'git push' first —"
  echo "  ArgoCD syncs from git, not your laptop. Syncing anyway to whatever is on the remote."
fi

# Force ArgoCD to re-read git, then request a sync to the pinned revision (no prune).
kubectl -n argocd annotate application "${APP}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
kubectl -n argocd patch application "${APP}" --type merge \
  -p "{\"operation\":{\"sync\":{\"revision\":\"${REV}\",\"prune\":false}}}"

echo "Sync requested for ${APP} at ${REV:0:7}."
echo "Watch it land:  bin/fredlab-status.sh   (or the ArgoCD UI)"
