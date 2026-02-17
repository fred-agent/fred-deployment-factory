#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/.env"

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

ensure_membership_tuple() {
  local user="$1"
  local team="$2"
  local object="team:${team}"

  if tuple_exists "$user" member "$object"; then
    ((SKIPPED_TUPLES+=1))
    return 0
  fi

  write_tuple "$user" member "$object"
  ((ADDED_TUPLES+=1))
  CHANGED=1
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
OPENFGA_SEED_FILE="${OPENFGA_SEED_FILE:-${SCRIPT_DIR}/openfga-seed.json}"
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
[[ -f "$OPENFGA_SEED_FILE" ]] || die "OpenFGA seed file not found: ${OPENFGA_SEED_FILE}"

jq -e '.teams | type == "array"' "$OPENFGA_SEED_FILE" >/dev/null || die "invalid seed file format: .teams must be an array"
jq -e '.users | type == "array"' "$OPENFGA_SEED_FILE" >/dev/null || die "invalid seed file format: .users must be an array"

CHANGED=0
ADDED_TUPLES=0
SKIPPED_TUPLES=0

declare -A TEAM_EXISTS=()
declare -A KEYCLOAK_USER_IDS=()

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
done < <(jq -r '.teams[]? // empty' "$OPENFGA_SEED_FILE")

log "authenticating with Keycloak admin API"
KEYCLOAK_ADMIN_TOKEN="$(kc_admin_token)"

while IFS=$'\t' read -r username team; do
  local_user_id=""
  [[ -n "$username" ]] || continue
  [[ -n "$team" ]] || continue

  if [[ -z "${TEAM_EXISTS[$team]:-}" ]]; then
    warn "team '${team}' is referenced by user '${username}' but missing from .teams list"
    TEAM_EXISTS["$team"]=1
  fi

  local_user_id="$(kc_user_id_by_username "$username")"
  ensure_membership_tuple "user:${local_user_id}" "$team"

  if is_truthy "$OPENFGA_SEED_INCLUDE_USERNAME_USERS"; then
    ensure_membership_tuple "user:${username}" "$team"
  fi
done < <(jq -r '.users[]? | .username as $u | (.teams[]? // empty) | [$u, .] | @tsv' "$OPENFGA_SEED_FILE")

log "post-install completed (store=${STORE_ID}, model=${AUTHORIZATION_MODEL_ID}, tuples_added=${ADDED_TUPLES}, tuples_skipped=${SKIPPED_TUPLES}, changes=${CHANGED})"
