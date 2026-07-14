#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# FRED preflight diagnostics (READ-ONLY)
# -----------------------------------------------------------------------------
# This script ONLY inspects configuration/state and never writes anything.
# It checks:
# 1) Keycloak realm/clients, app role definitions, groups scope mapper,
#    service-account rights
# 2) OpenFGA store presence + authorization-model shape (AUTHZ-05 target
#    relations present, no platform-to-team escalation)
# 3) Langfuse endpoints + S3 bucket diagnostics
#
# `make docker-up` always produces an empty realm and an empty OpenFGA store
# (AUTHZ-07): no demo users, no demo teams, no OpenFGA tuples. This script
# therefore validates INFRASTRUCTURE shape only (clients, role definitions,
# service accounts, the OpenFGA model) - it makes no assertion about specific
# users or team memberships, because none exist at docker-up time. The first
# platform_admin is created afterward via POST /bootstrap/platform-admin
# (control-plane, fred monorepo); any further identity/team provisioning is a
# separate, later, declarative import step owned by fred, not this repo.
# -----------------------------------------------------------------------------

# Configuration (override with env vars if needed)
KC="${KC:-http://localhost:8080}"
FGA="${FGA:-http://localhost:9080}"
REALM="${REALM:-app}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-fred}"

KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-Azerty123_}"
OPENFGA_TOKEN="${OPENFGA_TOKEN:-Azerty123_}"

TEMPORAL_UI_HOST="${TEMPORAL_UI_HOST:-${DOCKER_COMPOSE_HOST_FQDN:-localhost}}"
TEMPORAL_UI_PORT="${TEMPORAL_UI_PORT:-8233}"
TEMPORAL_UI_URL="${TEMPORAL_UI_URL:-http://${TEMPORAL_UI_HOST}:${TEMPORAL_UI_PORT}}"

LANGFUSE_UI_HOST="${LANGFUSE_UI_HOST:-${DOCKER_COMPOSE_HOST_FQDN:-localhost}}"
LANGFUSE_UI_PORT="${LANGFUSE_UI_PORT:-3001}"
LANGFUSE_UI_URL="${LANGFUSE_UI_URL:-http://${LANGFUSE_UI_HOST}:${LANGFUSE_UI_PORT}}"
LANGFUSE_WORKER_HOST="${LANGFUSE_WORKER_HOST:-127.0.0.1}"
LANGFUSE_WORKER_PORT="${LANGFUSE_WORKER_PORT:-3030}"
LANGFUSE_WORKER_URL="${LANGFUSE_WORKER_URL:-http://${LANGFUSE_WORKER_HOST}:${LANGFUSE_WORKER_PORT}}"
LANGFUSE_S3_URL="${LANGFUSE_S3_URL:-${LANGFUSE_S3_BATCH_EXPORT_EXTERNAL_ENDPOINT:-http://${DOCKER_COMPOSE_HOST_FQDN:-localhost}:8333}}"
LANGFUSE_EVENT_BUCKET="${LANGFUSE_EVENT_BUCKET:-${LANGFUSE_S3_EVENT_UPLOAD_BUCKET:-langfuse}}"
LANGFUSE_MEDIA_BUCKET="${LANGFUSE_MEDIA_BUCKET:-${LANGFUSE_S3_MEDIA_UPLOAD_BUCKET:-langfuse}}"
LANGFUSE_EXPORT_BUCKET="${LANGFUSE_EXPORT_BUCKET:-${LANGFUSE_S3_BATCH_EXPORT_BUCKET:-langfuse}}"
SEAWEEDFS_ADMIN_USER="${SEAWEEDFS_ADMIN_USER:-admin}"
SEAWEEDFS_ADMIN_PASSWORD="${SEAWEEDFS_ADMIN_PASSWORD:-Azerty123_}"
PREFLIGHT_HTTP_RETRY_DELAY_SEC="${PREFLIGHT_HTTP_RETRY_DELAY_SEC:-2}"
LANGFUSE_UI_HTTP_RETRIES="${LANGFUSE_UI_HTTP_RETRIES:-30}"
LANGFUSE_WORKER_HTTP_RETRIES="${LANGFUSE_WORKER_HTTP_RETRIES:-10}"
LANGFUSE_S3_HTTP_RETRIES="${LANGFUSE_S3_HTTP_RETRIES:-10}"

# Stack profile (extended|base). In the "base" profile Langfuse (and its Redis/
# ClickHouse dependencies) is not deployed, so its endpoint/S3 prerequisite checks
# are skipped instead of being reported as critical failures.
STACK="${STACK:-base}"

REQUIRED_CLIENTS=(app agentic knowledge-flow control-plane fred-evaluation-worker)
EXPECTED_SERVICE_APP_ROLE="service_agent"
# Pre-AUTHZ-05 user-facing app roles. The realm import (AUTHZ-07) never
# defines them anymore - team and platform roles live in OpenFGA, never as
# Keycloak app roles. Their presence on a from-scratch realm is a critical
# regression, not a missing prerequisite.
LEGACY_APP_CLIENT_ROLES=(admin editor viewer)
EXPECTED_GROUPS_SCOPE_NAME="groups-scope"
EXPECTED_GROUPS_MAPPER_NAME="groups"

