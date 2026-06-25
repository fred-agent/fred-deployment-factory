#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-argocd-ui.sh — open the ArgoCD UI privately, for admin only.
#
# Safe: this does NOT expose ArgoCD publicly. It prints the admin password and starts a
# local `kubectl port-forward`. Only your authenticated Cloud Shell session can reach it
# (via "Web Preview"). No Ingress, no public IP, no certificate. Ctrl-C stops it.

NAMESPACE="${NAMESPACE:-argocd}"
RELEASE="${RELEASE:-argocd}"
PORT="${PORT:-8080}"

command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

echo "ArgoCD login:"
echo "  user:     admin"
echo -n "  password: "
kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo

echo "Starting port-forward on localhost:${PORT}  (Ctrl-C to stop)"
echo "In Cloud Shell: click 'Web Preview' -> 'Preview on port ${PORT}', then log in."
echo
exec kubectl -n "${NAMESPACE}" port-forward "svc/${RELEASE}-server" "${PORT}:80"
