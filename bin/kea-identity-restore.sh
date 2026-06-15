#!/usr/bin/env bash
#
# kea-identity-restore.sh — restore the "identity" topic (migration step 1).
#
# Imports the dumped realm users + groups into the running Keycloak via the
# admin partialImport endpoint, PRESERVING IDs. Run it after `make docker-up`,
# before the metadata import. Demo users created by initial provisioning are left
# in place (inert — the import keys on the real UUIDs restored here).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DUMP_DIR="${DUMP_DIR:-${REPO_DIR}/dumps/identity}"
REALM="${REALM:-app}"
KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_PW="${KC_PW:-Azerty123_}"
EXPORT_FILE="${DUMP_DIR}/${REALM}-realm.json"

command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
if [ ! -f "$EXPORT_FILE" ]; then
    echo "ERROR: no identity dump at ${EXPORT_FILE}. Run 'make kea-identity-dump' first." >&2
    exit 1
fi

echo "=== Identity restore (realm '${REALM}', IDs preserved) ==="

echo "[1/3] Authenticating to Keycloak at ${KC_URL} ..."
TOKEN=""
for attempt in $(seq 1 30); do
    TOKEN="$(curl -fsS -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=admin-cli \
        -d username="${KC_ADMIN}" -d password="${KC_PW}" 2>/dev/null | jq -r '.access_token // empty' || true)"
    [ -n "$TOKEN" ] && break
    sleep 2
done
[ -n "$TOKEN" ] || { echo "ERROR: could not authenticate to Keycloak at ${KC_URL} (is the stack up?)." >&2; exit 1; }

echo "[2/3] Building partialImport payload (users + groups, OVERWRITE on conflict)..."
PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq '{ifResourceExists:"OVERWRITE", users:(.users // []), groups:(.groups // [])}' "$EXPORT_FILE" > "$PAYLOAD"

echo "[3/3] Importing into realm '${REALM}' ..."
RESP="$(curl -fsS -X POST "${KC_URL}/admin/realms/${REALM}/partialImport" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data @"${PAYLOAD}")"

echo ""
if echo "$RESP" | jq -e . >/dev/null 2>&1; then
    echo "$RESP" | jq -r '"✓ identity restored: added=\(.added // 0) overwritten=\(.overwritten // 0) skipped=\(.skipped // 0)"'
else
    echo "✓ identity restore call returned:"; echo "$RESP"
fi
echo "  realm '${REALM}' now holds the dumped users/groups with their original IDs."