# No app calls a Keycloak group-admin API (AUTHZ-05/06: OpenFGA is the sole
# authorization source), so no service account needs query-groups/view-groups -
# see docs/swift/platform/KEYCLOAK.md.
EXPECTED_AGENTIC_RM_ROLES="query-users view-users"
EXPECTED_AGENTIC_ACCOUNT_ROLES=""

EXPECTED_KF_RM_ROLES_BASE="query-users view-users"
EXPECTED_KF_RM_ROLES_WITH_MANAGE="query-users view-users manage-users"
EXPECTED_KF_ACCOUNT_ROLES=""
EXPECTED_CP_RM_ROLES="query-users view-users manage-users"
EXPECTED_CP_ACCOUNT_ROLES=""

# Colors (disabled when not a TTY)
if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  CYAN=$'\033[36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  RESET=""
fi

step() { printf "%s\n" "${BOLD}${BLUE}==> $*${RESET}"; }
info() { printf "%s\n" "${CYAN}• $*${RESET}"; }
ok() { printf "%s\n" "${GREEN}✓ $*${RESET}"; }
warn() { printf "%s\n" "${YELLOW}! $*${RESET}"; }
fail() { printf "%s\n" "${RED}✗ $*${RESET}"; }
die() { fail "$*"; exit 1; }

CRITICAL_ISSUES=0
WARNING_ISSUES=0

mark_critical() {
  ((CRITICAL_ISSUES+=1))
  fail "$*"
}

mark_warning() {
  ((WARNING_ISSUES+=1))
  warn "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

probe_http_status_with_retries() {
  local url="$1"
  local retries="$2"
  local delay_sec="$3"
  local http_code="000"
  local attempt

  for ((attempt=1; attempt<=retries; attempt+=1)); do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" || true)"
    # Stop waiting once endpoint is reachable and not a server-startup error.
    if [[ "${http_code}" != "000" && ! "${http_code}" =~ ^5[0-9][0-9]$ ]]; then
      printf '%s' "${http_code}"
      return 0
    fi
    if (( attempt < retries )); then
      sleep "${delay_sec}"
    fi
  done

  printf '%s' "${http_code}"
}

json_post() {
  local url="$1"
  local auth_token="$2"
  local payload="$3"
  curl -fsS -X POST "$url" \
    -H "Authorization: Bearer $auth_token" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

is_truthy() {
  case "${1,,}" in
    true|1|yes|on|always) return 0 ;;
    *) return 1 ;;
  esac
}

# Langfuse is only deployed in the "extended" stack profile.
langfuse_expected() {
  [[ "${STACK,,}" != "base" ]]
}

words_to_sorted_lines() {
  local words="$1"
  tr ' ' '\n' <<<"$words" | sed '/^$/d' | sort -u
}

sorted_lines_to_csv() {
  local lines="$1"
  local out
  if [[ -z "$lines" ]]; then
    printf '(none)'
    return 0
  fi
  out="$(printf '%s\n' "$lines" | sed '/^$/d' | tr '\n' ',' | sed 's/,$//')"
  out="${out//,/, }"
  printf '%s' "$out"
}

missing_lines() {
  local expected="$1"
  local actual="$2"
  comm -23 <(printf '%s\n' "$expected" | sed '/^$/d' | sort -u) <(printf '%s\n' "$actual" | sed '/^$/d' | sort -u) || true
}

extra_lines() {
  local expected="$1"
  local actual="$2"
  comm -13 <(printf '%s\n' "$expected" | sed '/^$/d' | sort -u) <(printf '%s\n' "$actual" | sed '/^$/d' | sort -u) || true
}

common_lines() {
  local a="$1"
  local b="$2"
  comm -12 <(printf '%s\n' "$a" | sed '/^$/d' | sort -u) <(printf '%s\n' "$b" | sed '/^$/d' | sort -u) || true
}

contains_line() {
  local needle="$1"
  local haystack="$2"
  grep -Fxq "$needle" <<<"$haystack"
}

keycloak_client_uuid() {
  local client_id="$1"
  curl -fsS -H "Authorization: Bearer ${ADM}" \
    "$KC/admin/realms/${REALM}/clients?clientId=${client_id}" | jq -r '.[0].id // empty'
}

keycloak_service_account_user_json() {
  local client_uuid="$1"
  curl -fsS -H "Authorization: Bearer ${ADM}" \
    "$KC/admin/realms/${REALM}/clients/${client_uuid}/service-account-user"
}

keycloak_user_client_roles() {
  local user_id="$1"
  local client_uuid="$2"
  curl -fsS -H "Authorization: Bearer ${ADM}" \
    "$KC/admin/realms/${REALM}/users/${user_id}/role-mappings/clients/${client_uuid}" \
    | jq -r '.[].name' | sort -u
}

keycloak_client_scope_uuid() {
  local scope_name="$1"
  curl -fsS -H "Authorization: Bearer ${ADM}" \
    "$KC/admin/realms/${REALM}/client-scopes" \
    | jq -r --arg scope_name "$scope_name" '.[] | select(.name == $scope_name) | .id' \
    | head -n1
}

step "Pre-check dependencies"
require_cmd curl
require_cmd jq
ok "curl/jq available"

