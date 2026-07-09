#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/.env"
DEFAULT_DEMO_IDENTITY_CONFIG_FILE="${REPO_ROOT}/config/configuration.yaml"
DEFAULT_SHARED_OPENFGA_SEED_FILE="${REPO_ROOT}/helm/fred-stack/files/openfga/openfga-seed.json"
DEFAULT_LEGACY_OPENFGA_SEED_FILE="${SCRIPT_DIR}/openfga-seed.json"

log() {
  printf '[openfga-post-install] %s\n' "$*"
}

warn() {
  printf '[openfga-post-install] WARN: %s\n' "$*" >&2
}

die() {
  printf '[openfga-post-install] ERROR: %s\n' "$*" >&2
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

wait_for_openfga() {
  local attempts="${1:-90}"
  local i=1
  local status

  while (( i <= attempts )); do
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${OPENFGA_API_TOKEN}" \
      "${OPENFGA_URL}/stores" || true)"
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep 2
    ((i++))
  done

  return 1
}

fga_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local url="${OPENFGA_URL}${path}"
  local response
  local body
  local status

  if [[ -n "$payload" ]]; then
    response="$(
      curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer ${OPENFGA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload"
    )"
  else
    response="$(
      curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer ${OPENFGA_API_TOKEN}"
    )"
  fi

  body="${response%$'\n'*}"
  status="${response##*$'\n'}"

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    die "OpenFGA ${method} ${path} failed (${status}): ${body}"
  fi

  printf '%s' "$body"
}

kc_admin_token() {
  local response
  local token

  response="$(
    curl -fsS -X POST "${KEYCLOAK_SERVER_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=${KC_BOOTSTRAP_ADMIN_USERNAME}" \
      -d "password=${KC_BOOTSTRAP_ADMIN_PASSWORD}"
  )" || die "failed to authenticate to Keycloak admin API"

  token="$(jq -r '.access_token // empty' <<<"$response")"
  [[ -n "$token" ]] || die "cannot get Keycloak admin access token"
  printf '%s' "$token"
}

kc_user_id_by_username() {
  local username="$1"
  local encoded_username
  local response
  local user_id

  if [[ -n "${KEYCLOAK_USER_IDS[$username]:-}" ]]; then
    printf '%s' "${KEYCLOAK_USER_IDS[$username]}"
    return 0
  fi

  encoded_username="$(jq -rn --arg value "$username" '$value|@uri')"
  response="$(
    curl -fsS \
      -H "Authorization: Bearer ${KEYCLOAK_ADMIN_TOKEN}" \
      "${KEYCLOAK_SERVER_URL}/admin/realms/${KEYCLOAK_REALM}/users?username=${encoded_username}&exact=true"
  )" || die "failed to query Keycloak user '${username}'"

  user_id="$(jq -r '.[0].id // empty' <<<"$response")"
  [[ -n "$user_id" ]] || die "Keycloak user '${username}' not found in realm '${KEYCLOAK_REALM}'"

  KEYCLOAK_USER_IDS["$username"]="$user_id"
  printf '%s' "$user_id"
}

