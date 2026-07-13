#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/.env"

log() {
  printf '[keycloak-post-install] %s\n' "$*"
}

warn() {
  printf '[keycloak-post-install] WARN: %s\n' "$*" >&2
}

die() {
  printf '[keycloak-post-install] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

read_env_file_var() {
  local key="$1"
  local value=""

  if [[ -f "$ENV_FILE" ]]; then
    value="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
  fi

  printf '%s' "$value"
}

is_truthy() {
  case "${1,,}" in
    true|1|yes|on|always) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_keycloak() {
  local attempts="${1:-120}"
  local i=1
  local http_code=""

  while (( i <= attempts )); do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' "${KEYCLOAK_SERVER_URL}/realms/master/.well-known/openid-configuration" || true)"
    if [[ "$http_code" == "200" ]]; then
      return 0
    fi
    sleep 2
    ((i++))
  done

  return 1
}

require_cmd jq
require_cmd curl

KEYCLOAK_REALM="${KEYCLOAK_REALM:-app}"
KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL:-http://keycloak:8080}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_USERNAME:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_USERNAME="$(read_env_file_var KC_BOOTSTRAP_ADMIN_USERNAME)"
fi
KC_BOOTSTRAP_ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_PASSWORD="$(read_env_file_var KC_BOOTSTRAP_ADMIN_PASSWORD)"
fi
KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-Azerty123_}"

KEYCLOAK_AGENTIC_CLIENT_SECRET="${KEYCLOAK_AGENTIC_CLIENT_SECRET:-$(read_env_file_var KEYCLOAK_AGENTIC_CLIENT_SECRET)}"
KEYCLOAK_AGENTIC_CLIENT_SECRET="${KEYCLOAK_AGENTIC_CLIENT_SECRET:-Azerty123_}"

KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET="${KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET:-$(read_env_file_var KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET)}"
KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET="${KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET:-Azerty123_}"

KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET="${KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET:-$(read_env_file_var KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET)}"
KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET="${KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET:-Azerty123_}"

KEYCLOAK_KF_ENABLE_MANAGE_USERS="${KEYCLOAK_KF_ENABLE_MANAGE_USERS:-$(read_env_file_var KEYCLOAK_KF_ENABLE_MANAGE_USERS)}"
KEYCLOAK_KF_ENABLE_MANAGE_USERS="${KEYCLOAK_KF_ENABLE_MANAGE_USERS:-true}"

KEYCLOAK_FORCE_RELOGIN="${KEYCLOAK_FORCE_RELOGIN:-$(read_env_file_var KEYCLOAK_FORCE_RELOGIN)}"
KEYCLOAK_FORCE_RELOGIN="${KEYCLOAK_FORCE_RELOGIN:-auto}"

# AUTHZ-05/06: swift-clean never represents a Swift team as a Keycloak group -
# a team is a team_metadata row + OpenFGA relations, created later via the
# control-plane APIs. kea-legacy keeps Keycloak groups so the migration
# rehearsal has an old-world source to translate. Mirrors the same case
# statement in docker-compose/keycloak/keycloak-post-install.sh and
# openfga-post-install.sh.
AUTHZ_MODE="${AUTHZ_MODE:-$(read_env_file_var AUTHZ_MODE)}"
AUTHZ_MODE="${AUTHZ_MODE:-swift-clean}"
case "${AUTHZ_MODE,,}" in
  swift|swift-clean)
    AUTHZ_MODE="swift-clean"
    ;;
  kea|kea-legacy)
    AUTHZ_MODE="kea-legacy"
    ;;
  *)
    die "unsupported AUTHZ_MODE='${AUTHZ_MODE}' (supported: swift-clean, kea-legacy)"
    ;;
esac

DEMO_IDENTITY_CONFIG_FILE="${DEMO_IDENTITY_CONFIG_FILE:-$(read_env_file_var DEMO_IDENTITY_CONFIG_FILE)}"
DEMO_IDENTITY_CONFIG_FILE="${DEMO_IDENTITY_CONFIG_FILE:-${SCRIPT_DIR}/../openfga/openfga-seed.json}"
DEMO_IDENTITY_DEFAULT_PASSWORD="${DEMO_IDENTITY_DEFAULT_PASSWORD:-$(read_env_file_var DEMO_IDENTITY_DEFAULT_PASSWORD)}"
DEMO_IDENTITY_DEFAULT_PASSWORD="${DEMO_IDENTITY_DEFAULT_PASSWORD:-Azerty123_}"
DEMO_IDENTITY_RESET_PASSWORDS="${DEMO_IDENTITY_RESET_PASSWORDS:-$(read_env_file_var DEMO_IDENTITY_RESET_PASSWORDS)}"
DEMO_IDENTITY_RESET_PASSWORDS="${DEMO_IDENTITY_RESET_PASSWORDS:-true}"

