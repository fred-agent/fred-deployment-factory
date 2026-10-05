#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare local Fred images, then deploy the installation described by Helmfile.
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
trap 'printf "Deployment failed at line %s\n" "$LINENO" >&2' ERR
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
mode="${1:-deploy}"
[[ "$mode" == deploy || "$mode" == validate ]] || fail "usage: $0 [deploy|validate]"
for tool in helm helmfile python3; do command -v "$tool" >/dev/null || fail "$tool is required"; done
export FRED_DIR="$(realpath -e "${FRED_DIR:-../fred}")"
export FRED_VALUES="$(realpath -e "${FRED_VALUES:-k3d-apps/fred/values.yaml}")"
[[ -f "$FRED_DIR/deploy/charts/fred/Chart.yaml" ]] || fail "Fred chart missing in $FRED_DIR"
[[ -f "$FRED_VALUES" ]] || fail "installation values missing: $FRED_VALUES"
if [[ -n "${FRED_IMAGE_VALUES:-}" ]]; then
  export FRED_IMAGE_VALUES="$(realpath -e "$FRED_IMAGE_VALUES")"
  [[ -f "$FRED_IMAGE_VALUES" ]] || fail "image values missing: $FRED_IMAGE_VALUES"
fi
export K3D_CLUSTER="${K3D_CLUSTER:-fred}" K3D_NAMESPACE="${K3D_NAMESPACE:-fred}" FRED_RELEASE="${FRED_RELEASE:-fred-app}"
export KUBE_CONTEXT="k3d-$K3D_CLUSTER"
state=(helmfile --file "$here/helmfile.yaml.gotmpl")
validate() {
  # Helm lint retains null deletion markers; template/sync validate the coalesced schema.
  "${state[@]}" lint --skip-deps --args "--skip-schema-validation" >/dev/null
  "${state[@]}" template --skip-deps >/dev/null
}
validate
if [[ "$mode" == validate ]]; then
  printf 'Helm lint/render passed (%s). No build or cluster mutation.\n' "${FRED_IMAGE_VALUES:-installation values only; no prepared image overrides}"
  exit 0
fi
for tool in docker kubectl make; do command -v "$tool" >/dev/null || fail "$tool is required"; done
kubectl --context "$KUBE_CONTEXT" -n "$K3D_NAMESPACE" get secret fred-secrets -o name >/dev/null
python3 "$FRED_DIR/deploy/k3d/build-images.py"
export FRED_IMAGE_VALUES="$FRED_DIR/.cache/k3d/images.json"
validate
mapfile -t images < "$FRED_DIR/.cache/k3d/images.txt"
"$here/bin/k3d-prefetch-images.sh" "$K3D_CLUSTER" "${images[@]}"
"$here/bin/k3d-helm-recover.sh" "$FRED_RELEASE" "$K3D_NAMESPACE" 1200s
bash "$FRED_DIR/deploy/k3d/configure.sh" key
"${state[@]}" sync --skip-deps
bash "$FRED_DIR/deploy/k3d/configure.sh" finish