kc_group_id_by_team_name() {
  local team_name="$1"
  local encoded_path
  local encoded_name
  local response
  local group_id

  if [[ -n "${KEYCLOAK_GROUP_IDS[$team_name]:-}" ]]; then
    printf '%s' "${KEYCLOAK_GROUP_IDS[$team_name]}"
    return 0
  fi

  # Allow explicit UUID team ids in config (advanced usage).
  if [[ "$team_name" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    KEYCLOAK_GROUP_IDS["$team_name"]="$team_name"
    printf '%s' "$team_name"
    return 0
  fi

  encoded_path="$(jq -rn --arg value "/${team_name}" '$value|@uri')"
  response="$(
    curl -fsS \
      -H "Authorization: Bearer ${KEYCLOAK_ADMIN_TOKEN}" \
      "${KEYCLOAK_SERVER_URL}/admin/realms/${KEYCLOAK_REALM}/group-by-path/${encoded_path}" \
      || true
  )"
  group_id="$(jq -r '.id // empty' <<<"$response" 2>/dev/null || true)"

  if [[ -z "$group_id" ]]; then
    encoded_name="$(jq -rn --arg value "$team_name" '$value|@uri')"
    response="$(
      curl -fsS \
        -H "Authorization: Bearer ${KEYCLOAK_ADMIN_TOKEN}" \
        "${KEYCLOAK_SERVER_URL}/admin/realms/${KEYCLOAK_REALM}/groups?search=${encoded_name}&briefRepresentation=true&first=0&max=200" \
        || true
    )"
    group_id="$(
      jq -r --arg team_name "$team_name" '.[] | select((.name // "") == $team_name) | .id' <<<"$response" \
        | head -n1
    )"
  fi

  [[ -n "$group_id" ]] || die "Keycloak group '${team_name}' not found in realm '${KEYCLOAK_REALM}'"

  KEYCLOAK_GROUP_IDS["$team_name"]="$group_id"
  printf '%s' "$group_id"
}

