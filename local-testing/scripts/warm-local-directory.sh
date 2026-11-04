#!/usr/bin/env bash
# Populate the local directory from the demo identities by authenticating each person.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/keycloak-lib.sh"
SWIFT_SRC="${SWIFT_SRC:-${SCRIPT_DIR}/../../../fred}"
USERS_JSON_REL="apps/control-plane-backend/tests/fixtures/import_export/demo_provisioning/users.json"
require_swift_path "$SWIFT_SRC" "$USERS_JSON_REL" "$0"
USERS_JSON="$SWIFT_SRC/$USERS_JSON_REL"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
CONTROL_PLANE_URL="${CONTROL_PLANE_URL:-http://localhost:8222}"
failed=0
succeeded=0

while IFS= read -r entry; do
  username="$(jq -r '.username' <<<"$entry")"
  password="$(jq -r '.password // empty' <<<"$entry")"
  if [[ -z "$username" || -z "$password" ]]; then
    printf 'FAIL %s: missing username or password in fixture\n' "${username:-<empty>}" >&2
    failed=$((failed + 1))
    continue
  fi

  token_response="$(curl --silent --show-error --fail-with-body \
    --request POST "${KEYCLOAK_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
    --data-urlencode 'grant_type=password' --data-urlencode 'client_id=app' \
    --data-urlencode "username=${username}" --data-urlencode "password=${password}" 2>/dev/null)" || token_response=''
  token="$(jq -r '.access_token // empty' <<<"${token_response:-{}}" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    printf 'FAIL %s: token request failed\n' "$username" >&2
    failed=$((failed + 1))
    continue
  fi

  # Authentication runs before the route's permission check, so a pre-import
  # 403 still writes the identity snapshot. A 401 means authentication failed.
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Authorization: Bearer ${token}" \
    "${CONTROL_PLANE_URL}/control-plane/v1/user" 2>/dev/null)" || status=000
  if [[ "$status" == 200 || "$status" == 403 ]]; then
    printf 'OK   %s (HTTP %s)\n' "$username" "$status"
    succeeded=$((succeeded + 1))
  else
    printf 'FAIL %s: control-plane HTTP %s\n' "$username" "$status" >&2
    failed=$((failed + 1))
  fi
done < <(jq -c '.[]' "$USERS_JSON")

printf 'Local directory warm-up: %s OK, %s FAIL\n' "$succeeded" "$failed"
(( failed == 0 ))
