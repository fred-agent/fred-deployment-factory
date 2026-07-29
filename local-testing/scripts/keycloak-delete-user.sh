#!/usr/bin/env bash
# Simulates a user swift has never known: removes the Keycloak account and every
# OpenFGA tuple that references them (as subject, or via their personal team object).
# Usage: ./keycloak-delete-user.sh <username>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./keycloak-lib.sh

USERNAME="${1:?Usage: $0 <username>}"

kc_login
user_id=$(kc_user_id_by_username "$USERNAME")

if [ -z "$user_id" ]; then
  jq -n --arg username "$USERNAME" \
    '{action: "noop", username: $username, reason: "not found in Keycloak", openfga_tuples_deleted: []}'
  exit 0
fi

store_id=$(fga_store_id)
if [ -z "$store_id" ]; then
  echo "OpenFGA store '$OPENFGA_STORE_NAME' not found" >&2
  exit 1
fi

all_tuples=$(fga_read_all_tuples "$store_id")
deleted_tuples=$(jq -c --arg uid "$user_id" \
  '[.[] | select(.user == "user:" + $uid or .object == "team:personal-" + $uid)]' \
  <<<"$all_tuples")

deleted_count=$(jq 'length' <<<"$deleted_tuples")
if [ "$deleted_count" -gt 0 ]; then
  write_body=$(jq -n --argjson tuples "$deleted_tuples" \
    '{deletes: {tuple_keys: [$tuples[] | {user, relation, object}]}}')
  fga_curl -X POST "$OPENFGA_URL/stores/$store_id/write" -d "$write_body" >/dev/null
fi

kc delete "users/$user_id" -r "$KC_REALM"

jq -n \
  --arg username "$USERNAME" \
  --arg id "$user_id" \
  --argjson tuples "$deleted_tuples" \
  '{
    action: "deleted",
    username: $username,
    keycloak_id: $id,
    openfga_tuples_deleted: $tuples
  }'