normalize_model_json() {
  jq -cS '
    {
      schema_version: .schema_version,
      type_definitions: (
        (.type_definitions // [])
        | map({
            type: .type,
            relations: (.relations // {}),
            metadata: (.metadata // {}),
            conditions: (.conditions // {})
          })
        | sort_by(.type)
      ),
      conditions: (.conditions // {})
    }
  '
}

resolve_store_id() {
  local stores_json
  local store_id
  local create_payload
  local create_json

  stores_json="$(fga_request GET "/stores")"
  store_id="$(jq -r --arg name "$OPENFGA_STORE_NAME" '.stores[]? | select(.name == $name) | .id' <<<"$stores_json" | head -n1)"

  if [[ -n "$store_id" ]]; then
    printf '%s' "$store_id"
    return 0
  fi

  create_payload="$(jq -nc --arg name "$OPENFGA_STORE_NAME" '{name: $name}')"
  create_json="$(fga_request POST "/stores" "$create_payload")"
  store_id="$(jq -r '.id // empty' <<<"$create_json")"
  [[ -n "$store_id" ]] || die "failed to create OpenFGA store '${OPENFGA_STORE_NAME}'"
  CHANGED=1
  printf '%s' "$store_id"
}

ensure_authorization_model() {
  local model_payload
  local desired_model
  local latest_models
  local current_model_id
  local current_model
  local create_response

  model_payload="$(cat "$OPENFGA_MODEL_FILE")"
  desired_model="$(normalize_model_json <"$OPENFGA_MODEL_FILE")"

  latest_models="$(fga_request GET "/stores/${STORE_ID}/authorization-models?page_size=1")"
  current_model_id="$(jq -r '.authorization_models[0].id // empty' <<<"$latest_models")"

  if [[ -z "$current_model_id" ]]; then
    create_response="$(fga_request POST "/stores/${STORE_ID}/authorization-models" "$model_payload")"
    AUTHORIZATION_MODEL_ID="$(jq -r '.authorization_model_id // empty' <<<"$create_response")"
    [[ -n "$AUTHORIZATION_MODEL_ID" ]] || die "failed to create OpenFGA authorization model"
    CHANGED=1
    return 0
  fi

  current_model="$(jq -c '.authorization_models[0]' <<<"$latest_models" | normalize_model_json)"
  if [[ "$current_model" == "$desired_model" ]]; then
    AUTHORIZATION_MODEL_ID="$current_model_id"
    return 0
  fi

  create_response="$(fga_request POST "/stores/${STORE_ID}/authorization-models" "$model_payload")"
  AUTHORIZATION_MODEL_ID="$(jq -r '.authorization_model_id // empty' <<<"$create_response")"
  [[ -n "$AUTHORIZATION_MODEL_ID" ]] || die "failed to update OpenFGA authorization model"
  CHANGED=1
}

tuple_exists() {
  local user="$1"
  local relation="$2"
  local object="$3"
  local payload
  local read_response
  local tuple_count

  payload="$(jq -nc \
    --arg user "$user" \
    --arg relation "$relation" \
    --arg object "$object" \
    '{tuple_key: {user: $user, relation: $relation, object: $object}, page_size: 1}')"

  read_response="$(fga_request POST "/stores/${STORE_ID}/read" "$payload")"
  tuple_count="$(jq -r '.tuples | length' <<<"$read_response")"
  [[ "$tuple_count" -gt 0 ]]
}

write_tuple() {
  local user="$1"
  local relation="$2"
  local object="$3"
  local payload

  payload="$(jq -nc \
    --arg authz_model_id "$AUTHORIZATION_MODEL_ID" \
    --arg user "$user" \
    --arg relation "$relation" \
    --arg object "$object" \
    '{authorization_model_id: $authz_model_id, writes: {tuple_keys: [{user: $user, relation: $relation, object: $object}]}}')"

  fga_request POST "/stores/${STORE_ID}/write" "$payload" >/dev/null
}

ensure_team_relation_tuple() {
  local user="$1"
  local relation="$2"
  local team="$3"
  local object="team:${team}"

  if tuple_exists "$user" "$relation" "$object"; then
    ((SKIPPED_TUPLES+=1))
    return 0
  fi

  write_tuple "$user" "$relation" "$object"
  ((ADDED_TUPLES+=1))
  CHANGED=1
}

ensure_team_role_closure() {
  local user="$1"
  local role="$2"
  local team="$3"

  case "$role" in
    member)
      ensure_team_relation_tuple "$user" member "$team"
      ;;
    manager)
      ensure_team_relation_tuple "$user" manager "$team"
      ensure_team_relation_tuple "$user" member "$team"
      ;;
    owner)
      ensure_team_relation_tuple "$user" owner "$team"
      ensure_team_relation_tuple "$user" manager "$team"
      ensure_team_relation_tuple "$user" member "$team"
      ;;
    *)
      die "unsupported team role '${role}' in demo identity config (supported: member, manager, owner)"
      ;;
  esac
}

# AUTHZ-05 (fred FRED-AUTHORIZATION-TARGET-MODEL-RFC): platform_admin/platform_observer
# are stored-only OpenFGA relations on the singleton organization - never derived from
# Keycloak app_roles. Seeded here from a user's `platform_roles`, independent of
# `app_roles` (legacy Keycloak admin/editor/viewer), so demo users can isolate the new
# target relation from every legacy escalation path.
ensure_platform_role_tuple() {
  local user="$1"
  local relation="$2"
  local object="organization:fred"

  if tuple_exists "$user" "$relation" "$object"; then
    ((SKIPPED_TUPLES+=1))
    return 0
  fi

  write_tuple "$user" "$relation" "$object"
  ((ADDED_TUPLES+=1))
  CHANGED=1
}

ensure_platform_role_closure() {
  local user="$1"
  local role="$2"

  case "$role" in
    admin)
      ensure_platform_role_tuple "$user" platform_admin
      ;;
    observer)
      ensure_platform_role_tuple "$user" platform_observer
      ;;
    *)
      die "unsupported platform role '${role}' in demo identity config (supported: admin, observer)"
      ;;
  esac
}

require_cmd curl
require_cmd jq

