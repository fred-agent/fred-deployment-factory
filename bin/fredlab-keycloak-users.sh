#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only: list realm `app` users with their email and group memberships.

NAMESPACE="${NAMESPACE:-default}"
KEYCLOAK_DEPLOY="${KEYCLOAK_DEPLOY:-keycloak}"
SECRET="${SECRET:-fredlab-infra-secrets}"
REALM="${REALM:-app}"

command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl"; exit 1; }

au="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d)"
ap="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"
kc() { kubectl -n "$NAMESPACE" exec -i "deploy/$KEYCLOAK_DEPLOY" -- /opt/keycloak/bin/kcadm.sh "$@"; }

kc config credentials --server http://localhost:8080 --realm master --user "$au" --password "$ap" >/dev/null

printf '%-28s %-34s %s\n' "USERNAME" "EMAIL" "GROUPS"
kc get users -r "$REALM" --fields id,username,email --format csv --noquotes 2>/dev/null | tr -d '\r' \
| while IFS=, read -r id username email; do
    [[ -z "$id" ]] && continue
    groups="$(kc get "users/$id/groups" -r "$REALM" --fields name --format csv --noquotes 2>/dev/null | tr -d '\r' | paste -sd, -)"
    printf '%-28s %-34s %s\n' "$username" "$email" "$groups"
  done