printf "\n%s\n" "${BOLD}Context:${RESET}"
info "Keycloak: ${KC} (realm=${REALM})"
info "OpenFGA: ${FGA} (store=${OPENFGA_STORE_NAME})"
info "Temporal UI: ${TEMPORAL_UI_URL}"
info "Langfuse UI: ${LANGFUSE_UI_URL}"
info "Langfuse worker: ${LANGFUSE_WORKER_URL}"
info "Langfuse S3 endpoint (external check): ${LANGFUSE_S3_URL}"
info "Langfuse buckets: event=${LANGFUSE_EVENT_BUCKET}, media=${LANGFUSE_MEDIA_BUCKET}, export=${LANGFUSE_EXPORT_BUCKET}"
info "Mode: READ-ONLY (no write calls are executed)"
info "Terminology: team = Keycloak group, permission = Keycloak client-role, ReBAC right = OpenFGA tuple"

step "Authenticate to Keycloak admin API"
ADM="$(
  curl -fsS -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" | jq -r '.access_token // empty'
)"
if [[ -z "${ADM}" ]]; then
  mark_critical "Unable to get Keycloak admin token"
else
  ok "Keycloak admin token obtained"
fi

REALM_NAME_GAPS=0
REALM_EXISTENCE_GAPS=0
if [[ -n "${ADM}" ]]; then
  step "Validate Keycloak realm"
  if [[ "${REALM}" == "app" ]]; then
    ok "Realm name matches expected value: app"
  else
    ((REALM_NAME_GAPS+=1))
    mark_critical "Realm should be 'app' for this setup (current='${REALM}')"
  fi

  if curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}" >/dev/null; then
    ok "Realm '${REALM}' exists"
  else
    ((REALM_EXISTENCE_GAPS+=1))
    mark_critical "Realm '${REALM}' does not exist in Keycloak"
  fi
fi

FOUND_CLIENTS=0
if [[ -n "${ADM}" ]]; then
  step "Validate required Keycloak clients"
  for c in "${REQUIRED_CLIENTS[@]}"; do
    cnt="$(
      curl -fsS -H "Authorization: Bearer ${ADM}" \
        "$KC/admin/realms/${REALM}/clients?clientId=${c}" | jq 'length'
    )"
    if [[ "$cnt" -ge 1 ]]; then
      ok "Client '${c}' present"
      ((FOUND_CLIENTS+=1))
    else
      mark_critical "Client '${c}' missing"
    fi
  done
fi

RESIDUAL_GROUPS=0
if [[ -n "${ADM}" ]]; then
  step "Keycloak groups (none expected - AUTHZ-05/06, a team is never a Keycloak group)"
  groups_json="$(curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/groups?first=0&max=500" 2>/dev/null || echo '[]')"
  group_count="$(jq 'length' <<<"$groups_json" 2>/dev/null || echo 0)"
  if [[ "$group_count" -eq 0 ]]; then
    ok "No Keycloak groups present, as expected (a team is never a Keycloak group)"
  else
    RESIDUAL_GROUPS="$group_count"
    residual_group_paths="$(jq -r '.[].path' <<<"$groups_json" | sort -u)"
    mark_warning "Residual Keycloak groups present (not read by any Swift authorization path): $(sorted_lines_to_csv "$residual_group_paths")"
  fi
fi

AGENTIC_ROLE_GAPS=0
KNOWLEDGE_FLOW_ROLE_GAPS=0
CONTROL_PLANE_ROLE_GAPS=0
EVAL_WORKER_ROLE_GAPS=0
AGENTIC_CLIENT_CONFIG_GAPS=0
KNOWLEDGE_FLOW_CLIENT_CONFIG_GAPS=0
CONTROL_PLANE_CLIENT_CONFIG_GAPS=0
EVAL_WORKER_CLIENT_CONFIG_GAPS=0
APP_CLIENT_ROLE_GAPS=0
APP_GROUPS_SCOPE_GAPS=0

