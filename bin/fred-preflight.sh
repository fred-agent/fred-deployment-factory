#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# FRED preflight diagnostics (READ-ONLY)
# -----------------------------------------------------------------------------
# This script ONLY inspects configuration/state and never writes anything.
# It checks:
# 1) Keycloak realm/clients/users/groups
# 2) App roles (legacy Keycloak admin/editor/viewer), groups scope mapper,
#    service-account rights
# 3) OpenFGA store presence + authorization-model shape (AUTHZ-05 target
#    relations present, no platform-to-team escalation) + team memberships
#    and platform roles (platform_admin/platform_observer) from demo identity
#    config
# 4) Optional Postgres agent IDs + owner coverage for Alice (read-only)
# 5) Langfuse endpoints + S3 bucket diagnostics
#
# On users with NO app_roles and/or NO platform_roles: this is a real, valid,
# common state (AUTHZ-05) - not every demo user is expected to hold a legacy
# Keycloak role. See "Why these exact users" near the top of
# validation/README.md for the reasoning; this script validates users AGAINST
# whatever configuration.yaml actually declares for them, it does not assume
# every user needs an app role.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Configuration (override with env vars if needed)
KC="${KC:-http://localhost:8080}"
FGA="${FGA:-http://localhost:9080}"
REALM="${REALM:-app}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-fred}"
DEMO_IDENTITY_CONFIG_FILE="${DEMO_IDENTITY_CONFIG_FILE:-${REPO_ROOT}/config/configuration.yaml}"

KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-Azerty123_}"
OPENFGA_TOKEN="${OPENFGA_TOKEN:-Azerty123_}"

PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-fred}"
PGDATABASE="${PGDATABASE:-fred}"
PGPASSWORD="${PGPASSWORD:-Azerty123_}"
export PGPASSWORD

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

# When true, also expect user:<username> team tuples in OpenFGA.
OPENFGA_EXPECT_USERNAME_SUBJECTS="${OPENFGA_EXPECT_USERNAME_SUBJECTS:-${OPENFGA_SEED_INCLUDE_USERNAME_USERS:-true}}"
PREFLIGHT_CHECK_AGENT_OWNERSHIP="${PREFLIGHT_CHECK_AGENT_OWNERSHIP:-false}"

# Stack profile (extended|base). In the "base" profile Langfuse (and its Redis/
# ClickHouse dependencies) is not deployed, so its endpoint/S3 prerequisite checks
# are skipped instead of being reported as critical failures.
STACK="${STACK:-base}"

REQUIRED_CLIENTS=(app agentic knowledge-flow control-plane fred-evaluation-worker)
REQUIRED_APP_CLIENT_ROLES=(admin editor viewer)
EXPECTED_SERVICE_APP_ROLE="service_agent"
EXPECTED_GROUPS_SCOPE_NAME="groups-scope"
EXPECTED_GROUPS_MAPPER_NAME="groups"

REQUIRED_USERS=()
REQUIRED_GROUPS=()

declare -A EXPECTED_TEAMS=()
declare -A EXPECTED_MANAGER_TEAMS=()
declare -A EXPECTED_OWNER_TEAMS=()
declare -A EXPECTED_APP_ROLES=()
declare -A EXPECTED_PLATFORM_ROLES=()
declare -A KEYCLOAK_GROUP_NAME_BY_ID=()

# AUTHZ-05 target platform relations (fred FRED-AUTHORIZATION-TARGET-MODEL-RFC),
# stored-only OpenFGA relations on the singleton organization:fred - never
# derived from a Keycloak role. "admin" in configuration.yaml's platform_roles
# maps to the OpenFGA relation "platform_admin", "observer" to "platform_observer".
declare -A PLATFORM_ROLE_TO_FGA_RELATION=( [admin]="platform_admin" [observer]="platform_observer" )

EXPECTED_AGENTIC_RM_ROLES="query-groups query-users view-users"
EXPECTED_AGENTIC_ACCOUNT_ROLES="view-groups"

EXPECTED_KF_RM_ROLES_BASE="query-groups query-users view-users"
EXPECTED_KF_RM_ROLES_WITH_MANAGE="query-groups query-users view-users manage-users"
EXPECTED_KF_ACCOUNT_ROLES="view-groups"
EXPECTED_CP_RM_ROLES="query-groups query-users view-users manage-users"
EXPECTED_CP_ACCOUNT_ROLES="view-groups"

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

