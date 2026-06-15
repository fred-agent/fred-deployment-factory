#!/usr/bin/env bash
#
# kea-identity-dump.sh — capture the "identity" migration topic.
#
# Exports the Keycloak realm (users + groups) with their IDs preserved, so the
# `sub` (user UUID) and group IDs — which every OpenFGA tuple and team row points
# at — survive a wipe/restore. This is the LOCAL rehearsal of the production
# identity step (MIGR-04). Run it from the running factory, with your real
# users/teams present, BEFORE `make docker-wipe`.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DUMP_DIR="${DUMP_DIR:-${REPO_DIR}/dumps/identity}"
KC_CONTAINER="${KC_CONTAINER:-app-keycloak}"
REALM="${REALM:-app}"

if ! docker inspect "$KC_CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '${KC_CONTAINER}' not found. Start the stack first (make docker-up WITH_KEA=true)." >&2
    exit 1
fi

mkdir -p "$DUMP_DIR"

echo "=== Identity dump (realm '${REALM}', IDs preserved) ==="
echo "[1/2] Exporting from ${KC_CONTAINER} (users + groups)..."
docker exec "$KC_CONTAINER" rm -rf /tmp/kc-identity-dump >/dev/null 2>&1 || true
# kc.sh export runs a one-shot server bootstrap. On a LIVE container the export itself
# completes successfully, but the process then exits non-zero because it tries to bind the
# management port already held by the running server. We therefore tolerate the exit code
# and treat "the realm file was written" as the real success signal.
EXPORT_LOG="$(mktemp)"
docker exec "$KC_CONTAINER" /opt/keycloak/bin/kc.sh export \
    --dir /tmp/kc-identity-dump --realm "$REALM" --users realm_file >"$EXPORT_LOG" 2>&1 || true
if ! docker exec "$KC_CONTAINER" test -f "/tmp/kc-identity-dump/${REALM}-realm.json"; then
    echo "ERROR: realm export did not produce ${REALM}-realm.json. Export log follows:" >&2
    cat "$EXPORT_LOG" >&2
    rm -f "$EXPORT_LOG"
    exit 1
fi
rm -f "$EXPORT_LOG"

echo "[2/2] Copying export to ${DUMP_DIR} ..."
docker cp "${KC_CONTAINER}:/tmp/kc-identity-dump/${REALM}-realm.json" "${DUMP_DIR}/${REALM}-realm.json"
docker exec "$KC_CONTAINER" rm -rf /tmp/kc-identity-dump >/dev/null 2>&1 || true

users="?"; groups="?"
if command -v jq >/dev/null 2>&1; then
    users="$(jq '.users | length' "${DUMP_DIR}/${REALM}-realm.json" 2>/dev/null || echo '?')"
    groups="$(jq '.groups | length' "${DUMP_DIR}/${REALM}-realm.json" 2>/dev/null || echo '?')"
fi

echo ""
echo "✓ identity dump: ${users} users, ${groups} groups"
echo "  → ${DUMP_DIR}/${REALM}-realm.json"
echo "  (contains user data — treat as sensitive; dumps/ is gitignored)"