CHANGED=0
KEYCLOAK_ADMIN_HTTP_TOKEN=""

mark_changed() {
  CHANGED=1
}

client_uuid() {
  local client_id="$1"
  local encoded_client_id
  encoded_client_id="$(uri_encode "$client_id")"
  kc_http_get "/clients?clientId=${encoded_client_id}" | jq -r '.[0].id // empty'
}

client_scope_uuid() {
  local scope_name="$1"
  local encoded_scope_name
  encoded_scope_name="$(uri_encode "$scope_name")"
  kc_http_get "/client-scopes?name=${encoded_scope_name}" \
    | jq -r --arg scope_name "$scope_name" '.[] | select(.name == $scope_name) | .id' | head -n1
}

ensure_client_exists() {
  local client_id="$1"
  local uuid
  local payload

  uuid="$(client_uuid "$client_id")"
  if [[ -z "$uuid" ]]; then
    payload="$(jq -nc --arg client_id "$client_id" '{clientId: $client_id, enabled: true, protocol: "openid-connect"}')"
    kc_http_post_json "/clients" "$payload"
    mark_changed
    uuid="$(client_uuid "$client_id")"
  fi

  [[ -n "$uuid" ]] || die "cannot ensure client '${client_id}'"
  printf '%s' "$uuid"
}

ensure_app_client() {
  local uuid
  local client_json
  local payload

  uuid="$(client_uuid app)"
  if [[ -z "$uuid" ]]; then
    payload="$(jq -nc '{
      clientId: "app",
      protocol: "openid-connect",
      enabled: true,
      publicClient: true,
      standardFlowEnabled: true,
      serviceAccountsEnabled: false
    }')"
    kc_http_post_json "/clients" "$payload"
    mark_changed
    uuid="$(client_uuid app)"
  fi
  [[ -n "$uuid" ]] || die "cannot ensure client 'app'"

  client_json="$(kc_http_get "/clients/${uuid}")"
  if ! jq -e '.enabled == true and .publicClient == true and .standardFlowEnabled == true' >/dev/null <<<"$client_json"; then
    payload="$(jq -c '.enabled = true | .publicClient = true | .standardFlowEnabled = true | .serviceAccountsEnabled = false' <<<"$client_json")"
    kc_http_put_json "/clients/${uuid}" "$payload"
    mark_changed
  fi

  printf '%s' "$uuid"
}

ensure_service_client_confidential() {
  local client_id="$1"
  local desired_secret="$2"
  local uuid
  local client_json
  local current_secret
  local payload

  uuid="$(ensure_client_exists "$client_id")"
  client_json="$(kc_http_get "/clients/${uuid}")"

  if ! jq -e '.enabled == true and .publicClient == false and .serviceAccountsEnabled == true and .clientAuthenticatorType == "client-secret"' >/dev/null <<<"$client_json"; then
    payload="$(jq -c '.enabled = true | .publicClient = false | .serviceAccountsEnabled = true | .clientAuthenticatorType = "client-secret"' <<<"$client_json")"
    kc_http_put_json "/clients/${uuid}" "$payload"
    mark_changed
    client_json="$(kc_http_get "/clients/${uuid}")"
  fi

  current_secret="$(kc_http_get "/clients/${uuid}/client-secret" | jq -r '.value // empty')"
  if [[ "$current_secret" != "$desired_secret" ]]; then
    # The /client-secret POST endpoint always REGENERATES a random value - it
    # cannot be told to set a specific secret. Setting an explicit value
    # requires PUTting the client representation with `secret` set directly
    # (same effect as kcadm's `update clients/{id} -s secret=...`).
    payload="$(jq -c --arg secret "$desired_secret" '.secret = $secret' <<<"$client_json")"
    kc_http_put_json "/clients/${uuid}" "$payload"
    mark_changed
  fi

  current_secret="$(kc_http_get "/clients/${uuid}/client-secret" | jq -r '.value // empty')"
  [[ "$current_secret" == "$desired_secret" ]] || die "failed to apply secret for client '${client_id}'"

  printf '%s' "$uuid"
}

