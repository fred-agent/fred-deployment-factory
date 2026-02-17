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

get_container_env() {
  local container="$1"
  local key="$2"

  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
    | sed -n "s/^${key}=//p" \
    | head -n1
}

is_truthy() {
  case "${1,,}" in
    true|1|yes|on|always) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_container() {
  local container="$1"
  local attempts="${2:-60}"
  local i=1

  while (( i <= attempts )); do
    if docker container inspect "$container" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    ((i++))
  done

  return 1
}

wait_for_container_running() {
  local container="$1"
  local attempts="${2:-60}"
  local i=1
  local running

  while (( i <= attempts )); do
    running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [[ "$running" == "true" ]]; then
      return 0
    fi
    sleep 2
    ((i++))
  done

  return 1
}

wait_for_container_health() {
  local container="$1"
  local attempts="${2:-90}"
  local i=1
  local status

  while (( i <= attempts )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    if [[ "$status" == "healthy" || "$status" == "none" ]]; then
      return 0
    fi
    sleep 2
    ((i++))
  done

  return 1
}

require_cmd docker
require_cmd jq

KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-app-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-app}"
KEYCLOAK_SERVER_URL="${KEYCLOAK_SERVER_URL:-http://localhost:8080}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_USERNAME:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_USERNAME="$(get_container_env "$KEYCLOAK_CONTAINER" KC_BOOTSTRAP_ADMIN_USERNAME || true)"
fi
if [[ -z "${KC_BOOTSTRAP_ADMIN_USERNAME:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_USERNAME="$(read_env_file_var KC_BOOTSTRAP_ADMIN_USERNAME)"
fi
KC_BOOTSTRAP_ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"

if [[ -z "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_PASSWORD="$(get_container_env "$KEYCLOAK_CONTAINER" KC_BOOTSTRAP_ADMIN_PASSWORD || true)"
fi
if [[ -z "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  KC_BOOTSTRAP_ADMIN_PASSWORD="$(read_env_file_var KC_BOOTSTRAP_ADMIN_PASSWORD)"
fi
KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-Azerty123_}"

KEYCLOAK_AGENTIC_CLIENT_SECRET="${KEYCLOAK_AGENTIC_CLIENT_SECRET:-$(read_env_file_var KEYCLOAK_AGENTIC_CLIENT_SECRET)}"
KEYCLOAK_AGENTIC_CLIENT_SECRET="${KEYCLOAK_AGENTIC_CLIENT_SECRET:-Azerty123_}"

KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET="${KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET:-$(read_env_file_var KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET)}"
KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET="${KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET:-Azerty123_}"

KEYCLOAK_KF_ENABLE_MANAGE_USERS="${KEYCLOAK_KF_ENABLE_MANAGE_USERS:-$(read_env_file_var KEYCLOAK_KF_ENABLE_MANAGE_USERS)}"
KEYCLOAK_KF_ENABLE_MANAGE_USERS="${KEYCLOAK_KF_ENABLE_MANAGE_USERS:-true}"

KEYCLOAK_FORCE_RELOGIN="${KEYCLOAK_FORCE_RELOGIN:-$(read_env_file_var KEYCLOAK_FORCE_RELOGIN)}"
KEYCLOAK_FORCE_RELOGIN="${KEYCLOAK_FORCE_RELOGIN:-auto}"

CHANGED=0

mark_changed() {
  CHANGED=1
}

kc() {
  docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@" \
    2> >(sed '/^[[:space:]]*$/d' >&2)
}

client_uuid() {
  local client_id="$1"
  kc get clients -r "$KEYCLOAK_REALM" -q "clientId=${client_id}" -c \
    | jq -r '.[0].id // empty'
}

client_scope_uuid() {
  local scope_name="$1"
  kc get client-scopes -r "$KEYCLOAK_REALM" -q "name=${scope_name}" -c \
    | jq -r --arg scope_name "$scope_name" '.[] | select(.name == $scope_name) | .id' \
    | head -n1
}

ensure_client_exists() {
  local client_id="$1"
  local uuid

  uuid="$(client_uuid "$client_id")"
  if [[ -z "$uuid" ]]; then
    kc create clients -r "$KEYCLOAK_REALM" -s "clientId=${client_id}" -s enabled=true -s protocol=openid-connect >/dev/null
    mark_changed
    uuid="$(client_uuid "$client_id")"
  fi

  [[ -n "$uuid" ]] || die "cannot ensure client '${client_id}'"
  printf '%s' "$uuid"
}

ensure_app_client() {
  local uuid
  local client_json

  uuid="$(client_uuid app)"
  if [[ -z "$uuid" ]]; then
    kc create clients -r "$KEYCLOAK_REALM" \
      -s clientId=app \
      -s protocol=openid-connect \
      -s enabled=true \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s serviceAccountsEnabled=false >/dev/null
    mark_changed
    uuid="$(client_uuid app)"
  fi
  [[ -n "$uuid" ]] || die "cannot ensure client 'app'"

  client_json="$(kc get "clients/${uuid}" -r "$KEYCLOAK_REALM" -c)"
  if ! jq -e '.enabled == true and .publicClient == true and .standardFlowEnabled == true' >/dev/null <<<"$client_json"; then
    kc update "clients/${uuid}" -r "$KEYCLOAK_REALM" \
      -s enabled=true \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s serviceAccountsEnabled=false >/dev/null
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

  uuid="$(ensure_client_exists "$client_id")"
  client_json="$(kc get "clients/${uuid}" -r "$KEYCLOAK_REALM" -c)"

  if ! jq -e '.enabled == true and .publicClient == false and .serviceAccountsEnabled == true and .clientAuthenticatorType == "client-secret"' >/dev/null <<<"$client_json"; then
    kc update "clients/${uuid}" -r "$KEYCLOAK_REALM" \
      -s enabled=true \
      -s publicClient=false \
      -s serviceAccountsEnabled=true \
      -s clientAuthenticatorType=client-secret >/dev/null
    mark_changed
  fi

  current_secret="$(kc get "clients/${uuid}/client-secret" -r "$KEYCLOAK_REALM" -c | jq -r '.value // empty')"
  if [[ "$current_secret" != "$desired_secret" ]]; then
    if ! kc create "clients/${uuid}/client-secret" -r "$KEYCLOAK_REALM" -s "value=${desired_secret}" >/dev/null 2>&1; then
      kc update "clients/${uuid}" -r "$KEYCLOAK_REALM" -s "secret=${desired_secret}" >/dev/null
    fi
    mark_changed
  fi

  current_secret="$(kc get "clients/${uuid}/client-secret" -r "$KEYCLOAK_REALM" -c | jq -r '.value // empty')"
  [[ "$current_secret" == "$desired_secret" ]] || die "failed to apply secret for client '${client_id}'"

  printf '%s' "$uuid"
}

ensure_client_role() {
  local client_id="$1"
  local role_name="$2"
  local description="$3"
  local uuid

  if kc get-roles -r "$KEYCLOAK_REALM" --cclientid "$client_id" --rolename "$role_name" -c >/dev/null 2>&1; then
    return
  fi

  uuid="$(client_uuid "$client_id")"
  [[ -n "$uuid" ]] || die "cannot resolve client '${client_id}' to create role '${role_name}'"
  kc create "clients/${uuid}/roles" -r "$KEYCLOAK_REALM" -s "name=${role_name}" -s "description=${description}" >/dev/null
  mark_changed
}

wait_for_service_account_username() {
  local client_id="$1"
  local username="service-account-${client_id}"
  local attempts=30
  local i=1

  while (( i <= attempts )); do
    if kc get users -r "$KEYCLOAK_REALM" -q "username=${username}" -c | jq -e 'length > 0' >/dev/null; then
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

  if kc get-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$client_id" -c \
    | jq -e --arg role_name "$role_name" '.[] | select(.name == $role_name)' >/dev/null; then
    return
  fi

  kc add-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$client_id" --rolename "$role_name" >/dev/null
  mark_changed
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

  scope_uuid="$(client_scope_uuid "$scope_name")"
  if [[ -z "$scope_uuid" ]]; then
    kc create client-scopes -r "$KEYCLOAK_REALM" -s "name=${scope_name}" -s protocol=openid-connect >/dev/null
    mark_changed
    scope_uuid="$(client_scope_uuid "$scope_name")"
  fi
  [[ -n "$scope_uuid" ]] || die "cannot ensure client scope '${scope_name}'"

  mapper_json="$(kc get "client-scopes/${scope_uuid}/protocol-mappers/models" -r "$KEYCLOAK_REALM" -c \
    | jq -c '.[] | select(.name == "groups" and .protocolMapper == "oidc-group-membership-mapper")' \
    | head -n1 || true)"

  if [[ -z "$mapper_json" ]]; then
    groups_mapper_payload \
      | docker exec -i "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh create "client-scopes/${scope_uuid}/protocol-mappers/models" -r "$KEYCLOAK_REALM" -f - >/dev/null
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
      groups_mapper_payload \
        | docker exec -i "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh update "client-scopes/${scope_uuid}/protocol-mappers/models/${mapper_uuid}" -r "$KEYCLOAK_REALM" -f - >/dev/null
      mark_changed
    fi
  fi

  printf '%s' "$scope_uuid"
}

ensure_app_default_scope() {
  local app_uuid="$1"
  local scope_uuid="$2"
  local scope_name="groups-scope"

  if kc get "clients/${app_uuid}/default-client-scopes" -r "$KEYCLOAK_REALM" -c \
    | jq -e --arg scope_name "$scope_name" '.[] | select(.name == $scope_name)' >/dev/null; then
    return
  fi

  if ! kc update "clients/${app_uuid}/default-client-scopes/${scope_uuid}" -r "$KEYCLOAK_REALM" -n -b '{}' >/dev/null 2>&1; then
    kc update "clients/${app_uuid}/default-client-scopes/${scope_uuid}" -r "$KEYCLOAK_REALM" -n >/dev/null
  fi
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

log "waiting for Keycloak container '${KEYCLOAK_CONTAINER}'"
wait_for_container "$KEYCLOAK_CONTAINER" || die "container '${KEYCLOAK_CONTAINER}' not found"
wait_for_container_running "$KEYCLOAK_CONTAINER" || die "container '${KEYCLOAK_CONTAINER}' is not running"
wait_for_container_health "$KEYCLOAK_CONTAINER" || die "container '${KEYCLOAK_CONTAINER}' did not become healthy"

log "authenticating with Keycloak admin API"
kc config credentials \
  --server "$KEYCLOAK_SERVER_URL" \
  --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
  --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

app_client_uuid="$(ensure_app_client)"
agentic_client_uuid="$(ensure_service_client_confidential agentic "$KEYCLOAK_AGENTIC_CLIENT_SECRET")"
knowledge_flow_client_uuid="$(ensure_service_client_confidential knowledge-flow "$KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET")"

ensure_client_role app admin "application administrator role"
ensure_client_role app editor "application editor role"
ensure_client_role app viewer "application viewer role"

agentic_service_user="$(wait_for_service_account_username agentic)"
knowledge_flow_service_user="$(wait_for_service_account_username knowledge-flow)"

ensure_user_client_role "$agentic_service_user" realm-management query-users
ensure_user_client_role "$agentic_service_user" realm-management query-groups
ensure_user_client_role "$agentic_service_user" realm-management view-users
ensure_user_client_role "$agentic_service_user" account view-groups

ensure_user_client_role "$knowledge_flow_service_user" realm-management query-users
ensure_user_client_role "$knowledge_flow_service_user" realm-management query-groups
ensure_user_client_role "$knowledge_flow_service_user" realm-management view-users
ensure_user_client_role "$knowledge_flow_service_user" account view-groups
if is_truthy "$KEYCLOAK_KF_ENABLE_MANAGE_USERS"; then
  ensure_user_client_role "$knowledge_flow_service_user" realm-management manage-users
fi

groups_scope_uuid="$(ensure_groups_scope)"
ensure_app_default_scope "$app_client_uuid" "$groups_scope_uuid"

if should_force_relogin; then
  if kc create "realms/${KEYCLOAK_REALM}/logout-all" >/dev/null 2>&1; then
    kc create "realms/${KEYCLOAK_REALM}/push-revocation" >/dev/null 2>&1 || true
    log "forced user re-login in realm '${KEYCLOAK_REALM}' (sessions revoked)"
  else
    warn "failed to call logout-all; users should manually re-login to refresh groups/roles claims"
  fi
fi

log "post-install completed (app=${app_client_uuid}, agentic=${agentic_client_uuid}, knowledge-flow=${knowledge_flow_client_uuid}, changes=${CHANGED})"
