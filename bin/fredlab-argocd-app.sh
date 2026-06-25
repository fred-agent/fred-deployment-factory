#!/usr/bin/env bash
set -Eeuo pipefail
# Register the fred-apps ArgoCD Application (manual sync). Idempotent.
# Registering only compares git vs cluster; it changes nothing until you Sync in the UI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

kubectl apply -f "${REPO_ROOT}/argocd/applications/fred-apps.yaml"
