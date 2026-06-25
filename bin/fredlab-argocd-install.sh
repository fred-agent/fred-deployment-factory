#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-argocd-install.sh — stand up ArgoCD in its own `argocd` namespace.
#
# Pragmatic, idempotent bootstrap: re-running it upgrades in place, never recreates.
# ArgoCD lives in `argocd` (its own RBAC boundary, cluster-wide power, clean teardown);
# it will manage the four fred apps IN-PLACE in `default` later — apps stay co-located
# with the infra-owned `fredlab-infra-secrets` Secret and the GCE Ingress, which a GCE
# Ingress and namespaced Secrets both require. Infra is untouched.
#
# GKE Autopilot: no custom values needed — Autopilot injects default resource requests
# for any container that omits them, so the stock chart schedules as-is. Pin resources
# later if you want tighter sizing.
#
# Run from Cloud Shell with the cluster context active:
#   kubectl config current-context   # -> fredlab-playground-gke

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-argocd-install.sh

Environment overrides:
  NAMESPACE              (default: argocd)
  RELEASE               (default: argocd)
  ARGOCD_CHART_VERSION  pin the argo/argo-cd chart version (recommended after first run
                        for reproducibility; empty = install latest)
  WAIT_TIMEOUT          (default: 300s) rollout wait; non-fatal if Autopilot is still
                        provisioning nodes
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unexpected argument: $1"; usage; exit 1 ;;
esac

NAMESPACE="${NAMESPACE:-argocd}"
RELEASE="${RELEASE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
REPO_URL="https://argoproj.github.io/argo-helm"

for bin in helm kubectl; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "Missing required tool: ${bin}"; exit 1; }
done

CTX="$(kubectl config current-context 2>/dev/null || true)"
echo "kube context: ${CTX:-<none>}"
if [[ "${CTX}" != *fredlab* ]]; then
  echo "⚠ current context is not a fredlab cluster — Ctrl-C now if that is wrong."
fi

echo "== Helm repo =="
helm repo add argo "${REPO_URL}" >/dev/null 2>&1 || true
helm repo update argo >/dev/null

echo "== Install / upgrade ArgoCD (release '${RELEASE}', namespace '${NAMESPACE}') =="
version_args=()
if [[ -n "${ARGOCD_CHART_VERSION}" ]]; then
  version_args+=(--version "${ARGOCD_CHART_VERSION}")
  echo "pinned chart version: ${ARGOCD_CHART_VERSION}"
else
  echo "no ARGOCD_CHART_VERSION pin — installing latest (pin it after this run for reproducibility)"
fi

helm upgrade --install "${RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  "${version_args[@]}"

echo "== Resolved version (pin this for next time) =="
helm -n "${NAMESPACE}" list --filter "^${RELEASE}$" \
  -o json 2>/dev/null | sed -n 's/.*"chart":"\(argo-cd-[^"]*\)".*/  chart: \1/p' || true
echo "  -> export ARGOCD_CHART_VERSION=<the X.Y.Z after 'argo-cd-'> for reproducible re-runs"

echo "== Wait for argocd-server (non-fatal) =="
kubectl -n "${NAMESPACE}" rollout status deploy/"${RELEASE}"-server --timeout="${WAIT_TIMEOUT}" || \
  echo "argocd-server not Ready yet — on Autopilot this can mean a node is still provisioning; re-check with: kubectl -n ${NAMESPACE} get pods"

cat <<EOF

== ArgoCD is installed. Access it (private, no Ingress) ==

  # initial admin password (username: admin)
  kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d; echo

  # open the UI / API locally
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-server 8080:443
  # then browse https://localhost:8080 (accept the self-signed cert)

Next step (separate, not done here): register the GitOps repo and create the first
Application that deploys the four fred apps into the 'default' namespace.
EOF