OPENFGA_URL="${OPENFGA_URL:-http://localhost:9080}"
OPENFGA_URL="${OPENFGA_URL%/}"
OPENFGA_API_TOKEN="${OPENFGA_API_TOKEN:-$(read_env_file_var OPENFGA_API_TOKEN)}"
OPENFGA_API_TOKEN="${OPENFGA_API_TOKEN:-Azerty123_}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-$(read_env_file_var OPENFGA_STORE_NAME)}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-fred}"
OPENFGA_MODEL_FILE="${OPENFGA_MODEL_FILE:-${SCRIPT_DIR}/openfga-model.json}"
if [[ -z "${DEMO_IDENTITY_CONFIG_FILE:-}" ]]; then
  DEMO_IDENTITY_CONFIG_FILE="$(read_env_file_var DEMO_IDENTITY_CONFIG_FILE)"
fi
if [[ -z "${DEMO_IDENTITY_CONFIG_FILE:-}" ]]; then
  if [[ -f "$DEFAULT_DEMO_IDENTITY_CONFIG_FILE" ]]; then
    DEMO_IDENTITY_CONFIG_FILE="$DEFAULT_DEMO_IDENTITY_CONFIG_FILE"
  elif [[ -n "${OPENFGA_SEED_FILE:-}" ]]; then
    DEMO_IDENTITY_CONFIG_FILE="$OPENFGA_SEED_FILE"
  elif [[ -f "$DEFAULT_SHARED_OPENFGA_SEED_FILE" ]]; then
    DEMO_IDENTITY_CONFIG_FILE="$DEFAULT_SHARED_OPENFGA_SEED_FILE"
  else
    DEMO_IDENTITY_CONFIG_FILE="$DEFAULT_LEGACY_OPENFGA_SEED_FILE"
  fi
fi
if [[ -z "${OPENFGA_SEED_FILE:-}" ]]; then
  if [[ -f "$DEFAULT_SHARED_OPENFGA_SEED_FILE" ]]; then
    OPENFGA_SEED_FILE="$DEFAULT_SHARED_OPENFGA_SEED_FILE"
  else
    OPENFGA_SEED_FILE="$DEFAULT_LEGACY_OPENFGA_SEED_FILE"
  fi
fi
OPENFGA_SEED_INCLUDE_USERNAME_USERS="${OPENFGA_SEED_INCLUDE_USERNAME_USERS:-$(read_env_file_var OPENFGA_SEED_INCLUDE_USERNAME_USERS)}"
OPENFGA_SEED_INCLUDE_USERNAME_USERS="${OPENFGA_SEED_INCLUDE_USERNAME_USERS:-true}"

KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL:-http://localhost:8080}"
KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL%/}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-app}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_USERNAME:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_USERNAME="$(read_env_file_var KC_BOOTSTRAP_ADMIN_USERNAME)"
fi
KC_BOOTSTRAP_ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_PASSWORD="$(read_env_file_var KC_BOOTSTRAP_ADMIN_PASSWORD)"
fi
KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-Azerty123_}"

[[ -f "$OPENFGA_MODEL_FILE" ]] || die "OpenFGA model file not found: ${OPENFGA_MODEL_FILE}"
[[ -f "$DEMO_IDENTITY_CONFIG_FILE" ]] || die "demo identity config file not found: ${DEMO_IDENTITY_CONFIG_FILE}"

