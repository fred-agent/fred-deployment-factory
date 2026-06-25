#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-argocd-install.sh — install/upgrade ArgoCD in the `argocd` namespace.
# Idempotent single setup point: config from argocd/argocd-values.yaml; the Keycloak OIDC
# client secret is fetched at runtime (never in git). If the `argocd` Keycloak client does
# not exist yet, OIDC is skipped and the rest installs — run fredlab-argocd-keycloak-client.sh
# then re-run this to enable login.

usage() {
  cat <<'EOF'
Usage:
  bin/fredlab-argocd-install.sh

Environment overrides:
  NAMESPACE, RELEASE, ARGOCD_CHART_VERSION (default pinned), WAIT_TIMEOUT,
  KC_NAMESPACE, KEYCLOAK_DEPLOY, INFRA_SECRET, REALM
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unexpected argument: $1"; usage; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/argocd/argocd-values.yaml"

NAMESPACE="${NAMESPACE:-argocd}"
RELEASE="${RELEASE:-argocd}"
# Pinned to the version first installed on fredlab (2026-06-25). Bump deliberately.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION-9.7.0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
REPO_URL="https://argoproj.github.io/argo-helm"

KC_NAMESPACE="${KC_NAMESPACE:-default}"
KEYCLOAK_DEPLOY="${KEYCLOAK_DEPLOY:-keycloak}"
INFRA_SECRET="${INFRA_SECRET:-fredlab-infra-secrets}"
REALM="${REALM:-app}"

for bin in helm kubectl; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "Missing required tool: ${bin}"; exit 1; }
done

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ "${CTX}" == *fredlab* ]] || echo "⚠ context '${CTX:-<none>}' is not a fredlab cluster — Ctrl-C if wrong."

helm repo add argo "${REPO_URL}" >/dev/null 2>&1 || true
helm repo update argo >/dev/null

version_args=()
[[ -n "${ARGOCD_CHART_VERSION}" ]] && version_args+=(--version "${ARGOCD_CHART_VERSION}")

# Fetch the argocd OIDC client secret from Keycloak (runtime only, never git).
oidc_set=()
client_secret="$(
  au="$(kubectl -n "$KC_NAMESPACE" get secret "$INFRA_SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' 2>/dev/null | base64 -d || true)"
  ap="$(kubectl -n "$KC_NAMESPACE" get secret "$INFRA_SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || true)"
  kc() { kubectl -n "$KC_NAMESPACE" exec -i "deploy/$KEYCLOAK_DEPLOY" -- /opt/keycloak/bin/kcadm.sh "$@"; }
  if [[ -n "$ap" ]] && kc config credentials --server http://localhost:8080 --realm master --user "$au" --password "$ap" >/dev/null 2>&1; then
    uuid="$(kc get clients -r "$REALM" -q clientId=argocd --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$uuid" ]] && kc get "clients/$uuid/client-secret" -r "$REALM" --fields value --format csv --noquotes 2>/dev/null | tr -d '\r'
  fi
)"
if [[ -n "${client_secret}" ]]; then
  oidc_set+=(--set "configs.secret.extra.oidc\.keycloak\.clientSecret=${client_secret}")
  echo "Keycloak 'argocd' client found — enabling OIDC login."
else
  echo "Keycloak 'argocd' client not found — installing without OIDC (run fredlab-argocd-keycloak-client.sh, then re-run)."
fi

helm upgrade --install "${RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  "${oidc_set[@]}" \
  "${version_args[@]}"

kubectl -n "${NAMESPACE}" rollout status deploy/"${RELEASE}"-server --timeout="${WAIT_TIMEOUT}" || true
helm -n "${NAMESPACE}" list --filter "^${RELEASE}$" -o json 2>/dev/null \
  | sed -n 's/.*"chart":"\(argo-cd-[^"]*\)".*/chart: \1/p' || true