uri_encode() {
  local raw="$1"
  jq -rn --arg v "$raw" '$v|@uri'
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

prefix_lines() {
  local prefix="$1"
  local text="$2"
  if [[ -z "$text" ]]; then
    return 0
  fi
  sed "s/^/${prefix}/" <<<"$text"
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

to_keycloak_group_lines() {
  local team_lines="$1"
  if [[ -z "$team_lines" ]]; then
    return 0
  fi
  sed 's#^#/#' <<<"$team_lines" | sort -u
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

intersect_lines() {
  local left="$1"
  local right="$2"
  comm -12 <(printf '%s\n' "$left" | sed '/^$/d' | sort -u) <(printf '%s\n' "$right" | sed '/^$/d' | sort -u) || true
}

contains_line() {
  local needle="$1"
  local haystack="$2"
  grep -Fxq "$needle" <<<"$haystack"
}

resolve_team_name_from_openfga_object_suffix() {
  local team_suffix="$1"
  local encoded_path
  local response
  local name

  if [[ -z "$team_suffix" ]]; then
    printf '%s' ""
    return 0
  fi

  if [[ -n "${KEYCLOAK_GROUP_NAME_BY_ID[$team_suffix]:-}" ]]; then
    printf '%s' "${KEYCLOAK_GROUP_NAME_BY_ID[$team_suffix]}"
    return 0
  fi

  # Legacy seed style: team object already uses the team name.
  if jq -e --arg team "$team_suffix" '.teams | index($team) != null' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null 2>&1; then
    KEYCLOAK_GROUP_NAME_BY_ID["$team_suffix"]="$team_suffix"
    printf '%s' "$team_suffix"
    return 0
  fi

  # New seed style: team object uses Keycloak group UUID.
  response="$(
    curl -fsS -H "Authorization: Bearer ${ADM}" \
      "$KC/admin/realms/${REALM}/groups/${team_suffix}" \
      || true
  )"
  name="$(jq -r '.name // empty' <<<"$response" 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    KEYCLOAK_GROUP_NAME_BY_ID["$team_suffix"]="$name"
    printf '%s' "$name"
    return 0
  fi

  # Fallback for path-like values.
  encoded_path="$(uri_encode "/${team_suffix}")"
  response="$(
    curl -fsS -H "Authorization: Bearer ${ADM}" \
      "$KC/admin/realms/${REALM}/group-by-path/${encoded_path}" \
      || true
  )"
  name="$(jq -r '.name // empty' <<<"$response" 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    KEYCLOAK_GROUP_NAME_BY_ID["$team_suffix"]="$name"
    printf '%s' "$name"
    return 0
  fi

  KEYCLOAK_GROUP_NAME_BY_ID["$team_suffix"]="$team_suffix"
  printf '%s' "$team_suffix"
}

fga_team_relation_lines() {
  local subject="$1"
  local relation="$2"
  local raw_team_suffixes
  local team_suffix
  local resolved_team_name

  raw_team_suffixes="$(
    jq -r --arg subj "$subject" --arg rel "$relation" \
      '.tuples[].key | select(.user==$subj and .relation==$rel and (.object|startswith("team:"))) | .object | sub("^team:";"")' <<<"$ALL_TUPLES"
  )"

  while IFS= read -r team_suffix; do
    [[ -n "$team_suffix" ]] || continue
    resolved_team_name="$(resolve_team_name_from_openfga_object_suffix "$team_suffix")"
    [[ -n "$resolved_team_name" ]] && printf '%s\n' "$resolved_team_name"
  done <<<"$raw_team_suffixes" | sort -u
}

# AUTHZ-05: does `subject` hold `relation` directly on the singleton
# organization:fred? Used for platform_admin/platform_observer, which unlike
# team relations have no per-object identity to resolve - just presence/absence.
fga_has_org_relation() {
  local subject="$1"
  local relation="$2"
  jq -e --arg subj "$subject" --arg rel "$relation" \
    '.tuples[]?.key | select(.user==$subj and .relation==$rel and .object=="organization:fred")' \
    <<<"$ALL_TUPLES" >/dev/null 2>&1
}

