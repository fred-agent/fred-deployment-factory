#!/usr/bin/env bash
# Prints known Keycloak users (realm "app") and their OpenFGA rights as JSON.
# Requires the local dev stack to be up:
#   app-keycloak (docker-compose-keycloak.yml), openfga (docker-compose-openfga.yml)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./keycloak-lib.sh

kc_login
kc_users=$(kc get users -r "$KC_REALM" --fields id,username,email,enabled,emailVerified)

store_id=$(fga_store_id)
if [ -z "$store_id" ]; then
  echo "OpenFGA store '$OPENFGA_STORE_NAME' not found" >&2
  exit 1
fi

all_tuples=$(fga_read_all_tuples "$store_id")

# --- Combine into a readable rights summary ---
# Tag/document "parent" tuples are catalog hierarchy, not access grants — kept only
# in the raw dump, excluded (and counted) in the readable sections below.
jq -n \
  --argjson keycloak_users "$kc_users" \
  --argjson tuples "$all_tuples" \
  --arg store "$OPENFGA_STORE_NAME" \
  '
  ($keycloak_users | map({(.id): .username}) | add // {}) as $id_to_username
  | ($tuples | map(select(.user | startswith("tag:") | not))) as $access_tuples
  | {
      keycloak_users: $keycloak_users,
      openfga_store: $store,

      # capabilities every member of the org gets by default (no per-user tuple needed)
      organization_default_capabilities:
        [$access_tuples[] | select(.relation == "default_on") | .object] | sort,

      # explicit per-user grants (platform_admin, team roles, ...), username-resolved
      explicit_user_grants:
        ($access_tuples
          | map(select(.user | startswith("user:")))
          | map(. + {resolved_user: ($id_to_username[(.user | ltrimstr("user:"))] // .user)})
          | group_by(.resolved_user)
          | map({(.[0].resolved_user): map({relation, object})})
          | add // {}),

      teams: [$access_tuples[] | .object | select(startswith("team:"))] | unique,

      tag_document_relations_excluded_count:
        ($tuples | map(select(.user | startswith("tag:"))) | length),

      openfga_tuples_raw: $tuples
    }
  '
