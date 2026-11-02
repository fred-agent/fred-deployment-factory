#!/usr/bin/env bash
# Removes the Keycloak account of a person; Fred's own records are left as they are.
# Usage: ./keycloak-delete-user.sh <username>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./keycloak-lib.sh

USERNAME="${1:?Usage: $0 <username>}"

kc_login
user_id=$(kc_user_id_by_username "$USERNAME")

if [ -z "$user_id" ]; then
  jq -n --arg username "$USERNAME" \
    '{action: "noop", username: $username, reason: "not found in Keycloak"}'
  exit 0
fi

kc delete "users/$user_id" -r "$KC_REALM"

jq -n \
  --arg username "$USERNAME" \
  --arg id "$user_id" \
  '{
    action: "deleted",
    username: $username,
    keycloak_id: $id
  }'
