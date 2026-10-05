#!/usr/bin/env bash
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
port="${K3D_ZITADEL_PORT:-5173}"
export K3D_HOST_PORT_FRONTEND="$port"
export FRED_URL="http://localhost:${port}"
export ZITADEL_ISSUER="${ZITADEL_ISSUER:-https://fred-lab-instance-qeuzio.ch1.zitadel.cloud}"

python=""
for candidate in ${PYTHON:-} python3 /usr/bin/python3; do
  if "$candidate" -c 'import yaml' 2>/dev/null; then python="$candidate"; break; fi
done
[[ -n "$python" ]] || { echo 'A python3 with PyYAML is required (pip install pyyaml, or PYTHON=/path/to/python3).' >&2; exit 1; }
cd "$here"

# deploy (default) | join <bundle> | bundle | purge
case "${1:-deploy}" in
  bundle) exec "$python" bin/k3d-zitadel-cloud.py bundle ;;
  purge) exec "$python" bin/k3d-zitadel-cloud.py purge ;;
  join)
    [[ -n "${2:-}" ]] || { echo 'Usage: make k3d-zitadel-cloud-join ZITADEL_BUNDLE=<tester bundle file>' >&2; exit 1; }
    "$python" bin/k3d-zitadel-cloud.py join --bundle "$2"
    # A tester never provisions: whatever PAT this shell holds is ignored.
    unset ZITADEL_PAT
    ;;
  deploy) ;;
  *) echo "Unknown command: $1" >&2; exit 1 ;;
esac

# No local state: the committed fred-lab bundle wins, even with a PAT in the shell, so a
# checkout never provisions a second Cloud project. Provisioning anew needs the bundle gone
# (make k3d-zitadel-cloud-wipe ZITADEL_PURGE=1 removes it).
if [[ ! -f docker/zitadel/state/cloud.json ]]; then
  if [[ -f docker/zitadel/fred-lab-bundle.json ]]; then
    "$python" bin/k3d-zitadel-cloud.py join --bundle docker/zitadel/fred-lab-bundle.json
    unset ZITADEL_PAT
  elif [[ -z "${ZITADEL_PAT:-}" ]]; then
    echo 'Initial Cloud provisioning needs ZITADEL_PAT (no docker/zitadel/fred-lab-bundle.json).' >&2
    exit 1
  fi
fi
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo 'OPENAI_API_KEY is required in the machine environment.' >&2; exit 1; }
[[ -d "${FRED_DIR:-../fred}/deploy/charts/fred" ]] || {
  echo "FRED_DIR=${FRED_DIR:-../fred} must point to a Fred checkout with its Helm chart." >&2
  exit 1
}
# Everything a fresh machine lacks is reported here, before anything is created.
missing=()
command -v kubectl >/dev/null || missing+=('kubectl: https://kubernetes.io/docs/tasks/tools/')
command -v k3d >/dev/null || missing+=('k3d: https://k3d.io/#installation')
command -v helm >/dev/null || missing+=('helm: https://helm.sh/docs/intro/install/')
if ! command -v docker >/dev/null; then
  missing+=('docker: https://docs.docker.com/engine/install/')
elif ! docker info >/dev/null 2>&1; then
  missing+=('a running Docker daemon your user may use (docker group: sudo usermod -aG docker "$USER", then log in again)')
elif ! docker buildx version >/dev/null 2>&1; then
  missing+=("docker buildx, Fred's images need BuildKit (Ubuntu: sudo apt install docker-buildx)")
fi
if (( ${#missing[@]} )); then
  printf 'Missing prerequisites:\n' >&2; printf '  - %s\n' "${missing[@]}" >&2; exit 1
fi
# The ZITADEL browser client only accepts this port; a rerun finds it held by the cluster itself.
if command -v ss >/dev/null && ss -ltnH "sport = :$port" | grep -q . \
  && ! docker ps --format '{{.Names}}' | grep -qx "k3d-${K3D_CLUSTER:-fred}-serverlb"; then
  echo "Port $port is already in use; free it (ss -ltnp 'sport = :$port' shows who holds it)." >&2
  exit 1
fi

"$python" bin/k3d-zitadel-cloud.py prepare

make k3d-up \
  K3D_HOST_PORT_FRONTEND="$port" \
  K3D_KEYCLOAK_ENABLED=false \
  K3D_TEMPORAL_UI_ENABLED=false

patch="$(mktemp)"
chart_work="$(mktemp -d)"
trap 'rm -f "$patch"; rm -rf "$chart_work"' EXIT
"$python" bin/k3d-zitadel-cloud.py secret-patch >"$patch"
kubectl patch secret fred-secrets -n "${K3D_NAMESPACE:-fred}" --type merge --patch-file "$patch" >/dev/null
rm -f "$patch"

"$python" bin/k3d-zitadel-cloud.py prepare-chart \
  --chart "${FRED_CHART:-${FRED_DIR:-../fred}/deploy/charts/fred}" \
  --output "$chart_work/fred"
export FRED_CHART="$chart_work/fred"
export FRED_VALUES="k3d-apps/fred/values.yaml docker/zitadel/state/cloud-values.json"
export K3D_IDP=zitadel-cloud
bin/k3d-fred-deploy.sh