jq -e '.teams | type == "array"' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null || die "invalid demo identity config format: .teams must be an array"
jq -e '.users | type == "array"' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null || die "invalid demo identity config format: .users must be an array"
jq -e '
  all(.users[]?;
    (.username|type=="string") and
    ((.teams // [])|type=="array") and
    all((.teams // [])[]?; type == "string" and length > 0) and
    (
      (.team_roles // {}) | type == "object"
    ) and
    (
      ((.team_roles.member // [])|type=="array") and
      ((.team_roles.manager // [])|type=="array") and
      ((.team_roles.owner // [])|type=="array")
    ) and
    all((.team_roles.member // [])[]?; type == "string" and length > 0) and
    all((.team_roles.manager // [])[]?; type == "string" and length > 0) and
    all((.team_roles.owner // [])[]?; type == "string" and length > 0) and
    ((.platform_roles // [])|type=="array") and
    all((.platform_roles // [])[]?; type == "string" and (. == "admin" or . == "observer"))
  )
' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null || die "invalid demo identity config format: each user must define username, optional teams[], optional team_roles.{member,manager,owner}[], and optional platform_roles[] (admin|observer only)"

log "using demo identity config file '${DEMO_IDENTITY_CONFIG_FILE}'"

CHANGED=0
ADDED_TUPLES=0
SKIPPED_TUPLES=0

declare -A TEAM_EXISTS=()
declare -A KEYCLOAK_USER_IDS=()
declare -A KEYCLOAK_GROUP_IDS=()

log "waiting for OpenFGA API at '${OPENFGA_URL}'"
wait_for_openfga || die "OpenFGA API is not reachable at ${OPENFGA_URL}"

STORE_ID="$(resolve_store_id)"
log "using OpenFGA store '${OPENFGA_STORE_NAME}' (${STORE_ID})"

AUTHORIZATION_MODEL_ID=""
ensure_authorization_model
[[ -n "$AUTHORIZATION_MODEL_ID" ]] || die "cannot resolve OpenFGA authorization model id"
log "using authorization model '${AUTHORIZATION_MODEL_ID}'"

while IFS= read -r team; do
  [[ -n "$team" ]] || continue
  TEAM_EXISTS["$team"]=1
done < <(jq -r '.teams[]? // empty' "$DEMO_IDENTITY_CONFIG_FILE")

log "authenticating with Keycloak admin API"
KEYCLOAK_ADMIN_TOKEN="$(kc_admin_token)"

while IFS=$'\t' read -r username relation team; do
  local_user_id=""
  local_team_id=""
  [[ -n "$username" ]] || continue
  [[ -n "$relation" ]] || continue
  [[ -n "$team" ]] || continue

  if [[ -z "${TEAM_EXISTS[$team]:-}" ]]; then
    warn "team '${team}' is referenced by user '${username}' but missing from .teams list"
    TEAM_EXISTS["$team"]=1
  fi

  local_user_id="$(kc_user_id_by_username "$username")"
  local_team_id="$(kc_group_id_by_team_name "$team")"
  ensure_team_role_closure "user:${local_user_id}" "$relation" "$local_team_id"

  if is_truthy "$OPENFGA_SEED_INCLUDE_USERNAME_USERS"; then
    ensure_team_role_closure "user:${username}" "$relation" "$local_team_id"
  fi
done < <(
  jq -r '
    .users[]? as $u
    | ($u.username // empty) as $name
    | (
        (($u.teams // [])[]? | [$name, "member", .]) ,
        (($u.team_roles.member // [])[]? | [$name, "member", .]) ,
        (($u.team_roles.manager // [])[]? | [$name, "manager", .]) ,
        (($u.team_roles.owner // [])[]? | [$name, "owner", .])
      )
    | @tsv
  ' "$DEMO_IDENTITY_CONFIG_FILE"
)

while IFS=$'\t' read -r username role; do
  local_user_id=""
  [[ -n "$username" ]] || continue
  [[ -n "$role" ]] || continue

  local_user_id="$(kc_user_id_by_username "$username")"
  ensure_platform_role_closure "user:${local_user_id}" "$role"

  if is_truthy "$OPENFGA_SEED_INCLUDE_USERNAME_USERS"; then
    ensure_platform_role_closure "user:${username}" "$role"
  fi
done < <(
  jq -r '
    .users[]? as $u
    | ($u.username // empty) as $name
    | (($u.platform_roles // [])[]? | [$name, .])
    | @tsv
  ' "$DEMO_IDENTITY_CONFIG_FILE"
)

log "post-install completed (store=${STORE_ID}, model=${AUTHORIZATION_MODEL_ID}, tuples_added=${ADDED_TUPLES}, tuples_skipped=${SKIPPED_TUPLES}, changes=${CHANGED})"
