#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${1:-config/fredlab-keycloak-identity.json}"
NAMESPACE="${NAMESPACE:-default}"
KEYCLOAK_DEPLOYMENT="${KEYCLOAK_DEPLOYMENT:-deploy/keycloak}"
DEFAULT_REALM="${REALM:-app}"
DEFAULT_CLIENT_ID="${CLIENT_ID:-app}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Identity config file not found: ${CONFIG_FILE}" >&2
  echo "Create it from config/fredlab-keycloak-identity.example.json." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

REALM="$(jq -r --arg fallback "$DEFAULT_REALM" '.realm // $fallback' "$CONFIG_FILE")"
CLIENT_ID="$(jq -r --arg fallback "$DEFAULT_CLIENT_ID" '.clientId // $fallback' "$CONFIG_FILE")"

KCADM="/opt/keycloak/bin/kcadm.sh"

kc() {
  kubectl exec -n "$NAMESPACE" "$KEYCLOAK_DEPLOYMENT" -- "$KCADM" "$@"
}

csv_value() {
  awk 'NR == 2 { print; exit }'
}

client_uuid() {
  kc get clients -r "$REALM" -q "clientId=$1" --fields id --format csv --noquotes 2>/dev/null \
    | csv_value
}

user_uuid() {
  kc get users -r "$REALM" -q "username=$1" -q exact=true --fields id --format csv --noquotes 2>/dev/null \
    | csv_value
}

group_path() {
  local name="$1"
  jq -rn --arg value "/${name}" '$value | @uri'
}

group_uuid() {
  local name="$1"
  local encoded_path
  encoded_path="$(group_path "$name")"
  kc get "group-by-path/${encoded_path}" -r "$REALM" --fields id --format csv --noquotes 2>/dev/null \
    | csv_value
}

client_scope_uuid() {
  local name="$1"
  kc get client-scopes -r "$REALM" --fields id,name --format csv --noquotes 2>/dev/null \
    | awk -F, -v wanted="$name" 'NR > 1 && $2 == wanted { print $1; exit }'
}

ensure_login() {
  local admin_user admin_password
  admin_user="$(kubectl get secret fredlab-infra-secrets -n "$NAMESPACE" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d)"
  admin_password="$(kubectl get secret fredlab-infra-secrets -n "$NAMESPACE" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"

  kubectl exec -n "$NAMESPACE" "$KEYCLOAK_DEPLOYMENT" -- \
    env KC_ADMIN_PASSWORD="$admin_password" /bin/sh -c \
      "${KCADM} config credentials --server http://localhost:8080 --realm master --user '$admin_user' --password \"\$KC_ADMIN_PASSWORD\"" >/dev/null
}

ensure_app_role() {
  local client_id="$1"
  local role="$2"
  local uuid
  uuid="$(client_uuid "$client_id")"

  if [[ -z "$uuid" ]]; then
    echo "Client '${client_id}' not found in realm '${REALM}'." >&2
    exit 1
  fi

  if kc get "clients/${uuid}/roles/${role}" -r "$REALM" >/dev/null 2>&1; then
    echo "Role '${client_id}/${role}' already exists."
  else
    echo "Creating role '${client_id}/${role}'."
    kc create "clients/${uuid}/roles" -r "$REALM" \
      -s "name=${role}" \
      -s "description=Fred application role ${role}" >/dev/null
  fi
}

ensure_groups_scope() {
  local client_id="$1"
  local app_uuid scope_uuid mapper_exists attached

  app_uuid="$(client_uuid "$client_id")"
  if [[ -z "$app_uuid" ]]; then
    echo "Client '${client_id}' not found in realm '${REALM}'." >&2
    exit 1
  fi

  scope_uuid="$(client_scope_uuid "groups-scope")"
  if [[ -z "$scope_uuid" ]]; then
    echo "Creating client scope 'groups-scope'."
    kc create client-scopes -r "$REALM" \
      -s name=groups-scope \
      -s protocol=openid-connect >/dev/null
    scope_uuid="$(client_scope_uuid "groups-scope")"
  else
    echo "Client scope 'groups-scope' already exists."
  fi

  mapper_exists="$(
    kc get "client-scopes/${scope_uuid}/protocol-mappers/models" -r "$REALM" --fields name --format csv --noquotes 2>/dev/null \
      | awk 'NR > 1 && $1 == "groups" { print "yes"; exit }'
  )"
  if [[ "$mapper_exists" != "yes" ]]; then
    echo "Creating groups mapper."
    kc create "client-scopes/${scope_uuid}/protocol-mappers/models" -r "$REALM" \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."claim.name"=groups' \
      -s 'config."full.path"=true' \
      -s 'config."access.token.claim"=true' \
      -s 'config."id.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' \
      -s 'config."multivalued"=true' >/dev/null
  else
    echo "Groups mapper already exists."
  fi

  attached="$(
    kc get "clients/${app_uuid}/default-client-scopes" -r "$REALM" --fields name --format csv --noquotes 2>/dev/null \
      | awk 'NR > 1 && $1 == "groups-scope" { print "yes"; exit }'
  )"
  if [[ "$attached" != "yes" ]]; then
    echo "Attaching 'groups-scope' to client '${client_id}'."
    kc update "clients/${app_uuid}/default-client-scopes/${scope_uuid}" -r "$REALM" >/dev/null
  else
    echo "Client '${client_id}' already has default scope 'groups-scope'."
  fi
}

