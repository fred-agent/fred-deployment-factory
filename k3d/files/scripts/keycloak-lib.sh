# Keycloak admin REST primitives, idempotent: each ensure_* creates or fixes
# one object and never deletes. Sourced by keycloak-post-install-k8s.sh (the
# platform's identities, in the cluster) and by bin/k3d-identities (the
# identities an application declares, from the host).
#
# The caller sets KEYCLOAK_SERVER_URL, KEYCLOAK_REALM, KC_BOOTSTRAP_ADMIN_USERNAME
# and KC_BOOTSTRAP_ADMIN_PASSWORD, then KEYCLOAK_ADMIN_HTTP_TOKEN="$(kc_http_admin_token)".

KC_LOG_PREFIX="${KC_LOG_PREFIX:-keycloak}"
CHANGED=0
KEYCLOAK_ADMIN_HTTP_TOKEN="${KEYCLOAK_ADMIN_HTTP_TOKEN:-}"

log() {
  printf '[%s] %s\n' "$KC_LOG_PREFIX" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$KC_LOG_PREFIX" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$KC_LOG_PREFIX" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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

mark_changed() {
  CHANGED=1
}

client_uuid() {
  local client_id="$1"
  local encoded_client_id
  encoded_client_id="$(uri_encode "$client_id")"
  kc_http_get "/clients?clientId=${encoded_client_id}" | jq -r '.[0].id // empty'
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

keycloak_user_json_by_username() {
  local username="$1"
  local encoded_username
  encoded_username="$(uri_encode "$username")"
  kc_http_get "/users?username=${encoded_username}&exact=true" | jq -c '.[0] // empty'
}
