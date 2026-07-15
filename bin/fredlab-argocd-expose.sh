#!/usr/bin/env bash
set -Eeuo pipefail
# Create ArgoCD's Ingress + ManagedCertificate in the argocd namespace. Idempotent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

kubectl apply -f "${REPO_ROOT}/gcp-c1/argocd/expose/"
