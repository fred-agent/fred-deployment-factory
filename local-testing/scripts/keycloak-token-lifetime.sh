#!/usr/bin/env bash
# Local Docker only: shorten browser and agentic workload tokens without changing refresh/session lifetimes.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/keycloak-lib.sh"
mode="${1:-status}"
case "$mode" in
  status|short|normal) ;;
  *) echo 'Usage: keycloak-token-lifetime.sh [status|short|normal]' >&2; exit 2 ;;
esac
# Use the credentials of the actual local container; never print them.
KC_ADMIN_USER="$(docker exec "$KC_CONTAINER" printenv KC_BOOTSTRAP_ADMIN_USERNAME)"
KC_ADMIN_PASSWORD="$(docker exec "$KC_CONTAINER" printenv KC_BOOTSTRAP_ADMIN_PASSWORD)"
kc_login
for client_id in app agentic; do
  client="$(kc get clients -r "$KC_REALM" -q "clientId=$client_id" --fields id,clientId | jq -er --arg id "$client_id" '.[] | select(.clientId == $id) | .id')"
  if [[ "$mode" != status ]]; then
    seconds=60
    [[ "$client_id" != agentic ]] || seconds=120
    [[ "$mode" != normal ]] || seconds=300
    kc get "clients/$client" -r "$KC_REALM" \
      | jq --arg seconds "$seconds" '{attributes: ((.attributes // {}) + {"access.token.lifespan": $seconds})}' \
      | kc update "clients/$client" -r "$KC_REALM" -f -
  fi
  kc get "clients/$client" -r "$KC_REALM" \
    | jq '{client: .clientId, access_token_seconds: (.attributes["access.token.lifespan"] // "realm default")}'
done
echo 'Only new app and agentic access tokens are affected. Sign out/in for app; restart Fred Agents or wait for its cached token to expire. Other clients and session/refresh lifetimes are unchanged.'