declare -A CLIENT_UUIDS=()
if [[ -n "${ADM}" ]]; then
  step "Service account permissions (Keycloak)"
  for client_id in app agentic knowledge-flow control-plane fred-evaluation-worker realm-management account; do
    if ! client_uuid="$(keycloak_client_uuid "$client_id" 2>/dev/null)"; then
      client_uuid=""
    fi
    if [[ -z "$client_uuid" ]]; then
      mark_critical "Cannot resolve Keycloak client UUID for '${client_id}'"
      continue
    fi
    CLIENT_UUIDS["$client_id"]="$client_uuid"
    info "Client '${client_id}' UUID: ${client_uuid}"
  done

  KC_KF_EXPECT_MANAGE_USERS="${KC_KF_EXPECT_MANAGE_USERS:-${KEYCLOAK_KF_ENABLE_MANAGE_USERS:-true}}"
  if is_truthy "$KC_KF_EXPECT_MANAGE_USERS"; then
    EXPECTED_KF_RM_ROLES="$EXPECTED_KF_RM_ROLES_WITH_MANAGE"
    info "knowledge-flow expected realm-management.manage-users: enabled"
  else
    EXPECTED_KF_RM_ROLES="$EXPECTED_KF_RM_ROLES_BASE"
    info "knowledge-flow expected realm-management.manage-users: disabled"
  fi
  info "control-plane expected realm-management.manage-users: enabled"

  step "App client role definitions and token-claim prerequisites (Keycloak)"
  APP_CLIENT_UUID="${CLIENT_UUIDS[app]:-}"
  if [[ -z "$APP_CLIENT_UUID" ]]; then
    ((APP_CLIENT_ROLE_GAPS+=1))
    mark_critical "Skipping app role checks: missing client UUID for 'app'"
  else
    legacy_app_roles_lines="$(printf '%s\n' "${LEGACY_APP_CLIENT_ROLES[@]}" | sort -u)"
    info "Token claim prerequisite: resource_access.app.roles comes from effective app client roles"
    info "No groups claim is required or consumed by any Swift authorization path (AUTHZ-05/06 - OpenFGA is the sole authorization source)"

    if app_client_roles="$(curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/clients/${APP_CLIENT_UUID}/roles?first=0&max=200" 2>/dev/null | jq -r '.[].name' | sort -u)"; then
      info "App client roles: $(sorted_lines_to_csv "$app_client_roles")"
      present_legacy_app_roles="$(common_lines "$legacy_app_roles_lines" "$app_client_roles")"
      if [[ -n "$present_legacy_app_roles" ]]; then
        ((APP_CLIENT_ROLE_GAPS+=1))
        mark_critical "Legacy app client role(s) present on an identity-only realm (AUTHZ-07 - must not exist): $(sorted_lines_to_csv "$present_legacy_app_roles")"
      fi
      if ! contains_line "$EXPECTED_SERVICE_APP_ROLE" "$app_client_roles"; then
        ((APP_CLIENT_ROLE_GAPS+=1))
        mark_critical "Missing app client role '${EXPECTED_SERVICE_APP_ROLE}' required for service accounts"
      fi
    else
      ((APP_CLIENT_ROLE_GAPS+=1))
      mark_critical "Cannot read roles for app client"
    fi

    groups_scope_uuid="$(keycloak_client_scope_uuid "$EXPECTED_GROUPS_SCOPE_NAME" 2>/dev/null || true)"
    # No groups claim is ever required (AUTHZ-05/06). Its absence is the
    # expected state, not a gap. A leftover scope from a prior hand-provisioned
    # or legacy run is only a residual-state warning, not a failure: nothing
    # in the Swift authorization path reads it.
    if [[ -z "$groups_scope_uuid" ]]; then
      ok "Client scope '${EXPECTED_GROUPS_SCOPE_NAME}' absent, as expected"
    else
      app_default_scopes="$(
        curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/clients/${APP_CLIENT_UUID}/default-client-scopes" 2>/dev/null \
          | jq -r '.[].name' | sort -u || true
      )"
      if contains_line "$EXPECTED_GROUPS_SCOPE_NAME" "$app_default_scopes"; then
        mark_warning "Client scope '${EXPECTED_GROUPS_SCOPE_NAME}' is still attached to the app client's default scopes (residual state from a prior run or hand provisioning) - not read by any Swift authorization path, but 'make docker-wipe && make docker-up' gives a from-scratch proof"
      else
        ok "Client scope '${EXPECTED_GROUPS_SCOPE_NAME}' exists but is not attached to app default scopes, as expected"
      fi
    fi
  fi

  for svc in agentic knowledge-flow control-plane fred-evaluation-worker; do
    svc_uuid="${CLIENT_UUIDS[$svc]:-}"
    if [[ -z "$svc_uuid" ]]; then
      mark_critical "Skipping '${svc}' permission checks: missing client UUID"
      continue
    fi

    printf "\n%sService Client: %s%s\n" "${BOLD}" "$svc" "${RESET}"
    if ! svc_json="$(curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/clients/${svc_uuid}" 2>/dev/null)"; then
      mark_critical "Cannot load client definition for '${svc}'"
      continue
    fi

    svc_enabled="$(jq -r 'if has("enabled") then .enabled else false end' <<<"$svc_json")"
    svc_public="$(jq -r 'if has("publicClient") then .publicClient else true end' <<<"$svc_json")"
    svc_sa_enabled="$(jq -r 'if has("serviceAccountsEnabled") then .serviceAccountsEnabled else false end' <<<"$svc_json")"
    svc_auth_type="$(jq -r '.clientAuthenticatorType // ""' <<<"$svc_json")"
    info "Client config: enabled=${svc_enabled}, publicClient=${svc_public}, serviceAccountsEnabled=${svc_sa_enabled}, authenticator=${svc_auth_type}"

    if [[ "$svc_enabled" != "true" || "$svc_public" != "false" || "$svc_sa_enabled" != "true" || "$svc_auth_type" != "client-secret" ]]; then
      mark_critical "Client '${svc}' should be confidential with service account enabled (enabled=true, publicClient=false, serviceAccountsEnabled=true, authenticator=client-secret)"
      if [[ "$svc" == "agentic" ]]; then
        ((AGENTIC_CLIENT_CONFIG_GAPS+=1))
      elif [[ "$svc" == "knowledge-flow" ]]; then
        ((KNOWLEDGE_FLOW_CLIENT_CONFIG_GAPS+=1))
      elif [[ "$svc" == "fred-evaluation-worker" ]]; then
        ((EVAL_WORKER_CLIENT_CONFIG_GAPS+=1))
      else
        ((CONTROL_PLANE_CLIENT_CONFIG_GAPS+=1))
      fi
    fi

    if ! sa_json="$(keycloak_service_account_user_json "$svc_uuid" 2>/dev/null)"; then
      mark_critical "Cannot resolve service account user for '${svc}'"
      continue
    fi

    sa_user_id="$(jq -r '.id // empty' <<<"$sa_json")"
    sa_username="$(jq -r '.username // empty' <<<"$sa_json")"
    if [[ -z "$sa_user_id" || -z "$sa_username" ]]; then
      mark_critical "Invalid service account user payload for '${svc}'"
      continue
    fi
    info "Service account user: ${sa_username} (${sa_user_id})"

    rm_roles=""
    acc_roles=""
    app_roles=""

    if [[ -n "${CLIENT_UUIDS[realm-management]:-}" ]]; then
      rm_roles="$(keycloak_user_client_roles "$sa_user_id" "${CLIENT_UUIDS[realm-management]}" 2>/dev/null || true)"
    fi
    if [[ -n "${CLIENT_UUIDS[account]:-}" ]]; then
      acc_roles="$(keycloak_user_client_roles "$sa_user_id" "${CLIENT_UUIDS[account]}" 2>/dev/null || true)"
    fi
    if [[ -n "${CLIENT_UUIDS[app]:-}" ]]; then
      app_roles="$(keycloak_user_client_roles "$sa_user_id" "${CLIENT_UUIDS[app]}" 2>/dev/null || true)"
    fi

    info "realm-management roles: $(sorted_lines_to_csv "$rm_roles")"
    info "account roles: $(sorted_lines_to_csv "$acc_roles")"
    info "app roles: $(sorted_lines_to_csv "$app_roles")"

    if [[ "$svc" == "agentic" ]]; then
      expected_rm_lines="$(words_to_sorted_lines "$EXPECTED_AGENTIC_RM_ROLES")"
      expected_acc_lines="$(words_to_sorted_lines "$EXPECTED_AGENTIC_ACCOUNT_ROLES")"
    elif [[ "$svc" == "knowledge-flow" ]]; then
      expected_rm_lines="$(words_to_sorted_lines "$EXPECTED_KF_RM_ROLES")"
      expected_acc_lines="$(words_to_sorted_lines "$EXPECTED_KF_ACCOUNT_ROLES")"
    elif [[ "$svc" == "fred-evaluation-worker" ]]; then
      # Least privilege (RFC EVAL-AUTH): only app:service_agent, no realm-management, no account roles.
      expected_rm_lines=""
      expected_acc_lines=""
    else
      expected_rm_lines="$(words_to_sorted_lines "$EXPECTED_CP_RM_ROLES")"
      expected_acc_lines="$(words_to_sorted_lines "$EXPECTED_CP_ACCOUNT_ROLES")"
    fi
    expected_app_lines="$(words_to_sorted_lines "$EXPECTED_SERVICE_APP_ROLE")"

    missing_rm_roles="$(missing_lines "$expected_rm_lines" "$rm_roles")"
    missing_acc_roles="$(missing_lines "$expected_acc_lines" "$acc_roles")"
    missing_app_roles="$(missing_lines "$expected_app_lines" "$app_roles")"
    extra_rm_roles="$(extra_lines "$expected_rm_lines" "$rm_roles")"
    extra_acc_roles="$(extra_lines "$expected_acc_lines" "$acc_roles")"
    extra_app_roles="$(extra_lines "$expected_app_lines" "$app_roles")"

    if [[ -n "$missing_rm_roles" ]]; then
      mark_critical "Missing realm-management roles for '${svc}': $(sorted_lines_to_csv "$missing_rm_roles")"
      if [[ "$svc" == "agentic" ]]; then
        ((AGENTIC_ROLE_GAPS+=1))
      elif [[ "$svc" == "knowledge-flow" ]]; then
        ((KNOWLEDGE_FLOW_ROLE_GAPS+=1))
      elif [[ "$svc" == "fred-evaluation-worker" ]]; then
        ((EVAL_WORKER_ROLE_GAPS+=1))
      else
        ((CONTROL_PLANE_ROLE_GAPS+=1))
      fi
    fi
    if [[ -n "$missing_acc_roles" ]]; then
      mark_critical "Missing account roles for '${svc}': $(sorted_lines_to_csv "$missing_acc_roles")"
      if [[ "$svc" == "agentic" ]]; then
        ((AGENTIC_ROLE_GAPS+=1))
      elif [[ "$svc" == "knowledge-flow" ]]; then
        ((KNOWLEDGE_FLOW_ROLE_GAPS+=1))
      elif [[ "$svc" == "fred-evaluation-worker" ]]; then
        ((EVAL_WORKER_ROLE_GAPS+=1))
      else
        ((CONTROL_PLANE_ROLE_GAPS+=1))
      fi
    fi
    if [[ -n "$missing_app_roles" ]]; then
      mark_critical "Missing app roles for '${svc}': $(sorted_lines_to_csv "$missing_app_roles")"
      if [[ "$svc" == "agentic" ]]; then
        ((AGENTIC_ROLE_GAPS+=1))
      elif [[ "$svc" == "knowledge-flow" ]]; then
        ((KNOWLEDGE_FLOW_ROLE_GAPS+=1))
      elif [[ "$svc" == "fred-evaluation-worker" ]]; then
        ((EVAL_WORKER_ROLE_GAPS+=1))
      else
        ((CONTROL_PLANE_ROLE_GAPS+=1))
      fi
    fi

    if [[ -n "$extra_rm_roles" ]]; then
      mark_warning "Additional realm-management roles for '${svc}': $(sorted_lines_to_csv "$extra_rm_roles")"
    fi
    if [[ -n "$extra_acc_roles" ]]; then
      mark_warning "Additional account roles for '${svc}': $(sorted_lines_to_csv "$extra_acc_roles")"
    fi
    if [[ -n "$extra_app_roles" ]]; then
      mark_warning "Additional app roles for '${svc}': $(sorted_lines_to_csv "$extra_app_roles")"
    fi
  done
