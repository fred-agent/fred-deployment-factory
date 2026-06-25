#!/usr/bin/env bash
set -Eeuo pipefail
# Ensure a confidential Keycloak `argocd` client in realm `app` (for ArgoCD OIDC login).
# Idempotent; additive — does not touch existing clients or the provision job.

NAMESPACE="${NAMESPACE:-default}"
KEYCLOAK_DEPLOY="${KEYCLOAK_DEPLOY:-keycloak}"
SECRET="${SECRET:-fredlab-infra-secrets}"
REALM="${REALM:-app}"
CLIENT_ID="${CLIENT_ID:-argocd}"
BASE_URL="${BASE_URL:-https://argocd.playground.fredlab.dev}"

command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

ADMIN_USER="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d)"
ADMIN_PASS="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"

kc() { kubectl -n "$NAMESPACE" exec -i "deploy/$KEYCLOAK_DEPLOY" -- /opt/keycloak/bin/kcadm.sh "$@"; }

kc config credentials --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null

redirect_uris="[\"${BASE_URL}/auth/callback\",\"http://localhost:8085/auth/callback\"]"
web_origins="[\"${BASE_URL}\"]"

uuid="$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' || true)"

if [[ -z "$uuid" ]]; then
  kc create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s rootUrl="$BASE_URL" \
    -s "redirectUris=${redirect_uris}" \
    -s "webOrigins=${web_origins}" >/dev/null
  uuid="$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')"
else
  kc update "clients/$uuid" -r "$REALM" \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s rootUrl="$BASE_URL" \
    -s "redirectUris=${redirect_uris}" \
    -s "webOrigins=${web_origins}" >/dev/null
fi

have_mapper="$(kc get "clients/$uuid/protocol-mappers/models" -r "$REALM" --fields name --format csv --noquotes 2>/dev/null | tr -d '\r' | grep -Fx groups || true)"
if [[ -z "$have_mapper" ]]; then
  kc create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
fi

echo "client '${CLIENT_ID}' ready (confidential, realm ${REALM})"
