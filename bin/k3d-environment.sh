#!/usr/bin/env bash
# Source from host-side helpers. Make exports the same profile; explicit overrides win.
export ENV="${ENV:-swift}"
case "$ENV" in
  swift|secondary) ;;
  *) echo "Invalid ENV '$ENV': use swift or secondary" >&2; exit 1 ;;
esac
k3d_profile="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k3d/environments" && pwd)/$ENV.env"
while IFS='=' read -r name value; do
  [[ "$name" == K3D_* ]] || continue
  if [[ ! -v "$name" ]]; then export "$name=$value"; fi
done < "$k3d_profile"
unset k3d_profile name value
export INSTANCE="${INSTANCE:-default}"
export K3D_INFRA_NAMESPACE="${K3D_INFRA_NAMESPACE:-fred}"
case "$INSTANCE" in
  default) export K3D_NAMESPACE="${K3D_NAMESPACE:-$K3D_INFRA_NAMESPACE}" ;;
  weaver)
    export K3D_NAMESPACE="${K3D_NAMESPACE:-fred-weaver}"
    export K3D_APP_HOST="${K3D_APP_HOST:-weaver.localhost}"
    export K3D_DATABASE="${K3D_DATABASE:-fred_weaver}"
    export K3D_TEMPORAL_NAMESPACE="${K3D_TEMPORAL_NAMESPACE:-fred-weaver}"
    [[ "$K3D_NAMESPACE" != "$K3D_INFRA_NAMESPACE" ]] || { echo "Weaver requires a separate application namespace" >&2; exit 1; }
    ;;
  *) echo "Invalid INSTANCE: use default or weaver" >&2; exit 1 ;;
esac
export K3D_DATABASE="${K3D_DATABASE:-fred}"
export K3D_TEMPORAL_NAMESPACE="${K3D_TEMPORAL_NAMESPACE:-default}"
export K3D_APP_HOST="${K3D_APP_HOST:-$K3D_HOST_NAME}"
export KUBE_CONTEXT="k3d-$K3D_CLUSTER"
export K3D_PUBLIC_URL="http://$K3D_APP_HOST:$K3D_HOST_PORT_FRONTEND"
export K3D_WEBSOCKET_URL="ws://$K3D_APP_HOST:$K3D_HOST_PORT_FRONTEND"
export K3D_KEYCLOAK_URL="http://$K3D_KEYCLOAK_HOST:$K3D_HOST_PORT_KEYCLOAK"
export K3D_REALM_URL="$K3D_KEYCLOAK_URL/realms/app"
