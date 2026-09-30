#!/usr/bin/env bash
set -Eeuo pipefail

# Make an already registered Keycloak account the platform_admin of the k3d
# Fred, then turn every capability on (tools, agent templates).
#
#   bin/k3d-fred-bootstrap.sh         (run by `make k3d-fred-bootstrap`)
#
# The root bootstrap works once per platform: the first account to use it keeps
# the role, a later call with another account is refused. The token comes from
# fred-secrets, the Foundation Secret; the calls are fred's own
# (apps/control-plane-backend: bootstrap-local, activate-all-capabilities).
#
# Environment: BOOTSTRAP_USER, BOOTSTRAP_PASSWORD, FRED_DIR, K3D_NAMESPACE,
#              K3D_HOST_PORT_FRONTEND, K3D_HOST_PORT_KEYCLOAK

c_err='\033[1;31m'; c_reset='\033[0m'
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }

[[ -n "${BOOTSTRAP_USER:-}" && -n "${BOOTSTRAP_PASSWORD:-}" ]] \
  || fail "usage: make k3d-fred-bootstrap BOOTSTRAP_USER=<you> BOOTSTRAP_PASSWORD=<pw>"
fred_dir="$(cd "${FRED_DIR:?}" 2>/dev/null && pwd)" || fail "FRED_DIR=$FRED_DIR: no such directory (a fred checkout)"
ns="${K3D_NAMESPACE:-fred}"
keycloak="http://keycloak:${K3D_HOST_PORT_KEYCLOAK:-8080}"

getent hosts keycloak >/dev/null || fail "'keycloak' does not resolve on this machine. Once, with sudo:
       grep -qw keycloak /etc/hosts || echo \"127.0.0.1 keycloak\" | sudo tee -a /etc/hosts"

token_file="$(umask 077 && mktemp)"
trap 'rm -f "$token_file"' EXIT
kubectl get secret fred-secrets -n "$ns" -o jsonpath='{.data.CONTROL_PLANE_BOOTSTRAP_TOKEN}' | base64 -d >"$token_file"
[[ -s "$token_file" ]] || fail "fred-secrets has no CONTROL_PLANE_BOOTSTRAP_TOKEN: run 'make k3d-up'"

make -C "$fred_dir/apps/control-plane-backend" bootstrap-local activate-all-capabilities \
  BOOTSTRAP_TOKEN_FILE="$token_file" \
  CONTROL_PLANE_BASE_URL="http://localhost:${K3D_HOST_PORT_FRONTEND:-8088}/control-plane/v1" \
  KEYCLOAK_REALM_URL="$keycloak/realms/app" \
  KEYCLOAK_REGISTER_URL="$keycloak/realms/app/account" \
  BOOTSTRAP_USER="$BOOTSTRAP_USER" BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASSWORD"