fi

STORE_ID=""
ALL_TUPLES=""
OPENFGA_STATUS="unknown"
step "Resolve OpenFGA store"
if stores_payload="$(curl -fsS -H "Authorization: Bearer ${OPENFGA_TOKEN}" "${FGA}/stores" 2>/dev/null)"; then
  STORE_ID="$(jq -r --arg name "${OPENFGA_STORE_NAME}" '.stores[]? | select(.name==$name) | .id' <<<"$stores_payload")"
  if [[ -n "${STORE_ID}" ]]; then
    OPENFGA_STATUS="present"
    ok "OpenFGA store id = ${STORE_ID}"
    info "OpenFGA access model in this setup: API token grants access to stores/models/tuples"
    if ! ALL_TUPLES="$(json_post "${FGA}/stores/${STORE_ID}/read" "${OPENFGA_TOKEN}" '{"page_size":100}' 2>/dev/null)"; then
      ALL_TUPLES=""
      mark_critical "Unable to read tuples from OpenFGA store '${OPENFGA_STORE_NAME}'"
    fi
  else
    OPENFGA_STATUS="store-missing"
    mark_critical "OpenFGA store '${OPENFGA_STORE_NAME}' not found"
  fi
else
  OPENFGA_STATUS="unreachable"
  mark_critical "Cannot reach OpenFGA API at ${FGA}"