ensure_client_role() {
  local client_id="$1"
  local role_name="$2"
  local description="$3"
  local uuid
  local role_exists
  local payload

  uuid="$(client_uuid "$client_id")"
  [[ -n "$uuid" ]] || die "cannot resolve client '${client_id}' to create role '${role_name}'"

  role_exists="$(kc_http_get "/clients/${uuid}/roles?first=0&max=500" | jq -r --arg role_name "$role_name" '.[] | select(.name == $role_name) | .name' | head -n1)"
  if [[ "$role_exists" == "$role_name" ]]; then
    return
  fi

  payload="$(jq -nc --arg name "$role_name" --arg description "$description" '{name: $name, description: $description}')"
  kc_http_post_json "/clients/${uuid}/roles" "$payload"
  mark_changed
}

wait_for_service_account_username() {
  local client_id="$1"
  local username="service-account-${client_id}"
  local encoded_username
  local attempts=30
  local i=1

  encoded_username="$(uri_encode "$username")"
  while (( i <= attempts )); do
    if kc_http_get "/users?username=${encoded_username}&exact=true" | jq -e 'length > 0' >/dev/null; then
      printf '%s' "$username"
      return 0
    fi
    sleep 1
    ((i++))
  done

  die "service account user '${username}' not found after enabling service account for '${client_id}'"
}

ensure_user_client_role() {
  local username="$1"
  local client_id="$2"
  local role_name="$3"
  local user_id
  local target_client_uuid
  local role_json

  user_id="$(keycloak_user_json_by_username "$username" | jq -r '.id // empty')"
  [[ -n "$user_id" ]] || die "cannot resolve user '${username}' to grant '${client_id}/${role_name}'"
  target_client_uuid="$(client_uuid "$client_id")"
  [[ -n "$target_client_uuid" ]] || die "cannot resolve client '${client_id}' to grant role '${role_name}'"

  if kc_http_get "/users/${user_id}/role-mappings/clients/${target_client_uuid}" \
    | jq -e --arg role_name "$role_name" '.[] | select(.name == $role_name)' >/dev/null; then
    return
  fi

  role_json="$(kc_http_get "/clients/${target_client_uuid}/roles/$(uri_encode "$role_name")")"
  kc_http_post_json "/users/${user_id}/role-mappings/clients/${target_client_uuid}" "[${role_json}]"
  mark_changed
}

uri_encode() {
  local raw="$1"
  jq -rn --arg v "$raw" '$v|@uri'
}

kc_http_admin_token() {
  local response
  local token

  response="$(
    curl -fsS -X POST "${KEYCLOAK_SERVER_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=${KC_BOOTSTRAP_ADMIN_USERNAME}" \
      -d "password=${KC_BOOTSTRAP_ADMIN_PASSWORD}"
  )" || die "failed to authenticate to Keycloak admin API (HTTP)"

  token="$(jq -r '.access_token // empty' <<<"$response")"
  [[ -n "$token" ]] || die "cannot get Keycloak admin access token (HTTP)"
  printf '%s' "$token"
}

kc_http_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local url="${KEYCLOAK_SERVER_URL}/admin/realms/${KEYCLOAK_REALM}${path}"
  local response
  local body
  local status
  local attempt=1
  local max_attempts=2

  while (( attempt <= max_attempts )); do
    if [[ -n "$payload" ]]; then
      response="$(
        curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
          -H "Authorization: Bearer ${KEYCLOAK_ADMIN_HTTP_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "$payload"
      )"
    else
      response="$(
        curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
          -H "Authorization: Bearer ${KEYCLOAK_ADMIN_HTTP_TOKEN}"
      )"
    fi

    body="${response%$'\n'*}"
    status="${response##*$'\n'}"

    if [[ "$status" == "401" && "$attempt" -lt "$max_attempts" ]]; then
      warn "received 401 on ${method} ${path}; refreshing admin token and retrying"
      KEYCLOAK_ADMIN_HTTP_TOKEN="$(kc_http_admin_token)"
      ((attempt++))
      continue
    fi
    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
      die "Keycloak ${method} ${path} failed (${status}): ${body}"
    fi

    printf '%s' "$body"
    return 0
  done

  die "Keycloak ${method} ${path} failed after retry"
}

