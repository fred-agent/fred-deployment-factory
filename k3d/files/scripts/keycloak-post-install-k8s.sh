#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/.env"

KC_LOG_PREFIX=keycloak-post-install
# shellcheck source=keycloak-lib.sh
source "${SCRIPT_DIR}/keycloak-lib.sh"

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

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_truthy() {
  case "$(to_lower "$1")" in
    true|1|yes|on|always) return 0 ;;
    *) return 1 ;;
  esac
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

# Receivers trust a workload that holds this client's caller role. The client issues
# no tokens; Keycloak adds it to the audience of every holder's tokens.
ensure_delegation_client() {
  local payload

  if [[ -z "$(client_uuid fred-delegation)" ]]; then
    payload="$(jq -nc '{
      clientId: "fred-delegation",
      protocol: "openid-connect",
      enabled: true,
      publicClient: false,
      serviceAccountsEnabled: false,
      standardFlowEnabled: false,
      implicitFlowEnabled: false,
      directAccessGrantsEnabled: false
    }')"
    kc_http_post_json "/clients" "$payload"
    mark_changed
  fi
  ensure_client_role fred-delegation delegation_caller "workload that may speak for a person"
}

should_force_relogin() {
  case "$(to_lower "$KEYCLOAK_FORCE_RELOGIN")" in
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

ensure_client_role app service_agent "application service agent role"

# An application's own service identities are not here: each one declares them
# in its deploy/k3d/identities.yaml, applied by bin/k3d-identities.

# The imported realm ships with zero users (.users=[]): Keycloak still
# auto-creates service-account-<clientId> for every confidential client with
# serviceAccountsEnabled=true (agentic, knowledge-flow, control-plane are
# already declared that way in the realm import), but grants no role. Mirror
# the Docker Compose post-install (docker/keycloak/keycloak-post-install.sh):
# resolve each service account and grant the least privilege it needs.
agentic_service_user="$(wait_for_service_account_username agentic)"
knowledge_flow_service_user="$(wait_for_service_account_username knowledge-flow)"
control_plane_service_user="$(wait_for_service_account_username control-plane)"

# Neither agentic (fred-agents), knowledge-flow, nor control-plane call any
# Keycloak group-admin API (a_get_groups/a_get_group_members) - confirmed
# against the fred product code (AUTHZ-05/06). Only user-scoped realm-management
# roles are granted.
ensure_user_client_role "$agentic_service_user" realm-management query-users
ensure_user_client_role "$agentic_service_user" realm-management view-users

ensure_user_client_role "$knowledge_flow_service_user" realm-management query-users
ensure_user_client_role "$knowledge_flow_service_user" realm-management view-users
if is_truthy "$KEYCLOAK_KF_ENABLE_MANAGE_USERS"; then
  ensure_user_client_role "$knowledge_flow_service_user" realm-management manage-users
fi

ensure_user_client_role "$control_plane_service_user" realm-management query-users
ensure_user_client_role "$control_plane_service_user" realm-management view-users
ensure_user_client_role "$control_plane_service_user" realm-management manage-users

ensure_user_client_role "$agentic_service_user" app service_agent
ensure_user_client_role "$knowledge_flow_service_user" app service_agent
ensure_user_client_role "$control_plane_service_user" app service_agent

# fred-agents speaks for a person on every receiver.
ensure_delegation_client
ensure_user_client_role "$agentic_service_user" fred-delegation delegation_caller

if should_force_relogin; then
  if kc_http_post_empty "/logout-all"; then
    kc_http_post_empty "/push-revocation" || true
    log "forced user re-login in realm '${KEYCLOAK_REALM}' (sessions revoked)"
  else
    warn "failed to call logout-all; users should manually re-login to refresh groups/roles claims"
  fi
fi

log "post-install completed (app=${app_client_uuid}, changes=${CHANGED})"