fi

MODEL_SHAPE_GAPS=0
if [[ -n "${STORE_ID}" ]]; then
  step "Validate authorization-model shape"
  info "Checking the LIVE model actually pushed to OpenFGA, not just a source file"
  if latest_models_payload="$(curl -fsS -H "Authorization: Bearer ${OPENFGA_TOKEN}" "${FGA}/stores/${STORE_ID}/authorization-models?page_size=1" 2>/dev/null)"; then
    current_model="$(jq -c '.authorization_models[0] // empty' <<<"$latest_models_payload")"
    if [[ -z "$current_model" ]]; then
      ((MODEL_SHAPE_GAPS+=1))
      mark_critical "OpenFGA store '${OPENFGA_STORE_NAME}' has no authorization model at all"
    else
      org_relations="$(jq -r '.type_definitions[]? | select(.type=="organization") | .relations // {} | keys[]?' <<<"$current_model" | sort -u)"
      team_relations="$(jq -r '.type_definitions[]? | select(.type=="team") | .relations // {} | keys[]?' <<<"$current_model" | sort -u)"

      if contains_line "platform_admin" "$org_relations" && contains_line "platform_observer" "$org_relations"; then
        ok "organization type defines platform_admin and platform_observer"
      else
        ((MODEL_SHAPE_GAPS+=1))
        mark_critical "organization type is missing platform_admin/platform_observer"
      fi

      missing_swift_relations=""
      for rel in team_member team_editor team_admin team_analyst; do
        if ! contains_line "$rel" "$team_relations"; then
          missing_swift_relations+="${rel}"$'\n'
        fi
      done
      if [[ -z "$missing_swift_relations" ]]; then
        ok "team type defines Swift target relations team_member/team_editor/team_admin/team_analyst"
      else
        ((MODEL_SHAPE_GAPS+=1))
        mark_critical "team type is missing Swift target relations: $(sorted_lines_to_csv "$missing_swift_relations")"
      fi
    fi
  else
    ((MODEL_SHAPE_GAPS+=1))
    mark_critical "Cannot read authorization models from OpenFGA store '${OPENFGA_STORE_NAME}'"
  fi
fi

TOTAL_TUPLES=-1
if [[ -n "${ALL_TUPLES}" ]]; then
  step "Inspect OpenFGA tuples"
  TOTAL_TUPLES="$(jq '.tuples | length' <<<"$ALL_TUPLES")"
  ok "Current tuples in store: ${TOTAL_TUPLES}"
fi

TEMPORAL_UI_HTTP_CODE="000"
step "Check Temporal UI endpoint"
TEMPORAL_UI_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "${TEMPORAL_UI_URL}" || true)"
if [[ "${TEMPORAL_UI_HTTP_CODE}" =~ ^2[0-9][0-9]$ || "${TEMPORAL_UI_HTTP_CODE}" =~ ^3[0-9][0-9]$ ]]; then
  ok "Temporal UI reachable (${TEMPORAL_UI_URL}, HTTP ${TEMPORAL_UI_HTTP_CODE})"
else
  mark_critical "Temporal UI unreachable (${TEMPORAL_UI_URL}, HTTP ${TEMPORAL_UI_HTTP_CODE})"
fi

LANGFUSE_UI_HTTP_CODE="000"
LANGFUSE_WORKER_HTTP_CODE="000"
LANGFUSE_S3_HTTP_CODE="000"
LANGFUSE_S3_CONFIG_GAPS=0
LANGFUSE_S3_BUCKET_GAPS=0