kc_http_get() { kc_http_request GET "$1"; }
kc_http_post_json() { kc_http_request POST "$1" "$2" >/dev/null; }
kc_http_put_json() { kc_http_request PUT "$1" "$2" >/dev/null; }
kc_http_put_empty() { kc_http_request PUT "$1" >/dev/null; }
kc_http_delete_empty() { kc_http_request DELETE "$1" >/dev/null; }
kc_http_delete_json() { kc_http_request DELETE "$1" "$2" >/dev/null; }
kc_http_post_empty() { kc_http_request POST "$1" >/dev/null; }

declare -a DEMO_MANAGED_TEAMS=()
declare -A DEMO_MANAGED_USERS=()
declare -A DEMO_GROUP_IDS=()
declare -A DEMO_APP_ROLE_JSON_CACHE=()

demo_identity_config_validate() {
  local duplicate_teams
  local duplicate_users
  local invalid_refs

  [[ -f "$DEMO_IDENTITY_CONFIG_FILE" ]] || die "demo identity config file not found: ${DEMO_IDENTITY_CONFIG_FILE}"

  jq -e '
    def role_array($name):
      ((.team_roles[$name] // []) | type == "array") and
      all((.team_roles[$name] // [])[]?; type == "string" and length > 0);
    (.teams | type == "array") and
    (.users | type == "array") and
    all(.teams[]?; type == "string" and length > 0) and
    all(.users[]?;
      (.username | type == "string" and length > 0) and
      ((.teams // []) | type == "array") and
      all((.teams // [])[]?; type == "string" and length > 0) and
      ((.team_roles // {}) | type == "object") and
      role_array("member") and
      role_array("manager") and
      role_array("owner") and
      role_array("team_member") and
      role_array("team_editor") and
      role_array("team_admin") and
      role_array("team_analyst") and
      ((.app_roles // []) | type == "array") and
      all((.app_roles // [])[]?; type == "string" and length > 0)
    )
  ' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null || die "invalid demo identity config format: ${DEMO_IDENTITY_CONFIG_FILE}"

  duplicate_teams="$(jq -r '[.teams[]?] | group_by(.)[] | select(length > 1) | .[0]' "$DEMO_IDENTITY_CONFIG_FILE")"
  [[ -z "$duplicate_teams" ]] || die "duplicate teams in demo identity config: ${duplicate_teams//$'\n'/, }"

  duplicate_users="$(jq -r '[.users[]?.username] | group_by(.)[] | select(length > 1) | .[0]' "$DEMO_IDENTITY_CONFIG_FILE")"
  [[ -z "$duplicate_users" ]] || die "duplicate usernames in demo identity config: ${duplicate_users//$'\n'/, }"

  invalid_refs="$(
    jq -r '
      (.teams // []) as $teams
      | .users[]?
      | .username as $u
      | (
          (.teams // [])[],
          (.team_roles.member // [])[],
          (.team_roles.manager // [])[],
          (.team_roles.owner // [])[],
          (.team_roles.team_member // [])[],
          (.team_roles.team_editor // [])[],
          (.team_roles.team_admin // [])[],
          (.team_roles.team_analyst // [])[]
        )
      | select(($teams | index(.)) == null)
      | [$u, .] | @tsv
    ' "$DEMO_IDENTITY_CONFIG_FILE"
  )"
  if [[ -n "$invalid_refs" ]]; then
    while IFS=$'\t' read -r username team; do
      [[ -n "$username" && -n "$team" ]] || continue
      die "demo identity config references unknown team '${team}' for user '${username}'"
    done <<<"$invalid_refs"
  fi
}

demo_identity_load_managed_teams() {
  mapfile -t DEMO_MANAGED_TEAMS < <(jq -r '.teams[]? // empty' "$DEMO_IDENTITY_CONFIG_FILE")
}

demo_identity_load_managed_users() {
  local username
  DEMO_MANAGED_USERS=()
  while IFS= read -r username; do
    [[ -n "$username" ]] || continue
    DEMO_MANAGED_USERS["$username"]=1
  done < <(jq -r '.users[]?.username // empty' "$DEMO_IDENTITY_CONFIG_FILE")
}

keycloak_group_id_by_path() {
  local group_path="$1"
  local group_id
  local groups_json

  if [[ -n "${DEMO_GROUP_IDS[$group_path]:-}" ]]; then
    printf '%s' "${DEMO_GROUP_IDS[$group_path]}"
    return 0
  fi

  groups_json="$(kc_http_get "/groups?first=0&max=500")"
  group_id="$(jq -r --arg p "$group_path" '.[] | select(.path == $p) | .id' <<<"$groups_json" | head -n1)"
  if [[ -n "$group_id" ]]; then
    DEMO_GROUP_IDS["$group_path"]="$group_id"
  fi
  printf '%s' "$group_id"
}

ensure_demo_team_group() {
  local team="$1"
  local group_path="/${team}"
  local group_id
  local payload

  group_id="$(keycloak_group_id_by_path "$group_path")"
  if [[ -n "$group_id" ]]; then
    DEMO_GROUP_IDS["$group_path"]="$group_id"
    return 0
  fi

  payload="$(jq -nc --arg name "$team" '{name: $name}')"
  kc_http_post_json "/groups" "$payload"
  mark_changed

  group_id="$(keycloak_group_id_by_path "$group_path")"
  [[ -n "$group_id" ]] || die "cannot resolve Keycloak group id for '${group_path}' after creation"
  DEMO_GROUP_IDS["$group_path"]="$group_id"
}

keycloak_user_json_by_username() {
  local username="$1"
  local encoded_username
  encoded_username="$(uri_encode "$username")"
  kc_http_get "/users?username=${encoded_username}&exact=true" | jq -c '.[0] // empty'
}

keycloak_app_role_json_by_name() {
  local app_client_uuid="$1"
  local role_name="$2"
  local encoded_role
  local role_json
  local cache_key="${app_client_uuid}:${role_name}"

  if [[ -n "${DEMO_APP_ROLE_JSON_CACHE[$cache_key]:-}" ]]; then
    printf '%s' "${DEMO_APP_ROLE_JSON_CACHE[$cache_key]}"
    return 0
  fi

  encoded_role="$(uri_encode "$role_name")"
  role_json="$(kc_http_get "/clients/${app_client_uuid}/roles/${encoded_role}")"
  DEMO_APP_ROLE_JSON_CACHE["$cache_key"]="$role_json"
  printf '%s' "$role_json"
}

ensure_demo_user_profile() {
  local user_json="$1"
  local username enabled email first_name last_name password
  local current_json user_id current_enabled current_email current_first_name current_last_name
  local desired_payload reset_payload
  local user_created=0

  username="$(jq -r '.username' <<<"$user_json")"
  enabled="$(jq -r 'if has("enabled") then (.enabled | tostring) else "true" end' <<<"$user_json")"
  email="$(jq -r '.email // empty' <<<"$user_json")"
  first_name="$(jq -r '.first_name // empty' <<<"$user_json")"
  last_name="$(jq -r '.last_name // empty' <<<"$user_json")"
  password="$(jq -r '.password // empty' <<<"$user_json")"

  [[ -n "$email" ]] || email="${username}@app.com"
  [[ -n "$first_name" ]] || first_name="${username^}"
  [[ -n "$password" ]] || password="$DEMO_IDENTITY_DEFAULT_PASSWORD"

  current_json="$(keycloak_user_json_by_username "$username")"
  if [[ -z "$current_json" ]]; then
    desired_payload="$(
      jq -nc \
        --arg username "$username" \
        --arg enabled "$enabled" \
        --arg email "$email" \
        --arg first_name "$first_name" \
        --arg last_name "$last_name" \
        '{
          username: $username,
          enabled: ($enabled == "true"),
          email: $email,
          emailVerified: false,
          firstName: $first_name,
          lastName: $last_name
        }'
    )"
    kc_http_post_json "/users" "$desired_payload"
    mark_changed
    user_created=1
    current_json="$(keycloak_user_json_by_username "$username")"
  fi

  user_id="$(jq -r '.id // empty' <<<"$current_json")"
  [[ -n "$user_id" ]] || die "cannot resolve Keycloak user '${username}'"

  current_enabled="$(jq -r 'if has("enabled") then (.enabled | tostring) else "false" end' <<<"$current_json")"
  current_email="$(jq -r '.email // ""' <<<"$current_json")"
  current_first_name="$(jq -r '.firstName // ""' <<<"$current_json")"
  current_last_name="$(jq -r '.lastName // ""' <<<"$current_json")"

  if [[ "$current_enabled" != "$enabled" || "$current_email" != "$email" || "$current_first_name" != "$first_name" || "$current_last_name" != "$last_name" ]]; then
    desired_payload="$(
      jq -nc \
        --arg id "$user_id" \
        --arg username "$username" \
        --arg enabled "$enabled" \
        --arg email "$email" \
        --arg first_name "$first_name" \
        --arg last_name "$last_name" \
        '{
          id: $id,
          username: $username,
          enabled: ($enabled == "true"),
          email: $email,
          emailVerified: false,
          firstName: $first_name,
          lastName: $last_name
        }'
    )"
    kc_http_put_json "/users/${user_id}" "$desired_payload"
    mark_changed
  fi

  if (( user_created == 1 )) || is_truthy "$DEMO_IDENTITY_RESET_PASSWORDS"; then
    reset_payload="$(jq -nc --arg password "$password" '{type: "password", value: $password, temporary: false}')"
    kc_http_put_json "/users/${user_id}/reset-password" "$reset_payload"
    mark_changed
  fi

  printf '%s' "$user_id"
}

ensure_demo_user_team_memberships() {
  local user_id="$1"
  local user_json="$2"
  local current_groups_json desired_paths team group_path group_id

  current_groups_json="$(kc_http_get "/users/${user_id}/groups")"
  desired_paths="$(
    jq -r '
      [
        (.teams // [])[],
        (.team_roles.member // [])[],
        (.team_roles.manager // [])[],
        (.team_roles.owner // [])[],
        (.team_roles.team_member // [])[],
        (.team_roles.team_editor // [])[],
        (.team_roles.team_admin // [])[],
        (.team_roles.team_analyst // [])[]
      ]
      | unique[]
      | "/" + .
    ' <<<"$user_json" | sort -u
  )"

  while IFS= read -r team; do
    [[ -n "$team" ]] || continue
    group_path="/${team}"
    group_id="${DEMO_GROUP_IDS[$group_path]:-}"
    if [[ -z "$group_id" ]]; then
      group_id="$(keycloak_group_id_by_path "$group_path")"
      [[ -n "$group_id" ]] || die "cannot resolve Keycloak group id for '${group_path}'"
      DEMO_GROUP_IDS["$group_path"]="$group_id"
    fi

    if grep -Fxq "$group_path" <<<"$desired_paths"; then
      if ! jq -e --arg p "$group_path" '.[] | select(.path == $p)' >/dev/null <<<"$current_groups_json"; then
        kc_http_put_empty "/users/${user_id}/groups/${group_id}"
        mark_changed
      fi
    else
      if jq -e --arg p "$group_path" '.[] | select(.path == $p)' >/dev/null <<<"$current_groups_json"; then
        kc_http_delete_empty "/users/${user_id}/groups/${group_id}"
        mark_changed
      fi
    fi
  done < <(printf '%s\n' "${DEMO_MANAGED_TEAMS[@]}")
}

ensure_demo_user_app_roles() {
  local app_client_uuid="$1"
  local user_id="$2"
  local user_json="$3"
  local current_roles_json desired_roles current_roles missing_roles extra_roles role role_json payload
  local -a add_role_jsons=()
  local -a remove_role_jsons=()

  current_roles_json="$(kc_http_get "/users/${user_id}/role-mappings/clients/${app_client_uuid}")"
  desired_roles="$(jq -r '(.app_roles // [])[]? // empty' <<<"$user_json" | sort -u)"
  current_roles="$(jq -r '.[].name // empty' <<<"$current_roles_json" | sort -u)"

  missing_roles="$(comm -23 <(printf '%s\n' "$desired_roles" | sed '/^$/d') <(printf '%s\n' "$current_roles" | sed '/^$/d') || true)"
  extra_roles="$(comm -13 <(printf '%s\n' "$desired_roles" | sed '/^$/d') <(printf '%s\n' "$current_roles" | sed '/^$/d') || true)"

  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    role_json="$(keycloak_app_role_json_by_name "$app_client_uuid" "$role")"
    add_role_jsons+=("$role_json")
  done <<<"$missing_roles"

  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    role_json="$(keycloak_app_role_json_by_name "$app_client_uuid" "$role")"
    remove_role_jsons+=("$role_json")
  done <<<"$extra_roles"

  if ((${#add_role_jsons[@]} > 0)); then
    payload="$(printf '%s\n' "${add_role_jsons[@]}" | jq -s '.')"
    kc_http_post_json "/users/${user_id}/role-mappings/clients/${app_client_uuid}" "$payload"
    mark_changed
  fi

  if ((${#remove_role_jsons[@]} > 0)); then
    payload="$(printf '%s\n' "${remove_role_jsons[@]}" | jq -s '.')"
    kc_http_delete_json "/users/${user_id}/role-mappings/clients/${app_client_uuid}" "$payload"
    mark_changed
  fi
}

ensure_demo_app_role_definitions() {
  local declared_role

  ensure_client_role app admin "application administrator role"
  ensure_client_role app editor "application editor role"
  ensure_client_role app viewer "application viewer role"
  ensure_client_role app service_agent "application service agent role"

  while IFS= read -r declared_role; do
    [[ -n "$declared_role" ]] || continue
    case "$declared_role" in
      admin|editor|viewer|service_agent) continue ;;
    esac
    ensure_client_role app "$declared_role" "application role '${declared_role}' (demo identity config)"
  done < <(jq -r '.users[]? | (.app_roles // [])[]? // empty' "$DEMO_IDENTITY_CONFIG_FILE" | sort -u)
}

reconcile_demo_users_exact() {
  local users_json username user_id

  users_json="$(kc_http_get "/users?first=0&max=500")"
  while IFS=$'\t' read -r username user_id; do
    [[ -n "$username" && -n "$user_id" ]] || continue
    if [[ "$username" == service-account-* ]]; then
      continue
    fi
    if [[ -z "${DEMO_MANAGED_USERS[$username]:-}" ]]; then
      kc_http_delete_empty "/users/${user_id}"
      mark_changed
    fi
  done < <(jq -r '.[] | [.username // "", .id // ""] | @tsv' <<<"$users_json")
}

reconcile_demo_groups_exact() {
  local groups_json group_path group_id

  groups_json="$(kc_http_get "/groups?first=0&max=500")"
  while IFS=$'\t' read -r group_path group_id; do
    [[ -n "$group_path" && -n "$group_id" ]] || continue
    if ! grep -Fxq "$group_path" < <(printf '%s\n' "${DEMO_MANAGED_TEAMS[@]}" | sed 's#^#/#'); then
      kc_http_delete_empty "/groups/${group_id}"
      mark_changed
    fi
  done < <(jq -r '.[] | [.path // "", .id // ""] | @tsv' <<<"$groups_json")
}

apply_demo_identity_config() {
  local app_client_uuid="$1"
  local user_json user_id existing_groups_json

  demo_identity_config_validate
  demo_identity_load_managed_teams
  demo_identity_load_managed_users
  log "applying demo identity config '${DEMO_IDENTITY_CONFIG_FILE}' (authz mode: ${AUTHZ_MODE})"

  DEMO_GROUP_IDS=()
  DEMO_APP_ROLE_JSON_CACHE=()

  reconcile_demo_users_exact

  if [[ "$AUTHZ_MODE" == "kea-legacy" ]]; then
    while IFS= read -r team; do
      [[ -n "$team" ]] || continue
      ensure_demo_team_group "$team"
    done < <(printf '%s\n' "${DEMO_MANAGED_TEAMS[@]}")
  else
    log "swift-clean: not creating Keycloak groups for teams - a Swift team is a team_metadata row + OpenFGA relations, bootstrapped later via the control-plane APIs"
  fi

  ensure_demo_app_role_definitions

  while IFS= read -r user_json; do
    [[ -n "$user_json" ]] || continue
    user_id="$(ensure_demo_user_profile "$user_json")"
    if [[ "$AUTHZ_MODE" == "kea-legacy" ]]; then
      ensure_demo_user_team_memberships "$user_id" "$user_json"
    fi
    ensure_demo_user_app_roles "$app_client_uuid" "$user_id" "$user_json"
  done < <(jq -c '.users[]?' "$DEMO_IDENTITY_CONFIG_FILE")

  if [[ "$AUTHZ_MODE" == "kea-legacy" ]]; then
    reconcile_demo_groups_exact
  else
    existing_groups_json="$(kc_http_get "/groups?first=0&max=1")"
    if [[ -n "$existing_groups_json" && "$existing_groups_json" != "[]" ]]; then
      warn "swift-clean: pre-existing Keycloak groups were found and are left untouched (not read by any Swift authorization path); reinstall the release for a from-scratch swift-clean proof"
    fi
  fi
}

groups_mapper_payload() {
  cat <<'EOF'
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "groups",
    "full.path": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "id.token.claim": "true",
    "multivalued": "true"
  }
}
EOF
}

ensure_groups_scope() {
  local scope_name="groups-scope"
  local scope_uuid
  local mapper_json
  local mapper_uuid
  local payload

  scope_uuid="$(client_scope_uuid "$scope_name")"
  if [[ -z "$scope_uuid" ]]; then
    payload="$(jq -nc --arg name "$scope_name" '{name: $name, protocol: "openid-connect"}')"
    kc_http_post_json "/client-scopes" "$payload"
    mark_changed
    scope_uuid="$(client_scope_uuid "$scope_name")"
  fi
  [[ -n "$scope_uuid" ]] || die "cannot ensure client scope '${scope_name}'"

  mapper_json="$(kc_http_get "/client-scopes/${scope_uuid}/protocol-mappers/models" \
    | jq -c '.[] | select(.name == "groups" and .protocolMapper == "oidc-group-membership-mapper")' \
    | head -n1 || true)"

  if [[ -z "$mapper_json" ]]; then
    payload="$(groups_mapper_payload)"
    kc_http_post_json "/client-scopes/${scope_uuid}/protocol-mappers/models" "$payload"
    mark_changed
  else
    mapper_uuid="$(jq -r '.id // empty' <<<"$mapper_json")"
    [[ -n "$mapper_uuid" ]] || die "cannot resolve groups mapper id for scope '${scope_name}'"

    if ! jq -e '
      .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and
      .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true" and
      .config["id.token.claim"] == "true" and
      .config["multivalued"] == "true"
    ' >/dev/null <<<"$mapper_json"; then
      payload="$(groups_mapper_payload | jq -c --arg id "$mapper_uuid" '.id = $id')"
      kc_http_put_json "/client-scopes/${scope_uuid}/protocol-mappers/models/${mapper_uuid}" "$payload"
      mark_changed
    fi
  fi

  printf '%s' "$scope_uuid"
}

ensure_app_default_scope() {
  local app_uuid="$1"
  local scope_uuid="$2"
  local scope_name="groups-scope"

  if kc_http_get "/clients/${app_uuid}/default-client-scopes" \
    | jq -e --arg scope_name "$scope_name" '.[] | select(.name == $scope_name)' >/dev/null; then
    return
  fi

  kc_http_put_empty "/clients/${app_uuid}/default-client-scopes/${scope_uuid}"
  mark_changed
}

ensure_app_default_scope_detached() {
  local app_uuid="$1"
  local scope_name="groups-scope"
  local scope_uuid

  scope_uuid="$(client_scope_uuid "$scope_name")"
  [[ -n "$scope_uuid" ]] || return 0

  if ! kc_http_get "/clients/${app_uuid}/default-client-scopes" \
    | jq -e --arg scope_name "$scope_name" '.[] | select(.name == $scope_name)' >/dev/null; then
    return 0
  fi

  kc_http_delete_empty "/clients/${app_uuid}/default-client-scopes/${scope_uuid}"
  mark_changed
}

should_force_relogin() {
  case "${KEYCLOAK_FORCE_RELOGIN,,}" in
    true|1|yes|on|always) return 0 ;;
    false|0|no|off|never) return 1 ;;
    auto|"")
      if (( CHANGED == 1 )); then
        return 0
      fi
      return 1
      ;;
    *)
      warn "unknown KEYCLOAK_FORCE_RELOGIN='${KEYCLOAK_FORCE_RELOGIN}', falling back to auto mode"
      if (( CHANGED == 1 )); then
        return 0
      fi
      return 1
      ;;
  esac
}

log "waiting for Keycloak API at '${KEYCLOAK_SERVER_URL}'"
wait_for_keycloak || die "Keycloak did not become ready at ${KEYCLOAK_SERVER_URL}"

log "authenticating with Keycloak admin API"
KEYCLOAK_ADMIN_HTTP_TOKEN="$(kc_http_admin_token)"

app_client_uuid="$(client_uuid app)"
[[ -n "$app_client_uuid" ]] || die "cannot resolve client 'app' from imported realm"

if [[ "$AUTHZ_MODE" == "kea-legacy" ]]; then
  groups_scope_uuid="$(ensure_groups_scope)"
  ensure_app_default_scope "$app_client_uuid" "$groups_scope_uuid"
else
  # swift-clean: no groups claim is required or consumed by any Swift
  # authorization path. The imported realm never attaches groups-scope by
  # default; this is a no-op unless a prior kea-legacy run (or hand
  # provisioning) attached it, in which case it is detached. Its absence
  # after this step is the expected, not an error, state either way.
  ensure_app_default_scope_detached "$app_client_uuid"
fi

apply_demo_identity_config "$app_client_uuid"

if should_force_relogin; then
  if kc_http_post_empty "/logout-all"; then
    kc_http_post_empty "/push-revocation" || true
    log "forced user re-login in realm '${KEYCLOAK_REALM}' (sessions revoked)"
  else
    warn "failed to call logout-all; users should manually re-login to refresh groups/roles claims"
  fi
fi

log "post-install completed (app=${app_client_uuid}, changes=${CHANGED})"
