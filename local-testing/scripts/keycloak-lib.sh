#!/usr/bin/env bash
# Shared config + helpers for the keycloak-*.sh local dev-stack scripts.
# Source this, don't execute it directly.

KC_CONTAINER="${KEYCLOAK_CONTAINER:-app-keycloak}"
KC_REALM="app"
KC_ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-Azerty123_}"

kc() {
  # -i so callers can pipe a request body in via `-f -` (e.g. partialImport).
  docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
}

kc_login() {
  kc config credentials --server "${KEYCLOAK_SERVER_URL:-http://localhost:8080}" --realm master \
    --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null 2>&1
}

kc_user_id_by_username() {
  local username="$1"
  kc get users -r "$KC_REALM" -q "username=$username" --fields id,username \
    | jq -r --arg u "$username" '.[] | select(.username == $u) | .id' | head -n1
}

# Verify SWIFT_SRC points at a real `fred` checkout containing a given
# relative path, for scripts here that read a file out of a sibling `fred`
# checkout. Assumes the `fred` and
# `fred-deployment-factory` checkouts are siblings under the same parent
# directory by default (override with SWIFT_SRC=/path/to/fred).
# Usage: require_swift_path "$SWIFT_SRC" "apps/.../users.json" "$0"
require_swift_path() {
  local swift_src="$1" rel_path="$2" script_name="$3"
  if [ ! -f "$swift_src/$rel_path" ]; then
    echo "✗ Not found in the fred checkout: $swift_src/$rel_path" >&2
    echo "  SWIFT_SRC is currently: $swift_src" >&2
    echo "  Fix: pass the path to your 'fred' checkout, e.g.:" >&2
    echo "    SWIFT_SRC=/path/to/fred $script_name" >&2
    exit 1
  fi
}
