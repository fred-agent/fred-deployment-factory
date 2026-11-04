#!/usr/bin/env bash
# Opt-in generic OIDC token shape for the local Keycloak realm.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/keycloak-post-install.sh"

mode="${1:-apply}"
[[ "$mode" == apply || "$mode" == revert ]] || die "usage: $0 [apply|revert]"
kc config credentials --server "$KEYCLOAK_SERVER_URL" --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

clients=(app agentic knowledge-flow control-plane fred-evaluation-worker)
services=(agentic knowledge-flow control-plane fred-evaluation-worker)

has_default_scope() {
  kc get "clients/$1/default-client-scopes" -r "$KEYCLOAK_REALM" -c \
    | jq -e --arg id "$2" '.[] | select(.id == $id)' >/dev/null
}
attach_scope() {
  if ! has_default_scope "$1" "$2"; then
    kc update "clients/$1/default-client-scopes/$2" -r "$KEYCLOAK_REALM" -n >/dev/null
  fi
}
detach_scope() {
  if has_default_scope "$1" "$2"; then
    kc delete "clients/$1/default-client-scopes/$2" -r "$KEYCLOAK_REALM" >/dev/null
  fi
}
remove_role() {
  local username="$1" client="$2" role="$3"
  if kc get-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$client" -c \
    | jq -e --arg role "$role" '.[] | select(.name == $role)' >/dev/null; then
    kc remove-roles -r "$KEYCLOAK_REALM" --uusername "$username" \
      --cclientid "$client" --rolename "$role" >/dev/null
  fi
}

scope_uuid="$(client_scope_uuid fred-api-shape)"
roles_uuid="$(client_scope_uuid roles)"
api_uuid="$(client_uuid fred-api)"

if [[ "$mode" == revert ]]; then
  for client in "${clients[@]}"; do
    uuid="$(client_uuid "$client")"
    [[ -n "$uuid" ]] || die "missing client '$client'"
    if [[ -n "$scope_uuid" ]]; then detach_scope "$uuid" "$scope_uuid"; fi
    if [[ -n "$roles_uuid" ]]; then attach_scope "$uuid" "$roles_uuid"; fi
  done
  for client in "${services[@]}"; do
    username="$(wait_for_service_account_username "$client")"
    if [[ -n "$api_uuid" ]]; then
      remove_role "$username" fred-api service_agent
      remove_role "$username" fred-api delegation_caller
    fi
    case "$client" in
      fred-evaluation-worker) ;;
      *)
        ensure_user_client_role "$username" realm-management query-users
        ensure_user_client_role "$username" realm-management view-users
        if [[ "$client" == control-plane ]] || \
           { [[ "$client" == knowledge-flow ]] && is_truthy "$KEYCLOAK_KF_ENABLE_MANAGE_USERS"; }; then
          ensure_user_client_role "$username" realm-management manage-users
        fi
        ;;
    esac
  done
  if [[ -n "$scope_uuid" ]]; then kc delete "client-scopes/$scope_uuid" -r "$KEYCLOAK_REALM" >/dev/null; fi
  if [[ -n "$api_uuid" ]]; then kc delete "clients/$api_uuid" -r "$KEYCLOAK_REALM" >/dev/null; fi
  log 'generic OIDC profile reverted'
  exit 0
fi

if [[ -z "$api_uuid" ]]; then
  kc create clients -r "$KEYCLOAK_REALM" -s clientId=fred-api -s protocol=openid-connect \
    -s enabled=true -s publicClient=false -s standardFlowEnabled=false \
    -s implicitFlowEnabled=false -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false >/dev/null
  api_uuid="$(client_uuid fred-api)"
fi
[[ -n "$api_uuid" ]] || die "cannot create fred-api client"
api_json="$(kc get "clients/$api_uuid" -r "$KEYCLOAK_REALM" -c)"
if ! jq -e '.enabled == true and .standardFlowEnabled == false and .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and .serviceAccountsEnabled == false' >/dev/null <<<"$api_json"; then
  kc update "clients/$api_uuid" -r "$KEYCLOAK_REALM" -s enabled=true \
    -s standardFlowEnabled=false -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false >/dev/null
fi
ensure_client_role fred-api service_agent 'Fred service identity'
ensure_client_role fred-api delegation_caller 'Fred delegation caller'

if [[ -z "$scope_uuid" ]]; then
  kc create client-scopes -r "$KEYCLOAK_REALM" -s name=fred-api-shape \
    -s protocol=openid-connect >/dev/null
  scope_uuid="$(client_scope_uuid fred-api-shape)"
fi
[[ -n "$scope_uuid" ]] || die "cannot create fred-api-shape scope"
mappers="$(kc get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" -c)"
if ! jq -e '.[] | select(.name == "fred-api-roles")' >/dev/null <<<"$mappers"; then
  kc create "client-scopes/$scope_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
    -s name=fred-api-roles -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-client-role-mapper \
    -s 'config."usermodel.clientRoleMapping.clientId"=fred-api' \
    -s 'config."claim.name"=roles' -s 'config."jsonType.label"=String' \
    -s 'config."multivalued"=true' -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null
fi
if ! jq -e '.[] | select(.name == "fred-api-audience")' >/dev/null <<<"$mappers"; then
  kc create "client-scopes/$scope_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
    -s name=fred-api-audience -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config."included.client.audience"=fred-api' \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null
fi

for client in "${clients[@]}"; do
  uuid="$(client_uuid "$client")"
  [[ -n "$uuid" ]] || die "missing client '$client'; run keycloak-post-install first"
  attach_scope "$uuid" "$scope_uuid"
  if [[ "${STRICT:-0}" == 1 && -n "$roles_uuid" ]]; then detach_scope "$uuid" "$roles_uuid"; fi
done
for client in "${services[@]}"; do
  username="$(wait_for_service_account_username "$client")"
  ensure_user_client_role "$username" fred-api service_agent
  if [[ "$client" == agentic ]]; then
    ensure_user_client_role "$username" fred-api delegation_caller
  fi
  if [[ "${STRICT:-0}" == 1 ]]; then
    for role in query-users view-users manage-users; do
      remove_role "$username" realm-management "$role"
    done
  fi
done
log "generic OIDC profile applied (STRICT=${STRICT:-0})"
