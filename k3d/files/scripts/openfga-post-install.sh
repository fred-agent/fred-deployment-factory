#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[openfga-post-install] %s\n' "$*"
}

die() {
  printf '[openfga-post-install] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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

require_cmd curl
require_cmd jq

OPENFGA_URL="${OPENFGA_URL:-http://localhost:9080}"
OPENFGA_URL="${OPENFGA_URL%/}"
OPENFGA_API_TOKEN="${OPENFGA_API_TOKEN:-Azerty123_}"
OPENFGA_STORE_NAME="${OPENFGA_STORE_NAME:-fred}"
OPENFGA_MODEL_FILE="${OPENFGA_MODEL_FILE:-${SCRIPT_DIR}/openfga-model.json}"

[[ -f "$OPENFGA_MODEL_FILE" ]] || die "OpenFGA model file not found: ${OPENFGA_MODEL_FILE}"

CHANGED=0

log "waiting for OpenFGA API at '${OPENFGA_URL}'"
wait_for_openfga || die "OpenFGA API is not reachable at ${OPENFGA_URL}"

STORE_ID="$(resolve_store_id)"
log "using OpenFGA store '${OPENFGA_STORE_NAME}' (${STORE_ID})"

AUTHORIZATION_MODEL_ID=""
ensure_authorization_model
[[ -n "$AUTHORIZATION_MODEL_ID" ]] || die "cannot resolve OpenFGA authorization model id"
log "using authorization model '${AUTHORIZATION_MODEL_ID}'"

log "post-install completed (store=${STORE_ID}, model=${AUTHORIZATION_MODEL_ID}, changes=${CHANGED})"
