#!/usr/bin/env bash
# Simulates a brand-new SSO login: creates a user in Keycloak only (fresh id),
# with no OpenFGA tuples — i.e. known to Keycloak, not yet known to Fred.
#
# Usage:
#   ./keycloak-add-user.sh <username>                 single user (original behaviour)
#   ./keycloak-add-user.sh --count N [--prefix P]      bulk-create N synthetic users
#
# Bulk mode goes through Keycloak's partialImport endpoint in chunks instead of
# one kcadm call per user: kcadm's per-invocation JVM startup makes the
# single-user path (create + set-password, ~1 docker exec each) take ~35-40min
# for 3000 users; partialImport batches hundreds of users into one Admin REST
# call (~500 users / ~17s measured locally), cutting that to ~2min.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./keycloak-lib.sh

usage() {
  cat <<EOF
Usage:
  $0 <username>                          Create a single user
  $0 --count N [--prefix PREFIX] [--chunk-size K]
                                          Bulk-create N synthetic users (default
                                          prefix: user -> user0001, user0002, ...)
                                          via Keycloak's partialImport endpoint.
                                          Idempotent: existing usernames are skipped.
                                          Chunk size defaults to 500 users/request.
EOF
}

if [ "${1:-}" = "--count" ]; then
  COUNT="${2:?Usage: $0 --count N [--prefix PREFIX] [--chunk-size K]}"
  PREFIX="user"
  CHUNK_SIZE=500
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix)
        PREFIX="${2:?--prefix requires a value}"
        shift 2
        ;;
      --chunk-size)
        CHUNK_SIZE="${2:?--chunk-size requires a value}"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
  [[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || { echo "--count must be a positive integer" >&2; exit 1; }
  [[ "$CHUNK_SIZE" =~ ^[0-9]+$ && "$CHUNK_SIZE" -gt 0 ]] || { echo "--chunk-size must be a positive integer" >&2; exit 1; }

  kc_login

  width=${#COUNT}
  total_added=0
  total_skipped=0
  total_overwritten=0

  chunk_start=1
  while [ "$chunk_start" -le "$COUNT" ]; do
    chunk_end=$((chunk_start + CHUNK_SIZE - 1))
    [ "$chunk_end" -gt "$COUNT" ] && chunk_end=$COUNT

    # Piped through stdin (jq -s), never passed as a single --argjson argument —
    # a 500-user chunk is well past ARG_MAX in some shells and execve fails with
    # "argument list too long".
    resp=$(
      {
        for ((i = chunk_start; i <= chunk_end; i++)); do
          username="$(printf "%s%0${width}d" "$PREFIX" "$i")"
          jq -cn --arg u "$username" --arg pass "$KC_ADMIN_PASSWORD" '
            {
              username: $u,
              email: ($u + "@app.com"),
              firstName: (($u[0:1] | ascii_upcase) + $u[1:]),
              lastName: "Swify",
              enabled: true,
              emailVerified: true,
              credentials: [{type: "password", value: $pass, temporary: false}]
            }'
        done
      } | jq -cs '{ifResourceExists: "SKIP", users: .}' | kc create "realms/$KC_REALM/partialImport" -f - -o 2>&1
    )

    added=$(jq -r '.added // 0' <<<"$resp" 2>/dev/null || echo 0)
    skipped=$(jq -r '.skipped // 0' <<<"$resp" 2>/dev/null || echo 0)
    overwritten=$(jq -r '.overwritten // 0' <<<"$resp" 2>/dev/null || echo 0)
    if ! [[ "$added" =~ ^[0-9]+$ ]]; then
      echo "  chunk [$chunk_start-$chunk_end]: unexpected response: $resp" >&2
      exit 1
    fi
    total_added=$((total_added + added))
    total_skipped=$((total_skipped + skipped))
    total_overwritten=$((total_overwritten + overwritten))

    echo "  chunk [$chunk_start-$chunk_end]: added=$added skipped=$skipped overwritten=$overwritten" >&2

    chunk_start=$((chunk_end + 1))
  done

  jq -n \
    --arg prefix "$PREFIX" \
    --argjson requested "$COUNT" \
    --argjson created "$total_added" \
    --argjson skipped_existing "$total_skipped" \
    --argjson overwritten "$total_overwritten" \
    '{
      action: "bulk_created",
      prefix: $prefix,
      requested: $requested,
      created: $created,
      skipped_existing: $skipped_existing,
      overwritten: $overwritten,
      known_to_openfga: false
    }'
  exit 0
fi

USERNAME="${1:?Usage: $0 <username>}"
EMAIL="${USERNAME}@app.com"
# firstName/lastName are required for the UI to render initials/avatars
# instead of "UU" (undefined/undefined) — "Swify" marks the account as
# synthetic, created by this tooling rather than a real seed user.
FIRST_NAME="$(tr '[:lower:]' '[:upper:]' <<<"${USERNAME:0:1}")${USERNAME:1}"
LAST_NAME="Swify"

kc_login

existing_id=$(kc_user_id_by_username "$USERNAME")
if [ -n "$existing_id" ]; then
  echo "User '$USERNAME' already exists in Keycloak (id=$existing_id) — nothing to do." >&2
  exit 1
fi

kc create users -r "$KC_REALM" \
  -s username="$USERNAME" \
  -s email="$EMAIL" \
  -s firstName="$FIRST_NAME" \
  -s lastName="$LAST_NAME" \
  -s enabled=true \
  -s emailVerified=true >/dev/null 2>&1

new_id=$(kc_user_id_by_username "$USERNAME")
kc set-password -r "$KC_REALM" --userid "$new_id" --new-password "$KC_ADMIN_PASSWORD" --temporary=false >/dev/null 2>&1

jq -n \
  --arg username "$USERNAME" \
  --arg id "$new_id" \
  --arg email "$EMAIL" \
  --arg first_name "$FIRST_NAME" \
  --arg last_name "$LAST_NAME" \
  '{
    action: "created",
    username: $username,
    keycloak_id: $id,
    email: $email,
    first_name: $first_name,
    last_name: $last_name,
    known_to_keycloak: true,
    known_to_openfga: false
  }'