ensure_group() {
  local name="$1"

  if [[ -z "$name" ]]; then
    return
  fi

  if [[ -n "$(group_uuid "$name")" ]]; then
    echo "Group '${name}' already exists."
  else
    echo "Creating group '${name}'."
    kc create groups -r "$REALM" -s "name=${name}" >/dev/null
  fi
}

ensure_user() {
  local user_json="$1"
  local email first_name last_name enabled email_verified user_id password

  email="$(jq -r '.email' <<<"$user_json")"
  first_name="$(jq -r '.firstName // ""' <<<"$user_json")"
  last_name="$(jq -r '.lastName // ""' <<<"$user_json")"
  enabled="$(jq -r '.enabled // true' <<<"$user_json")"
  email_verified="$(jq -r '.emailVerified // true' <<<"$user_json")"
  password="$(jq -r '.temporaryPassword // ""' <<<"$user_json")"

  if [[ -z "$email" || "$email" == "null" ]]; then
    echo "User without email in ${CONFIG_FILE}." >&2
    exit 1
  fi

  user_id="$(user_uuid "$email")"
  if [[ -n "$user_id" ]]; then
    echo "Updating user '${email}'."
    kc update "users/${user_id}" -r "$REALM" \
      -s "username=${email}" \
      -s "email=${email}" \
      -s "firstName=${first_name}" \
      -s "lastName=${last_name}" \
      -s "enabled=${enabled}" \
      -s "emailVerified=${email_verified}" >/dev/null
  else
    echo "Creating user '${email}'."
    kc create users -r "$REALM" \
      -s "username=${email}" \
      -s "email=${email}" \
      -s "firstName=${first_name}" \
      -s "lastName=${last_name}" \
      -s "enabled=${enabled}" \
      -s "emailVerified=${email_verified}" >/dev/null
    user_id="$(user_uuid "$email")"
  fi

  if [[ -n "$password" && "$password" != "null" ]]; then
    echo "Setting temporary password for '${email}'."
    kc set-password -r "$REALM" --userid "$user_id" --new-password "$password" --temporary >/dev/null
  fi

  jq -r '.appRoles[]? // empty' <<<"$user_json" | while IFS= read -r role; do
    [[ -z "$role" ]] && continue
    ensure_app_role "$CLIENT_ID" "$role"
    echo "Granting role '${CLIENT_ID}/${role}' to '${email}'."
    kc add-roles -r "$REALM" --uusername "$email" --cclientid "$CLIENT_ID" --rolename "$role" >/dev/null 2>&1 || true
  done

  jq -r '
    [
      (.teams[]? | if type == "string" then . else .name end),
      (.teamRoles.member[]?),
      (.teamRoles.manager[]?),
      (.teamRoles.owner[]?)
    ]
    | map(select(. != null and . != ""))
    | unique[]
  ' <<<"$user_json" | while IFS= read -r team; do
    local group_id
    ensure_group "$team"
    group_id="$(group_uuid "$team")"
    echo "Adding '${email}' to group '${team}'."
    kc update "users/${user_id}/groups/${group_id}" -r "$REALM" >/dev/null 2>&1 || true
  done
}

echo "Provisioning Keycloak identity from ${CONFIG_FILE}"
echo "Realm: ${REALM}"
echo "Client: ${CLIENT_ID}"

ensure_login
ensure_groups_scope "$CLIENT_ID"

jq -r '.appRoles[]? // empty' "$CONFIG_FILE" | while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  ensure_app_role "$CLIENT_ID" "$role"
done

jq -r '.teams[]? | if type == "string" then . else .name end' "$CONFIG_FILE" | while IFS= read -r team; do
  ensure_group "$team"
done

jq -c '.users[]?' "$CONFIG_FILE" | while IFS= read -r user_json; do
  ensure_user "$user_json"
done

echo "Keycloak identity provisioning complete."
echo "Note: team owner/manager/member fields are preserved in the source file but only Keycloak groups and app roles are applied here."
echo "Fred/OpenFGA team ownership remains an application-domain provisioning step."
