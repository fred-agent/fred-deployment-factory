#!/usr/bin/env bash
set -Eeuo pipefail
# Provision real Keycloak identities from a git-ignored roster file.
#
# Identity only: creates the Keycloak user and sets a one-time temporary
# password (kcadm `set-password --temporary` — forces Keycloak's own
# UPDATE_PASSWORD required action at first login). Never assigns a team or
# platform role — that stays Fred's job, via the declarative platform-import
# bundle (`manifest.json` + `users.json`, uploaded through Admin -> Migration
# or `POST /control-plane/v1/import-export/import`) run afterwards, once
# these identities exist. See docs/DEPLOY-CLOUD.md §5.
#
# Idempotent and non-destructive: a username that already exists in the realm
# is skipped, never re-created, never re-passworded.

NAMESPACE="${NAMESPACE:-default}"
KEYCLOAK_DEPLOY="${KEYCLOAK_DEPLOY:-keycloak}"
SECRET="${SECRET:-fredlab-infra-secrets}"
REALM="${REALM:-app}"
FILE="${FILE:-config/fredlab-keycloak-identity.json}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--file PATH] [--dry-run]

Creates Keycloak users from a git-ignored roster file (default:
${FILE} — see config/fredlab-keycloak-identity.example.json for the shape
and field reference). Each new user gets a one-time temporary password that
Keycloak forces them to change at first login. Users that already exist in
the realm are left untouched.

Options:
  --file PATH   Roster file to read (default: ${FILE})
  --dry-run     List what would be created without creating anything

Env (same defaults as bin/fredlab-keycloak-users.sh):
  NAMESPACE, KEYCLOAK_DEPLOY, SECRET, REALM
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "Missing required tool: kubectl" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Missing required tool: jq" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "Missing required tool: openssl" >&2; exit 1; }
[[ -f "$FILE" ]] || {
  echo "Roster file not found: $FILE" >&2
  echo "See config/fredlab-keycloak-identity.example.json for the shape — copy it, fill in your team, keep it out of git." >&2
  exit 1
}

jq -e 'has("users") and (.users | type == "array")' "$FILE" >/dev/null \
  || { echo "$FILE must have a top-level \"users\" array (see config/fredlab-keycloak-identity.example.json)" >&2; exit 1; }

au="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d)"
ap="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)"
kc() { kubectl -n "$NAMESPACE" exec "deploy/$KEYCLOAK_DEPLOY" -- /opt/keycloak/bin/kcadm.sh "$@"; }

kc config credentials --server http://localhost:8080 --realm master --user "$au" --password "$ap" >/dev/null

user_exists() {
  local username="$1"
  kc get users -r "$REALM" -q "username=${username}" -c 2>/dev/null | jq -e 'length > 0' >/dev/null
}

count="$(jq '.users | length' "$FILE")"
echo "Roster: $count user(s) in $FILE (realm: $REALM)"
(( DRY_RUN )) && echo "-- dry run, nothing will be created --"

generated=()

for i in $(seq 0 $((count - 1))); do
  entry="$(jq -c ".users[$i]" "$FILE")"
  username="$(jq -r '.username // empty' <<<"$entry")"
  email="$(jq -r '.email // empty' <<<"$entry")"
  first_name="$(jq -r '.firstName // empty' <<<"$entry")"
  last_name="$(jq -r '.lastName // empty' <<<"$entry")"
  password="$(jq -r '.temporaryPassword // empty' <<<"$entry")"

  if [[ -z "$username" ]]; then
    echo "  entry $i: missing \"username\", skipping" >&2
    continue
  fi
  if [[ -z "$email" || -z "$first_name" || -z "$last_name" ]]; then
    echo "  $username: \"email\", \"firstName\" and \"lastName\" are all required — Keycloak's User Profile schema rejects a direct-grant login without them (see docs/DEPLOY-CLOUD.md §4.1), skipping" >&2
    continue
  fi

  if user_exists "$username"; then
    echo "  $username: already exists, skipping (never overwrites an existing identity or password)"
    continue
  fi

  if (( DRY_RUN )); then
    echo "  $username: would create ($email, $first_name $last_name)"
    continue
  fi

  if [[ -z "$password" ]]; then
    password="$(openssl rand -hex 16)"
    generated+=("$username:$password")
  fi

  kc create users -r "$REALM" \
    -s "username=${username}" \
    -s "email=${email}" \
    -s "firstName=${first_name}" \
    -s "lastName=${last_name}" \
    -s enabled=true \
    -s emailVerified=true >/dev/null
  kc set-password -r "$REALM" --username "$username" --new-password "$password" --temporary >/dev/null
  echo "  $username: created, temporary password set (forced change at first login)"
done

if (( ${#generated[@]} > 0 )); then
  echo
  echo "=== Generated temporary passwords — hand these to each user over a secure channel, then discard this output ==="
  for pair in "${generated[@]}"; do
    echo "  $pair"
  done
fi

echo
echo "Identities only — no team or role was granted. Next: run Fred's declarative import"
echo "(Admin -> Migration, or POST /control-plane/v1/import-export/import) with a users.json"
echo "that names these usernames and their teams/roles — see docs/DEPLOY-CLOUD.md §5."