step "Check Langfuse endpoints and S3 prerequisites"
if ! langfuse_expected; then
  info "Skipped: Langfuse is not deployed in the 'base' stack profile (STACK=${STACK})"
else
LANGFUSE_UI_HTTP_CODE="$(
  probe_http_status_with_retries \
    "${LANGFUSE_UI_URL}" \
    "${LANGFUSE_UI_HTTP_RETRIES}" \
    "${PREFLIGHT_HTTP_RETRY_DELAY_SEC}"
)"
if [[ "${LANGFUSE_UI_HTTP_CODE}" == "000" ]]; then
  mark_critical "Langfuse UI unreachable (${LANGFUSE_UI_URL}, HTTP ${LANGFUSE_UI_HTTP_CODE})"
elif [[ "${LANGFUSE_UI_HTTP_CODE}" =~ ^5[0-9][0-9]$ ]]; then
  mark_warning "Langfuse UI reachable but returned server error (${LANGFUSE_UI_URL}, HTTP ${LANGFUSE_UI_HTTP_CODE})"
else
  ok "Langfuse UI reachable (${LANGFUSE_UI_URL}, HTTP ${LANGFUSE_UI_HTTP_CODE})"
fi

LANGFUSE_WORKER_HTTP_CODE="$(
  probe_http_status_with_retries \
    "${LANGFUSE_WORKER_URL}" \
    "${LANGFUSE_WORKER_HTTP_RETRIES}" \
    "${PREFLIGHT_HTTP_RETRY_DELAY_SEC}"
)"
if [[ "${LANGFUSE_WORKER_HTTP_CODE}" == "000" ]]; then
  mark_warning "Langfuse worker endpoint unreachable (${LANGFUSE_WORKER_URL}, HTTP ${LANGFUSE_WORKER_HTTP_CODE})"
elif [[ "${LANGFUSE_WORKER_HTTP_CODE}" =~ ^5[0-9][0-9]$ ]]; then
  mark_warning "Langfuse worker endpoint reachable but returned server error (${LANGFUSE_WORKER_URL}, HTTP ${LANGFUSE_WORKER_HTTP_CODE})"
else
  ok "Langfuse worker endpoint reachable (${LANGFUSE_WORKER_URL}, HTTP ${LANGFUSE_WORKER_HTTP_CODE})"
fi

LANGFUSE_S3_HTTP_CODE="$(
  probe_http_status_with_retries \
    "${LANGFUSE_S3_URL}" \
    "${LANGFUSE_S3_HTTP_RETRIES}" \
    "${PREFLIGHT_HTTP_RETRY_DELAY_SEC}"
)"
if [[ "${LANGFUSE_S3_HTTP_CODE}" == "000" ]]; then
  mark_warning "Langfuse S3 endpoint unreachable from host (${LANGFUSE_S3_URL}, HTTP ${LANGFUSE_S3_HTTP_CODE})"
elif [[ "${LANGFUSE_S3_HTTP_CODE}" =~ ^5[0-9][0-9]$ ]]; then
  mark_warning "Langfuse S3 endpoint reachable but returned server error (${LANGFUSE_S3_URL}, HTTP ${LANGFUSE_S3_HTTP_CODE})"
else
  ok "Langfuse S3 endpoint reachable from host (${LANGFUSE_S3_URL}, HTTP ${LANGFUSE_S3_HTTP_CODE})"
fi

for bucket_name in "${LANGFUSE_EVENT_BUCKET}" "${LANGFUSE_MEDIA_BUCKET}" "${LANGFUSE_EXPORT_BUCKET}"; do
  if [[ -z "${bucket_name}" ]]; then
    ((LANGFUSE_S3_CONFIG_GAPS+=1))
    mark_critical "Langfuse S3 bucket configuration contains an empty bucket name"
  fi
done

if [[ "${LANGFUSE_EVENT_BUCKET}" == "${LANGFUSE_MEDIA_BUCKET}" && "${LANGFUSE_EVENT_BUCKET}" == "${LANGFUSE_EXPORT_BUCKET}" ]]; then
  ok "Langfuse S3 bucket configuration consistent (single bucket: ${LANGFUSE_EVENT_BUCKET})"
else
  info "Langfuse S3 bucket configuration uses multiple buckets (event=${LANGFUSE_EVENT_BUCKET}, media=${LANGFUSE_MEDIA_BUCKET}, export=${LANGFUSE_EXPORT_BUCKET})"
fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "app-seaweedfs"; then
    candidate_bucket_payload="$(
      docker exec app-seaweedfs sh -lc \
        'bucket_output="$(echo "s3.bucket.list" | weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888 2>&1)"; rc="$?"; printf "__RC__=%s\n" "$rc"; printf "%s" "$bucket_output"' \
        || true
    )"
    seaweedfs_bucket_listing_rc="$(sed -n '1s/^__RC__=//p' <<<"${candidate_bucket_payload}")"
    seaweedfs_bucket_listing="$(sed '1d' <<<"${candidate_bucket_payload}")"
    if [[ "${seaweedfs_bucket_listing_rc}" != "0" ]]; then
      mark_warning "Could not list buckets from app-seaweedfs; skipping Langfuse bucket existence checks"
    else
      mapfile -t langfuse_unique_buckets < <(
        printf '%s\n' "${LANGFUSE_EVENT_BUCKET}" "${LANGFUSE_MEDIA_BUCKET}" "${LANGFUSE_EXPORT_BUCKET}" \
          | sed '/^$/d' | sort -u
      )
      for bucket_name in "${langfuse_unique_buckets[@]}"; do
        if grep -Fq "${bucket_name}" <<<"${seaweedfs_bucket_listing}"; then
          ok "S3 bucket present for Langfuse: ${bucket_name}"
        else
          ((LANGFUSE_S3_BUCKET_GAPS+=1))
          mark_critical "Missing S3 bucket for Langfuse: ${bucket_name}"
        fi
      done
    fi
  else
    mark_warning "Container 'app-seaweedfs' not found; skipping Langfuse bucket existence checks"
  fi
else
  mark_warning "docker CLI unavailable; skipping Langfuse bucket existence checks"
fi
fi

printf "\n%s\n" "${BOLD}============================================================${RESET}"
printf "%s\n" "${BOLD}Preflight Summary (READ-ONLY)${RESET}"
printf "%s\n" "${BOLD}============================================================${RESET}"
info "Keycloak clients: ${FOUND_CLIENTS}/${#REQUIRED_CLIENTS[@]} present"
info "Residual Keycloak groups (expected 0): ${RESIDUAL_GROUPS}"
info "Keycloak realm name gaps (expected 'app'): ${REALM_NAME_GAPS}"
info "Keycloak realm existence gaps: ${REALM_EXISTENCE_GAPS}"
info "App client role definition gaps (service_agent required; admin/editor/viewer forbidden as legacy): ${APP_CLIENT_ROLE_GAPS}"
info "groups-scope / groups mapper gaps: ${APP_GROUPS_SCOPE_GAPS}"
info "Service-client config gaps (agentic): ${AGENTIC_CLIENT_CONFIG_GAPS}"
info "Service-client config gaps (knowledge-flow): ${KNOWLEDGE_FLOW_CLIENT_CONFIG_GAPS}"
info "Service-client config gaps (control-plane): ${CONTROL_PLANE_CLIENT_CONFIG_GAPS}"
info "Service-client config gaps (fred-evaluation-worker): ${EVAL_WORKER_CLIENT_CONFIG_GAPS}"
info "Service-account role gaps (agentic: realm-management + account + app:service_agent): ${AGENTIC_ROLE_GAPS}"
info "Service-account role gaps (knowledge-flow: realm-management + account + app:service_agent): ${KNOWLEDGE_FLOW_ROLE_GAPS}"
info "Service-account role gaps (control-plane: realm-management + account + app:service_agent): ${CONTROL_PLANE_ROLE_GAPS}"
info "Service-account role gaps (fred-evaluation-worker: least-privilege, only app:service_agent): ${EVAL_WORKER_ROLE_GAPS}"
if [[ "${OPENFGA_STATUS}" == "present" ]]; then
  info "OpenFGA store '${OPENFGA_STORE_NAME}': present (${STORE_ID})"
elif [[ "${OPENFGA_STATUS}" == "store-missing" ]]; then
  info "OpenFGA store '${OPENFGA_STORE_NAME}': missing"
else
  info "OpenFGA store '${OPENFGA_STORE_NAME}': not reachable (${FGA})"
fi
info "Authorization-model shape gaps: ${MODEL_SHAPE_GAPS}"
info "Temporal UI endpoint: ${TEMPORAL_UI_URL} (HTTP ${TEMPORAL_UI_HTTP_CODE})"
if langfuse_expected; then
  info "Langfuse UI endpoint: ${LANGFUSE_UI_URL} (HTTP ${LANGFUSE_UI_HTTP_CODE})"
  info "Langfuse worker endpoint: ${LANGFUSE_WORKER_URL} (HTTP ${LANGFUSE_WORKER_HTTP_CODE})"
  info "Langfuse S3 endpoint (external check): ${LANGFUSE_S3_URL} (HTTP ${LANGFUSE_S3_HTTP_CODE})"
  info "Langfuse S3 config gaps (empty bucket names): ${LANGFUSE_S3_CONFIG_GAPS}"
  info "Langfuse S3 bucket gaps: ${LANGFUSE_S3_BUCKET_GAPS}"
else
  info "Langfuse: skipped (base stack profile)"
fi
if [[ "${TOTAL_TUPLES}" -ge 0 ]]; then
  info "OpenFGA tuples total: ${TOTAL_TUPLES}"
fi

printf "\n%s\n" "${BOLD}Readiness:${RESET}"
if [[ "${CRITICAL_ISSUES}" -eq 0 && "${WARNING_ISSUES}" -eq 0 ]]; then
  ok "GREEN: ready to start FRED (no critical/warning issues detected)."
elif [[ "${CRITICAL_ISSUES}" -eq 0 ]]; then
  warn "YELLOW: startup possible but warnings should be reviewed."
else
  fail "RED: not ready. Fix critical issues before starting FRED."
fi
info "Critical issues: ${CRITICAL_ISSUES}"
info "Warning issues: ${WARNING_ISSUES}"
info "This script performed NO write operation."

if [[ "${CRITICAL_ISSUES}" -gt 0 ]]; then
  exit 1
fi

exit 0