load_demo_identity_expectations() {
  local duplicate_teams
  local duplicate_users
  local invalid_refs

  [[ -f "$DEMO_IDENTITY_CONFIG_FILE" ]] || die "Demo identity config file not found: ${DEMO_IDENTITY_CONFIG_FILE}"

  jq -e '
    (.teams | type == "array") and
    (.users | type == "array") and
    all(.teams[]?; type == "string" and length > 0) and
    all(.users[]?;
      (.username | type == "string" and length > 0) and
      ((.teams // []) | type == "array") and
      all((.teams // [])[]?; type == "string" and length > 0) and
      ((.team_roles // {}) | type == "object") and
      ((.team_roles.member // []) | type == "array") and
      ((.team_roles.manager // []) | type == "array") and
      ((.team_roles.owner // []) | type == "array") and
      all((.team_roles.member // [])[]?; type == "string" and length > 0) and
      all((.team_roles.manager // [])[]?; type == "string" and length > 0) and
      all((.team_roles.owner // [])[]?; type == "string" and length > 0) and
      ((.app_roles // []) | type == "array") and
      all((.app_roles // [])[]?; type == "string" and length > 0) and
      ((.platform_roles // []) | type == "array") and
      all((.platform_roles // [])[]?; type == "string" and (. == "admin" or . == "observer"))
    )
  ' "$DEMO_IDENTITY_CONFIG_FILE" >/dev/null \
    || die "Invalid demo identity config format in ${DEMO_IDENTITY_CONFIG_FILE}"

  duplicate_teams="$(jq -r '[.teams[]?] | group_by(.)[] | select(length > 1) | .[0]' "$DEMO_IDENTITY_CONFIG_FILE")"
  [[ -z "$duplicate_teams" ]] || die "Duplicate teams in demo identity config: $(sorted_lines_to_csv "$duplicate_teams")"

  duplicate_users="$(jq -r '[.users[]?.username] | group_by(.)[] | select(length > 1) | .[0]' "$DEMO_IDENTITY_CONFIG_FILE")"
  [[ -z "$duplicate_users" ]] || die "Duplicate usernames in demo identity config: $(sorted_lines_to_csv "$duplicate_users")"

  invalid_refs="$(
    jq -r '
      (.teams // []) as $teams
      | .users[]?
      | .username as $u
      | (
          (.teams // [])[],
          (.team_roles.member // [])[],
          (.team_roles.manager // [])[],
          (.team_roles.owner // [])[]
        )
      | select(($teams | index(.)) == null)
      | [$u, .] | @tsv
    ' "$DEMO_IDENTITY_CONFIG_FILE"
  )"
  if [[ -n "$invalid_refs" ]]; then
    while IFS=$'\t' read -r u team; do
      [[ -n "$u" && -n "$team" ]] || continue
      die "Demo identity config references unknown team '${team}' for user '${u}'"
    done <<<"$invalid_refs"
  fi

  mapfile -t REQUIRED_USERS < <(jq -r '.users[]?.username // empty' "$DEMO_IDENTITY_CONFIG_FILE")
  mapfile -t REQUIRED_GROUPS < <(jq -r '.teams[]? // empty' "$DEMO_IDENTITY_CONFIG_FILE" | sed 's#^#/#')

  ((${#REQUIRED_USERS[@]} > 0)) || die "Demo identity config must define at least one user"

  EXPECTED_TEAMS=()
  EXPECTED_MANAGER_TEAMS=()
  EXPECTED_OWNER_TEAMS=()
  EXPECTED_APP_ROLES=()
  EXPECTED_PLATFORM_ROLES=()
  while IFS= read -r user_json; do
    [[ -n "$user_json" ]] || continue
    local username team_words manager_words owner_words role_words platform_role_words
    username="$(jq -r '.username' <<<"$user_json")"
    team_words="$(
      jq -r '
        [
          (.teams // [])[],
          (.team_roles.member // [])[],
          (.team_roles.manager // [])[],
          (.team_roles.owner // [])[]
        ] | unique | join(" ")
      ' <<<"$user_json"
    )"
    manager_words="$(
      jq -r '
        [
          (.team_roles.manager // [])[],
          (.team_roles.owner // [])[]
        ] | unique | join(" ")
      ' <<<"$user_json"
    )"
    owner_words="$(jq -r '(.team_roles.owner // []) | unique | join(" ")' <<<"$user_json")"
    role_words="$(jq -r '(.app_roles // []) | join(" ")' <<<"$user_json")"
    platform_role_words="$(jq -r '(.platform_roles // []) | join(" ")' <<<"$user_json")"
    EXPECTED_TEAMS["$username"]="$team_words"
    EXPECTED_MANAGER_TEAMS["$username"]="$manager_words"
    EXPECTED_OWNER_TEAMS["$username"]="$owner_words"
    EXPECTED_APP_ROLES["$username"]="$role_words"
    EXPECTED_PLATFORM_ROLES["$username"]="$platform_role_words"
  done < <(jq -c '.users[]?' "$DEMO_IDENTITY_CONFIG_FILE")
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

keycloak_user_client_roles_composite() {
  local user_id="$1"
  local client_uuid="$2"
  curl -fsS -H "Authorization: Bearer ${ADM}" \
    "$KC/admin/realms/${REALM}/users/${user_id}/role-mappings/clients/${client_uuid}/composite" \
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
require_cmd psql
ok "curl/jq/psql available"
load_demo_identity_expectations
ok "demo identity config loaded"

printf "\n%s\n" "${BOLD}Context:${RESET}"
info "Keycloak: ${KC} (realm=${REALM})"
info "OpenFGA: ${FGA} (store=${OPENFGA_STORE_NAME})"
info "Demo identity config: ${DEMO_IDENTITY_CONFIG_FILE}"
info "Postgres: host=${PGHOST} db=${PGDATABASE} user=${PGUSER}"
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

declare -A USER_IDS=()
FOUND_USERS=0
if [[ -n "${ADM}" ]]; then
  step "Validate required Keycloak users"
  for u in "${REQUIRED_USERS[@]}"; do
    user_payload="$(
      curl -fsS -H "Authorization: Bearer ${ADM}" \
        "$KC/admin/realms/${REALM}/users?username=${u}&exact=true"
    )"
    cnt="$(jq 'length' <<<"$user_payload")"
    if [[ "$cnt" -ge 1 ]]; then
      uid="$(jq -r '.[0].id // empty' <<<"$user_payload")"
      USER_IDS["$u"]="$uid"
      ok "User '${u}' present"
      ((FOUND_USERS+=1))
    else
      mark_critical "User '${u}' missing"
    fi
  done
fi

FOUND_GROUPS=0
if [[ -n "${ADM}" ]]; then
  step "Validate required Keycloak groups"
  for g in "${REQUIRED_GROUPS[@]}"; do
    enc="$(uri_encode "$g")"
    if curl -fsS -H "Authorization: Bearer ${ADM}" \
      "$KC/admin/realms/${REALM}/group-by-path/${enc}" >/dev/null; then
      ok "Group '${g}' present"
      ((FOUND_GROUPS+=1))
    else
      mark_critical "Group '${g}' missing"
    fi
  done
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
APP_USER_PERMISSION_GAPS=0
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

  step "User client roles and token-claim prerequisites (Keycloak)"
  APP_CLIENT_UUID="${CLIENT_UUIDS[app]:-}"
  if [[ -z "$APP_CLIENT_UUID" ]]; then
    ((APP_CLIENT_ROLE_GAPS+=1))
    mark_critical "Skipping app role checks: missing client UUID for 'app'"
  else
    expected_app_roles_lines="$(printf '%s\n' "${REQUIRED_APP_CLIENT_ROLES[@]}" | sort -u)"
    required_user_permissions_lines="$expected_app_roles_lines"
    info "Token claim prerequisite: resource_access.app.roles comes from effective app client roles"
    info "Token claim prerequisite: groups comes from '${EXPECTED_GROUPS_SCOPE_NAME}' mapper on app default scopes"

    if app_client_roles="$(curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/clients/${APP_CLIENT_UUID}/roles?first=0&max=200" 2>/dev/null | jq -r '.[].name' | sort -u)"; then
      info "App client roles: $(sorted_lines_to_csv "$app_client_roles")"
      missing_app_client_roles="$(missing_lines "$expected_app_roles_lines" "$app_client_roles")"
      if [[ -n "$missing_app_client_roles" ]]; then
        ((APP_CLIENT_ROLE_GAPS+=1))
        mark_critical "Missing app client roles: $(sorted_lines_to_csv "$missing_app_client_roles")"
      fi
      if ! contains_line "$EXPECTED_SERVICE_APP_ROLE" "$app_client_roles"; then
        ((APP_CLIENT_ROLE_GAPS+=1))
        mark_critical "Missing app client role '${EXPECTED_SERVICE_APP_ROLE}' required for service accounts"
      fi
    else
      ((APP_CLIENT_ROLE_GAPS+=1))
      mark_critical "Cannot read roles for app client"
    fi

    # AUTHZ-05: a user with app_roles=[] in configuration.yaml is a deliberate,
    # valid state (e.g. a freshly onboarded user with nothing granted yet, or a
    # user whose authorization comes entirely from platform_roles/team_roles
    # instead - see "Why these exact users" in validation/README.md). This loop
    # therefore validates each user against what configuration.yaml actually
    # declares for them, not against a blanket "must hold admin/editor/viewer"
    # assumption. The claim-mechanism sanity check (does resource_access.app.roles
    # work at all) is done once, in aggregate, right after this loop.
    ANY_USER_HAS_REQUIRED_APP_ROLE=0
    for u in "${REQUIRED_USERS[@]}"; do
      uid="${USER_IDS[$u]:-}"
      if [[ -z "$uid" ]]; then
        ((APP_USER_PERMISSION_GAPS+=1))
        mark_critical "Cannot validate app permissions for '${u}' (missing user id)"
        continue
      fi

      user_app_roles_direct="$(keycloak_user_client_roles "$uid" "$APP_CLIENT_UUID" 2>/dev/null || true)"
      user_app_roles_effective="$(keycloak_user_client_roles_composite "$uid" "$APP_CLIENT_UUID" 2>/dev/null || true)"
      expected_user_roles_lines="$(words_to_sorted_lines "${EXPECTED_APP_ROLES[$u]:-}")"

      info "User '${u}' app roles (direct): $(sorted_lines_to_csv "$user_app_roles_direct")"
      info "User '${u}' app roles (effective): $(sorted_lines_to_csv "$user_app_roles_effective")"

      if [[ -z "$expected_user_roles_lines" ]]; then
        info "User '${u}' has no app_roles by design (AUTHZ-05) - authorization, if any, comes from platform_roles/team_roles instead"
        extra_user_direct_roles="$(extra_lines "" "$user_app_roles_direct")"
        if [[ -n "$extra_user_direct_roles" ]]; then
          ((APP_USER_PERMISSION_GAPS+=1))
          mark_critical "User '${u}' expected to have NO app roles (demo identity config) but Keycloak grants: $(sorted_lines_to_csv "$extra_user_direct_roles")"
        fi
      else
        missing_user_direct_roles="$(missing_lines "$expected_user_roles_lines" "$user_app_roles_direct")"
        extra_user_direct_roles="$(extra_lines "$expected_user_roles_lines" "$user_app_roles_direct")"
        missing_user_effective_roles="$(missing_lines "$expected_user_roles_lines" "$user_app_roles_effective")"

        if [[ -n "$missing_user_direct_roles" ]]; then
          ((APP_USER_PERMISSION_GAPS+=1))
          mark_critical "User '${u}' missing direct app roles from demo identity config: $(sorted_lines_to_csv "$missing_user_direct_roles")"
        fi
        if [[ -n "$missing_user_effective_roles" ]]; then
          ((APP_USER_PERMISSION_GAPS+=1))
          mark_critical "User '${u}' missing effective app roles from demo identity config: $(sorted_lines_to_csv "$missing_user_effective_roles")"
        fi
        if [[ -n "$extra_user_direct_roles" ]]; then
          mark_warning "User '${u}' has additional direct app roles not in demo identity config: $(sorted_lines_to_csv "$extra_user_direct_roles")"
        fi
      fi

      if [[ -n "$(intersect_lines "$required_user_permissions_lines" "$user_app_roles_effective")" ]]; then
        ANY_USER_HAS_REQUIRED_APP_ROLE=1
      fi
    done

    # Claim-mechanism sanity check, once in aggregate (not per user): at least
    # one demo user must actually carry an effective admin/editor/viewer role,
    # proving resource_access.app.roles is wired end-to-end. A stack where
    # nobody has a legacy app role at all is a real config problem even under
    # AUTHZ-05 (some legacy-role-gated capabilities still exist - see fred's
    # RFC §25a); a stack where SOME users legitimately have none is not.
    if [[ "$ANY_USER_HAS_REQUIRED_APP_ROLE" -eq 0 ]]; then
      ((APP_USER_PERMISSION_GAPS+=1))
      mark_critical "No demo user has an effective app role in {admin, editor, viewer}; token claim resource_access.app.roles would never be populated for anyone"
    else
      ok "At least one demo user has an effective app role in {admin, editor, viewer} - resource_access.app.roles claim mechanism confirmed working"
    fi

    groups_scope_uuid="$(keycloak_client_scope_uuid "$EXPECTED_GROUPS_SCOPE_NAME" 2>/dev/null || true)"
    if [[ -z "$groups_scope_uuid" ]]; then
      ((APP_GROUPS_SCOPE_GAPS+=1))
      mark_critical "Client scope '${EXPECTED_GROUPS_SCOPE_NAME}' is missing"
    else
      ok "Client scope '${EXPECTED_GROUPS_SCOPE_NAME}' present (${groups_scope_uuid})"

      groups_mapper_json="$(
        curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/client-scopes/${groups_scope_uuid}/protocol-mappers/models" 2>/dev/null \
          | jq -c --arg mapper "$EXPECTED_GROUPS_MAPPER_NAME" '.[] | select(.name == $mapper and .protocolMapper == "oidc-group-membership-mapper")' \
          | head -n1 || true
      )"
      if [[ -z "$groups_mapper_json" ]]; then
        ((APP_GROUPS_SCOPE_GAPS+=1))
        mark_critical "Scope '${EXPECTED_GROUPS_SCOPE_NAME}' missing mapper '${EXPECTED_GROUPS_MAPPER_NAME}' (oidc-group-membership-mapper)"
      else
        mapper_protocol="$(jq -r '.protocolMapper // ""' <<<"$groups_mapper_json")"
        claim_name="$(jq -r '.config["claim.name"] // ""' <<<"$groups_mapper_json")"
        full_path="$(jq -r '.config["full.path"] // ""' <<<"$groups_mapper_json")"
        access_claim="$(jq -r '.config["access.token.claim"] // ""' <<<"$groups_mapper_json")"
        multivalued_claim="$(jq -r '.config["multivalued"] // ""' <<<"$groups_mapper_json")"
        id_claim="$(jq -r '.config["id.token.claim"] // ""' <<<"$groups_mapper_json")"
        userinfo_claim="$(jq -r '.config["userinfo.token.claim"] // ""' <<<"$groups_mapper_json")"

        info "groups mapper config: protocolMapper=${mapper_protocol}, claim.name=${claim_name}, full.path=${full_path}, access.token.claim=${access_claim}, multivalued=${multivalued_claim}, id.token.claim=${id_claim}, userinfo.token.claim=${userinfo_claim}"

        if [[ "$claim_name" != "groups" ]]; then
          ((APP_GROUPS_SCOPE_GAPS+=1))
          mark_critical "groups mapper claim.name should be 'groups' (actual='${claim_name}')"
        fi
        if [[ "$full_path" != "true" ]]; then
          ((APP_GROUPS_SCOPE_GAPS+=1))
          mark_critical "groups mapper full.path should be true (actual='${full_path}')"
        fi
        if [[ "$access_claim" != "true" ]]; then
          ((APP_GROUPS_SCOPE_GAPS+=1))
          mark_critical "groups mapper access.token.claim should be true (actual='${access_claim}')"
        fi
        if [[ "$multivalued_claim" != "true" ]]; then
          ((APP_GROUPS_SCOPE_GAPS+=1))
          mark_critical "groups mapper multivalued should be true (actual='${multivalued_claim}')"
        fi
        if [[ "$id_claim" != "true" ]]; then
          mark_warning "groups mapper id.token.claim is '${id_claim}' (recommended: true)"
        fi
        if [[ "$userinfo_claim" != "true" ]]; then
          mark_warning "groups mapper userinfo.token.claim is '${userinfo_claim}' (recommended: true)"
        fi
      fi

      app_default_scopes="$(
        curl -fsS -H "Authorization: Bearer ${ADM}" "$KC/admin/realms/${REALM}/clients/${APP_CLIENT_UUID}/default-client-scopes" 2>/dev/null \
          | jq -r '.[].name' | sort -u || true
      )"
      info "app default client scopes: $(sorted_lines_to_csv "$app_default_scopes")"
      if ! contains_line "$EXPECTED_GROUPS_SCOPE_NAME" "$app_default_scopes"; then
        ((APP_GROUPS_SCOPE_GAPS+=1))
        mark_critical "Scope '${EXPECTED_GROUPS_SCOPE_NAME}' is not attached to app default client scopes"
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
  step "Validate authorization-model shape (AUTHZ-05)"
  info "Checking the LIVE model actually pushed to OpenFGA, not just fred-core's schema.fga.json source"
  if latest_models_payload="$(curl -fsS -H "Authorization: Bearer ${OPENFGA_TOKEN}" "${FGA}/stores/${STORE_ID}/authorization-models?page_size=1" 2>/dev/null)"; then
    current_model="$(jq -c '.authorization_models[0] // empty' <<<"$latest_models_payload")"
    if [[ -z "$current_model" ]]; then
      ((MODEL_SHAPE_GAPS+=1))
      mark_critical "OpenFGA store '${OPENFGA_STORE_NAME}' has no authorization model at all"
    else
      org_relations="$(jq -r '.type_definitions[]? | select(.type=="organization") | .relations // {} | keys[]?' <<<"$current_model" | sort -u)"
      team_owner_def="$(jq -c '.type_definitions[]? | select(.type=="team") | .relations.owner // {}' <<<"$current_model")"

      if contains_line "platform_admin" "$org_relations" && contains_line "platform_observer" "$org_relations"; then
        ok "organization type defines platform_admin and platform_observer (AUTHZ-05 target relations present)"
      else
        ((MODEL_SHAPE_GAPS+=1))
        mark_critical "organization type is missing platform_admin/platform_observer - the live OpenFGA model predates AUTHZ-05. Run 'make sync-openfga-model' then re-run 'make openfga-post-install'."
      fi

      if [[ "$team_owner_def" == '{"this":{}}' ]]; then
        ok "team.owner is a direct-only relation (no organization-admin escalation into team ownership)"
      else
        ((MODEL_SHAPE_GAPS+=1))
        mark_critical "team.owner is NOT direct-only (got: ${team_owner_def}) - this is the exact escalation bug fixed in AUTHZ-05 (FRED-AUTHORIZATION-TARGET-MODEL-RFC.md §24.2): a Keycloak admin would be an implicit owner of every team. Run 'make sync-openfga-model' then re-run 'make openfga-post-install'."
      fi
    fi
  else
    ((MODEL_SHAPE_GAPS+=1))
    mark_critical "Cannot read authorization models from OpenFGA store '${OPENFGA_STORE_NAME}'"
  fi
fi

ALICE_UID="${USER_IDS[alice]:-}"
if [[ -n "${ALICE_UID}" ]]; then
  step "Resolve Alice UID from Keycloak"
  ok "Alice UID = ${ALICE_UID}"
fi

KC_MEMBERSHIP_MISSING=0
FGA_UUID_MEMBERSHIP_MISSING=0
FGA_USERNAME_MEMBERSHIP_MISSING=0
FGA_UUID_MANAGER_MISSING=0
FGA_USERNAME_MANAGER_MISSING=0
FGA_UUID_OWNER_MISSING=0
FGA_USERNAME_OWNER_MISSING=0
FGA_UUID_PLATFORM_ROLE_MISSING=0
FGA_USERNAME_PLATFORM_ROLE_MISSING=0

step "Starting situation: team membership matrix"
for u in "${REQUIRED_USERS[@]}"; do
  printf "\n%sUser: %s%s\n" "${BOLD}" "$u" "${RESET}"
  uid="${USER_IDS[$u]:-}"
  if [[ -z "$uid" ]]; then
    mark_critical "Cannot evaluate memberships for '${u}' (user missing in Keycloak)"
    continue
  fi

  expected_teams="$(words_to_sorted_lines "${EXPECTED_TEAMS[$u]:-}")"
  expected_manager_teams="$(words_to_sorted_lines "${EXPECTED_MANAGER_TEAMS[$u]:-}")"
  expected_owner_teams="$(words_to_sorted_lines "${EXPECTED_OWNER_TEAMS[$u]:-}")"
  expected_platform_roles="$(words_to_sorted_lines "${EXPECTED_PLATFORM_ROLES[$u]:-}")"
  expected_groups="$(to_keycloak_group_lines "$expected_teams")"
  info "Keycloak UID: ${uid}"
  info "Expected teams: $(sorted_lines_to_csv "$expected_teams")"
  info "Expected manager teams: $(sorted_lines_to_csv "$expected_manager_teams")"
  info "Expected owner teams: $(sorted_lines_to_csv "$expected_owner_teams")"
  info "Expected platform roles (AUTHZ-05): $(sorted_lines_to_csv "$expected_platform_roles")"

  kc_groups="$(
    curl -fsS -H "Authorization: Bearer ${ADM}" \
      "$KC/admin/realms/${REALM}/users/${uid}/groups" | jq -r '.[].path' | sort -u
  )"
  info "Keycloak groups: $(sorted_lines_to_csv "$kc_groups")"

  missing_kc_groups="$(missing_lines "$expected_groups" "$kc_groups")"
  extra_kc_groups="$(extra_lines "$expected_groups" "$kc_groups")"
  if [[ -n "$missing_kc_groups" ]]; then
    ((KC_MEMBERSHIP_MISSING+=1))
    mark_critical "Keycloak missing expected groups for '${u}': $(sorted_lines_to_csv "$missing_kc_groups")"
  fi
  if [[ -n "$extra_kc_groups" ]]; then
    mark_warning "Keycloak extra groups for '${u}': $(sorted_lines_to_csv "$extra_kc_groups")"
  fi

  if [[ -n "${ALL_TUPLES}" ]]; then
    fga_username_teams="$(fga_team_relation_lines "user:${u}" member)"
    fga_uuid_teams="$(fga_team_relation_lines "user:${uid}" member)"
    fga_username_manager_teams="$(fga_team_relation_lines "user:${u}" manager)"
    fga_uuid_manager_teams="$(fga_team_relation_lines "user:${uid}" manager)"
    fga_username_owner_teams="$(fga_team_relation_lines "user:${u}" owner)"
    fga_uuid_owner_teams="$(fga_team_relation_lines "user:${uid}" owner)"

    info "OpenFGA member teams (user:${u}): $(sorted_lines_to_csv "$fga_username_teams")"
    info "OpenFGA member teams (user:${uid}): $(sorted_lines_to_csv "$fga_uuid_teams")"
    info "OpenFGA manager teams (user:${u}): $(sorted_lines_to_csv "$fga_username_manager_teams")"
    info "OpenFGA manager teams (user:${uid}): $(sorted_lines_to_csv "$fga_uuid_manager_teams")"
    info "OpenFGA owner teams (user:${u}): $(sorted_lines_to_csv "$fga_username_owner_teams")"
    info "OpenFGA owner teams (user:${uid}): $(sorted_lines_to_csv "$fga_uuid_owner_teams")"

    missing_fga_uuid="$(missing_lines "$expected_teams" "$fga_uuid_teams")"
    if [[ -n "$missing_fga_uuid" ]]; then
      ((FGA_UUID_MEMBERSHIP_MISSING+=1))
      mark_critical "OpenFGA UUID-subject tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_uuid")"
    fi

    missing_fga_uuid_manager="$(missing_lines "$expected_manager_teams" "$fga_uuid_manager_teams")"
    if [[ -n "$missing_fga_uuid_manager" ]]; then
      ((FGA_UUID_MANAGER_MISSING+=1))
      mark_critical "OpenFGA UUID-subject manager tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_uuid_manager")"
    fi

    missing_fga_uuid_owner="$(missing_lines "$expected_owner_teams" "$fga_uuid_owner_teams")"
    if [[ -n "$missing_fga_uuid_owner" ]]; then
      ((FGA_UUID_OWNER_MISSING+=1))
      mark_critical "OpenFGA UUID-subject owner tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_uuid_owner")"
    fi

    if [[ "${OPENFGA_EXPECT_USERNAME_SUBJECTS,,}" == "true" ]]; then
      missing_fga_user="$(missing_lines "$expected_teams" "$fga_username_teams")"
      if [[ -n "$missing_fga_user" ]]; then
        ((FGA_USERNAME_MEMBERSHIP_MISSING+=1))
        mark_warning "OpenFGA username-subject tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_user")"
      fi

      missing_fga_user_manager="$(missing_lines "$expected_manager_teams" "$fga_username_manager_teams")"
      if [[ -n "$missing_fga_user_manager" ]]; then
        ((FGA_USERNAME_MANAGER_MISSING+=1))
        mark_warning "OpenFGA username-subject manager tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_user_manager")"
      fi

      missing_fga_user_owner="$(missing_lines "$expected_owner_teams" "$fga_username_owner_teams")"
      if [[ -n "$missing_fga_user_owner" ]]; then
        ((FGA_USERNAME_OWNER_MISSING+=1))
        mark_warning "OpenFGA username-subject owner tuples missing for '${u}': $(sorted_lines_to_csv "$missing_fga_user_owner")"
      fi
    fi

    # AUTHZ-05 platform roles (platform_admin/platform_observer): stored-only
    # OpenFGA relations on organization:fred, seeded by openfga-post-install.sh
    # from configuration.yaml's platform_roles - independent of app_roles.
    while IFS= read -r platform_role; do
      [[ -n "$platform_role" ]] || continue
      fga_relation="${PLATFORM_ROLE_TO_FGA_RELATION[$platform_role]:-}"
      if [[ -z "$fga_relation" ]]; then
        mark_critical "Unknown platform role '${platform_role}' for user '${u}' (supported: admin, observer)"
        continue
      fi

      if fga_has_org_relation "user:${uid}" "$fga_relation"; then
        ok "OpenFGA UUID-subject '${fga_relation}' present for '${u}'"
      else
        ((FGA_UUID_PLATFORM_ROLE_MISSING+=1))
        mark_critical "OpenFGA UUID-subject tuple missing for '${u}': expected '${fga_relation}' on organization:fred"
      fi

      if [[ "${OPENFGA_EXPECT_USERNAME_SUBJECTS,,}" == "true" ]]; then
        if fga_has_org_relation "user:${u}" "$fga_relation"; then
          ok "OpenFGA username-subject '${fga_relation}' present for '${u}'"
        else
          ((FGA_USERNAME_PLATFORM_ROLE_MISSING+=1))
          mark_warning "OpenFGA username-subject tuple missing for '${u}': expected '${fga_relation}' on organization:fred"
        fi
      fi
    done <<<"$expected_platform_roles"
  fi
done

AGENT_IDS=()
TOTAL_TUPLES=-1
ALICE_OWNER_COUNT=0
AGENTS_WITH_OWNER=0
AGENTS_WITHOUT_OWNER=0
UNSUPPORTED_AGENT_IDS=0

if is_truthy "$PREFLIGHT_CHECK_AGENT_OWNERSHIP"; then
  step "Read agent IDs from Postgres"
  mapfile -t AGENT_IDS < <(
    psql -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" -Atc \
      "select id from public.\"agent\" order by id;" 2>/dev/null || true
  )

  if [[ "${#AGENT_IDS[@]}" -eq 0 ]]; then
    info "No agents found in Postgres (normal starting situation)"
  else
    ok "${#AGENT_IDS[@]} agent(s) found"
    info "IDs: ${AGENT_IDS[*]}"
  fi
fi

if [[ -n "${ALL_TUPLES}" ]]; then
  step "Inspect OpenFGA tuples"
  TOTAL_TUPLES="$(jq '.tuples | length' <<<"$ALL_TUPLES")"
  ok "Current tuples in store: ${TOTAL_TUPLES}"

  if is_truthy "$PREFLIGHT_CHECK_AGENT_OWNERSHIP" && [[ -n "${ALICE_UID}" ]]; then
    ALICE_OWNER_COUNT="$(
      jq -r --arg uid "user:${ALICE_UID}" \
        '[.tuples[].key | select(.user==$uid and .relation=="owner" and (.object|startswith("agent:")))] | length' <<<"$ALL_TUPLES"
    )"
    info "Alice owner tuples (user UUID): ${ALICE_OWNER_COUNT}"
  fi

  if is_truthy "$PREFLIGHT_CHECK_AGENT_OWNERSHIP" && [[ "${#AGENT_IDS[@]}" -gt 0 && -n "${ALICE_UID}" ]]; then
    step "Check ownership coverage (READ-ONLY)"
    for AGENT_ID in "${AGENT_IDS[@]}"; do
      if [[ ! "${AGENT_ID}" =~ ^[^[:space:]]{2,256}$ ]]; then
        ((UNSUPPORTED_AGENT_IDS+=1))
        mark_warning "Unsupported OpenFGA agent id '${AGENT_ID}' (contains spaces/invalid chars)"
        continue
      fi

      exists="$(
        jq -r --arg u "user:${ALICE_UID}" --arg o "agent:${AGENT_ID}" \
          '[.tuples[].key | select(.user==$u and .relation=="owner" and .object==$o)] | length' <<<"$ALL_TUPLES"
      )"
      if [[ "$exists" -gt 0 ]]; then
        ((AGENTS_WITH_OWNER+=1))
      else
        ((AGENTS_WITHOUT_OWNER+=1))
        mark_warning "Missing owner tuple for Alice on agent '${AGENT_ID}'"
      fi
    done
  fi
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
info "Keycloak users: ${FOUND_USERS}/${#REQUIRED_USERS[@]} present"
info "Keycloak groups: ${FOUND_GROUPS}/${#REQUIRED_GROUPS[@]} present"
info "Keycloak realm name gaps (expected 'app'): ${REALM_NAME_GAPS}"
info "Keycloak realm existence gaps: ${REALM_EXISTENCE_GAPS}"
info "App client role definition gaps (admin/editor/viewer/service_agent): ${APP_CLIENT_ROLE_GAPS}"
info "User app permission gaps (effective app roles): ${APP_USER_PERMISSION_GAPS}"
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
info "Team membership gaps (Keycloak): ${KC_MEMBERSHIP_MISSING}"
if [[ -n "${ALL_TUPLES}" ]]; then
  info "Team membership gaps (OpenFGA UUID-subject): ${FGA_UUID_MEMBERSHIP_MISSING}"
  info "Team manager-role gaps (OpenFGA UUID-subject): ${FGA_UUID_MANAGER_MISSING}"
  info "Team owner-role gaps (OpenFGA UUID-subject): ${FGA_UUID_OWNER_MISSING}"
elif [[ "${OPENFGA_STATUS}" == "present" ]]; then
  info "Team membership gaps (OpenFGA UUID-subject): not evaluated (tuple read failed)"
  info "Team manager-role gaps (OpenFGA UUID-subject): not evaluated (tuple read failed)"
  info "Team owner-role gaps (OpenFGA UUID-subject): not evaluated (tuple read failed)"
else
  info "Team membership gaps (OpenFGA UUID-subject): not evaluated (OpenFGA unavailable)"
  info "Team manager-role gaps (OpenFGA UUID-subject): not evaluated (OpenFGA unavailable)"
  info "Team owner-role gaps (OpenFGA UUID-subject): not evaluated (OpenFGA unavailable)"
fi
if [[ "${OPENFGA_EXPECT_USERNAME_SUBJECTS,,}" == "true" ]]; then
  if [[ -n "${ALL_TUPLES}" ]]; then
    info "Team membership gaps (OpenFGA username-subject): ${FGA_USERNAME_MEMBERSHIP_MISSING}"
    info "Team manager-role gaps (OpenFGA username-subject): ${FGA_USERNAME_MANAGER_MISSING}"
    info "Team owner-role gaps (OpenFGA username-subject): ${FGA_USERNAME_OWNER_MISSING}"
  elif [[ "${OPENFGA_STATUS}" == "present" ]]; then
    info "Team membership gaps (OpenFGA username-subject): not evaluated (tuple read failed)"
    info "Team manager-role gaps (OpenFGA username-subject): not evaluated (tuple read failed)"
    info "Team owner-role gaps (OpenFGA username-subject): not evaluated (tuple read failed)"
  else
    info "Team membership gaps (OpenFGA username-subject): not evaluated (OpenFGA unavailable)"
    info "Team manager-role gaps (OpenFGA username-subject): not evaluated (OpenFGA unavailable)"
    info "Team owner-role gaps (OpenFGA username-subject): not evaluated (OpenFGA unavailable)"
  fi
else
  info "Team membership gaps (OpenFGA username-subject): skipped by config"
  info "Team manager-role gaps (OpenFGA username-subject): skipped by config"
  info "Team owner-role gaps (OpenFGA username-subject): skipped by config"
fi
info "Authorization-model shape gaps (AUTHZ-05 relations, no escalation): ${MODEL_SHAPE_GAPS}"
if [[ -n "${ALL_TUPLES}" ]]; then
  info "Platform-role gaps (OpenFGA UUID-subject): ${FGA_UUID_PLATFORM_ROLE_MISSING}"
  if [[ "${OPENFGA_EXPECT_USERNAME_SUBJECTS,,}" == "true" ]]; then
    info "Platform-role gaps (OpenFGA username-subject): ${FGA_USERNAME_PLATFORM_ROLE_MISSING}"
  else
    info "Platform-role gaps (OpenFGA username-subject): skipped by config"
  fi
else
  info "Platform-role gaps (OpenFGA UUID-subject): not evaluated (OpenFGA unavailable or tuple read failed)"
  info "Platform-role gaps (OpenFGA username-subject): not evaluated (OpenFGA unavailable or tuple read failed)"
fi
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
if is_truthy "$PREFLIGHT_CHECK_AGENT_OWNERSHIP"; then
  info "Postgres agents: ${#AGENT_IDS[@]}"
  if [[ -n "${ALICE_UID}" && "${TOTAL_TUPLES}" -ge 0 ]]; then
    info "Alice owner tuples: ${ALICE_OWNER_COUNT}"
  elif [[ -n "${ALICE_UID}" ]]; then
    info "Alice owner tuples: not evaluated (OpenFGA tuples unavailable)"
  fi
  if [[ "${#AGENT_IDS[@]}" -gt 0 && -n "${ALICE_UID}" ]]; then
    info "Agents with Alice owner tuple: ${AGENTS_WITH_OWNER}"
    info "Agents missing Alice owner tuple: ${AGENTS_WITHOUT_OWNER}"
  fi
  if [[ "${UNSUPPORTED_AGENT_IDS}" -gt 0 ]]; then
    info "Unsupported agent IDs for OpenFGA: ${UNSUPPORTED_AGENT_IDS}"
  fi
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
