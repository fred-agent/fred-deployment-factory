#!/usr/bin/env bash
# Shared config + helpers for the keycloak-*.sh local dev-stack scripts.
# Source this, don't execute it directly.

KC_CONTAINER="app-keycloak"
KC_REALM="app"
KC_ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-Azerty123_}"

OPENFGA_URL="${OPENFGA_URL:-http://localhost:9080}"
OPENFGA_API_TOKEN="${OPENFGA_API_TOKEN:-Azerty123_}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-fred}"

kc() {
  # -i so callers can pipe a request body in via `-f -` (e.g. partialImport).
  docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
}

kc_login() {
  kc config credentials --server http://localhost:8080 --realm master \
    --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null 2>&1
}

kc_user_id_by_username() {
  local username="$1"
  kc get users -r "$KC_REALM" -q "username=$username" --fields id,username \
    | jq -r --arg u "$username" '.[] | select(.username == $u) | .id' | head -n1
}

# Verify SWIFT_SRC points at a real `fred` checkout containing a given
# relative path, mirroring the Makefile's own `require_swift_lib` macro
# (`Makefile:529`) — same env var name, same message shape — for scripts here
# that read a file out of a sibling `fred` checkout instead of checking
# fred-core is a valid Python project. Assumes the `fred` and
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

fga_curl() {
  curl -s -H "Authorization: Bearer $OPENFGA_API_TOKEN" -H "Content-Type: application/json" "$@"
}

fga_store_id() {
  fga_curl "$OPENFGA_URL/stores" \
    | jq -r --arg name "$OPENFGA_STORE_NAME" '.stores[] | select(.name == $name) | .id' | head -n1
}

# Reads every tuple in a store (paginated). Prints a JSON array of tuple keys.
fga_read_all_tuples() {
  local store_id="$1"
  local all_tuples="[]"
  local continuation_token=""
  while true; do
    local body
    body=$(jq -n --arg pt "$continuation_token" \
      '{page_size: 100} + (if $pt != "" then {continuation_token: $pt} else {} end)')
    local resp
    resp=$(fga_curl -X POST "$OPENFGA_URL/stores/$store_id/read" -d "$body")
    local page
    page=$(echo "$resp" | jq '[.tuples[].key]')
    all_tuples=$(jq -c -n --argjson a "$all_tuples" --argjson b "$page" '$a + $b')
    continuation_token=$(echo "$resp" | jq -r '.continuation_token')
    [ -z "$continuation_token" ] && break
  done
  echo "$all_tuples"
}
