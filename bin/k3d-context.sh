#!/usr/bin/env bash
# Internal application context. The public command derives placement once.
if [[ -v ENV || -v INSTANCE || -v MODE || -v PROFILE ]]; then
  echo 'Removed deployment selectors. Use make k3d-up, k3d-up-swift or k3d-up-weaver.' >&2
  exit 2
fi
while IFS='=' read -r name value; do
  [[ "$name" == K3D_* ]] || continue
  export "$name=$value"
done < "$(cd "$(dirname "${BASH_SOURCE[0]}")/../k3d" && pwd)/local.env"
unset name value
export KUBE_CONTEXT=k3d-fred K3D_INFRA_NAMESPACE=fred
: "${K3D_NAMESPACE:?internal caller must provide the application namespace}"
case "$K3D_NAMESPACE" in
  fred) export K3D_APP_HOST=localhost K3D_DATABASE=fred K3D_TEMPORAL_NAMESPACE=default ;;
  fred-weaver) export K3D_APP_HOST=weaver.localhost K3D_DATABASE=fred_weaver K3D_TEMPORAL_NAMESPACE=fred-weaver ;;
  *) echo 'Unsupported local application namespace' >&2; exit 2 ;;
esac
export K3D_PUBLIC_URL="http://$K3D_APP_HOST:$K3D_HOST_PORT_FRONTEND"
export K3D_WEBSOCKET_URL="ws://$K3D_APP_HOST:$K3D_HOST_PORT_FRONTEND"
export K3D_KEYCLOAK_URL="http://$K3D_KEYCLOAK_HOST:$K3D_HOST_PORT_KEYCLOAK"
export K3D_REALM_URL="$K3D_KEYCLOAK_URL/realms/app"
