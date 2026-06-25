#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-argocd-render.sh — READ-ONLY. Render the fred-apps chart locally so you can
# eyeball exactly what ArgoCD would create, BEFORE anything touches the cluster.
#
# Safe to run anytime: it only runs `helm template`. It does NOT contact GCP, does NOT
# talk to the cluster, and changes nothing. Output is plain YAML on stdout.
#
# Usage:
#   bin/fredlab-argocd-render.sh            # render to stdout
#   bin/fredlab-argocd-render.sh | less     # page through it

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/argocd/fred-apps"

command -v helm >/dev/null 2>&1 || { echo "Missing required tool: helm"; exit 1; }

helm template fred-apps "${CHART_DIR}" \
  -f "${CHART_DIR}/values.yaml" \
  -f "${CHART_DIR}/values-fredlab.yaml"
