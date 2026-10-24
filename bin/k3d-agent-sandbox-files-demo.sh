#!/usr/bin/env bash
# Copyright Thales 2026
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster="${K3D_CLUSTER:?Set K3D_CLUSTER}"
context="${KUBE_CONTEXT:-k3d-$cluster}"
fred_repo="$(realpath "${FRED_REPO:?Set FRED_REPO to the Fred checkout}")"
model_key_file="${MODEL_API_KEY_FILE:?Set MODEL_API_KEY_FILE to a local model API key file}"
cache="$repo_root/.cache/agent-sandbox/$cluster"
demo="$cache/files-demo"
source="$repo_root/k3d/agent-sandbox/files-demo"

kube() { kubectl --context "$context" "$@"; }
require_file() { [[ -s "$1" ]] || { printf 'Missing %s\n' "$1" >&2; exit 1; }; }
umask 077
mkdir -p "$demo"
require_file "$cache/python-image"
require_file "$model_key_file"
require_file "$fred_repo/deploy/sandbox/agent-sandbox-files.yaml"
require_file "$fred_repo/libs/fred-runtime/fred_runtime/skills/summarize-document/SKILL.md"
python3 -c 'import yaml' >/dev/null || { printf 'Python PyYAML is required\n' >&2; exit 1; }
kube get namespace fred-sandbox >/dev/null
kube get namespace fred >/dev/null
image="$(cat "$cache/python-image")"
[[ "$image" =~ ^[a-z0-9.-]+:5000/python@sha256:[a-f0-9]{64}$ ]] || {
  printf 'Unapproved sandbox image reference\n' >&2; exit 1;
}

trust_changed=false
if [[ ! -s "$demo/gateway-ca.crt" || ! -s "$demo/gateway-ca.key" ]] || \
    ! openssl x509 -in "$demo/gateway-ca.crt" -checkend 2592000 -noout >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$demo/gateway-ca.key" -out "$demo/gateway-ca.crt" \
    -subj '/CN=Fred k3d file gateway CA' >/dev/null 2>&1
  trust_changed=true
fi
if [[ "$trust_changed" == true || ! -s "$demo/gateway.crt" || ! -s "$demo/gateway.key" ]] || \
    ! openssl x509 -in "$demo/gateway.crt" -checkend 604800 -noout >/dev/null 2>&1 || \
    ! openssl verify -CAfile "$demo/gateway-ca.crt" "$demo/gateway.crt" >/dev/null 2>&1; then
  openssl req -newkey rsa:2048 -nodes -keyout "$demo/gateway.key" \
    -out "$demo/gateway.csr" \
    -subj '/CN=fred-sandbox-file-gateway.fred.svc.cluster.local' >/dev/null 2>&1
  printf 'subjectAltName=DNS:fred-sandbox-file-gateway.fred.svc.cluster.local\nextendedKeyUsage=serverAuth\n' \
    > "$demo/gateway.ext"
  openssl x509 -req -in "$demo/gateway.csr" -CA "$demo/gateway-ca.crt" \
    -CAkey "$demo/gateway-ca.key" -CAcreateserial -out "$demo/gateway.crt" \
    -days 30 -extfile "$demo/gateway.ext" >/dev/null 2>&1
  trust_changed=true
fi
if [[ ! -s "$demo/file-gateway-secret" ]]; then
  openssl rand -hex 32 > "$demo/file-gateway-secret"
fi

for namespace in fred fred-sandbox-system; do
  kube -n "$namespace" create secret generic fred-sandbox-file-gateway \
    --from-file=secret="$demo/file-gateway-secret" --dry-run=client -o yaml | kube apply -f -
done
kube -n fred create secret tls fred-sandbox-file-gateway-tls \
  --cert="$demo/gateway.crt" --key="$demo/gateway.key" \
  --dry-run=client -o yaml | kube apply -f -
kube -n fred create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY="$model_key_file" --dry-run=client -o yaml | kube apply -f -
for namespace in fred-sandbox-system fred-sandbox-csi; do
  kube -n "$namespace" create configmap real-kflow-gateway-ca \
    --from-file=ca.crt="$demo/gateway-ca.crt" --dry-run=client -o yaml | kube apply -f -
done
kube -n fred create configmap fred-sandbox-file-gateway-code \
  --from-file=cluster-file-gateway.py="$source/file-gateway.py" \
  --dry-run=client -o yaml | kube apply -f -
kube -n fred create configmap fred-platform-skills-source-code \
  --from-file=skill-webdav-server.py="$source/skill-webdav-server.py" \
  --dry-run=client -o yaml | kube apply -f -
kube -n fred create configmap fred-platform-summarize-document \
  --from-file=SKILL.md="$fred_repo/libs/fred-runtime/fred_runtime/skills/summarize-document/SKILL.md" \
  --dry-run=client -o yaml | kube apply -f -
kube -n fred create configmap fred-platform-tabular-evidence \
  --from-file=SKILL.md="$source/tabular-evidence/SKILL.md" \
  --from-file=analyze.py="$source/tabular-evidence/analyze.py" \
  --dry-run=client -o yaml | kube apply -f -

sed "s|REPLACE_WITH_APPROVED_PYTHON_IMAGE_DIGEST|$image|g" \
  "$source/file-gateway.yaml" | kube apply -f -
if [[ "$trust_changed" == true ]]; then
  kube -n fred rollout restart deployment/fred-sandbox-file-gateway
fi
sed "s|REPLACE_WITH_APPROVED_PYTHON_IMAGE_DIGEST|$image|g" \
  "$source/skills-source.yaml" | kube apply -f -
kube -n fred rollout status deployment/fred-sandbox-file-gateway --timeout=180s
kube -n fred rollout status deployment/fred-platform-skills-source --timeout=180s

SANDBOX_CSI_VALUES="$source/rclone-csi-ca-values.yaml" \
  K3D_CLUSTER="$cluster" KUBE_CONTEXT="$context" FRED_REPO="$fred_repo" \
  "$repo_root/bin/k3d-agent-sandbox.sh" csi
if [[ "$trust_changed" == true ]]; then
  kube -n fred-sandbox-csi rollout restart daemonset/csi-rclone-node deployment/csi-rclone-controller
  kube -n fred-sandbox-csi rollout status daemonset/csi-rclone-node --timeout=180s
  kube -n fred-sandbox-csi rollout status deployment/csi-rclone-controller --timeout=180s
fi
kube apply -f "$fred_repo/deploy/sandbox/rclone-webdav-storageclass.yaml"
kube apply -f "$fred_repo/deploy/sandbox/file-mount-rbac.yaml"
cat > "$demo/skills-rclone.conf" <<'EOF'
[fred-platform-skills]
type = webdav
url = http://fred-platform-skills-source.fred.svc.cluster.local:8080/
vendor = other
EOF
kube -n fred-sandbox create secret generic fred-platform-skills \
  --from-literal=remote=fred-platform-skills --from-literal=remotePath=/ \
  --from-file=configData="$demo/skills-rclone.conf" \
  --dry-run=client -o yaml | kube apply -f -
kube apply -f "$source/platform-skills-pvc.yaml"
kube -n fred-sandbox wait pvc/fred-platform-skills --for=jsonpath='{.status.phase}'=Bound --timeout=180s
python3 - "$fred_repo/deploy/sandbox/agent-sandbox-files.yaml" "$demo/template.yaml" "$image" <<'RENDER_TEMPLATE'
from pathlib import Path
import sys
import yaml
objects = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
template, pool = objects
template['metadata']['name'] = 'fred-code-files-skills'
pool['metadata']['name'] = 'fred-code-files-skills'
pool['spec']['sandboxTemplateRef']['name'] = 'fred-code-files-skills'
spec = template['spec']['podTemplate']['spec']
container = spec['containers'][0]
container['image'] = sys.argv[3]
container['volumeMounts'].append({'name': 'skills', 'mountPath': '/skills', 'readOnly': True})
spec['volumes'].append({'name': 'skills', 'persistentVolumeClaim': {
    'claimName': 'fred-platform-skills', 'readOnly': True}})
Path(sys.argv[2]).write_text(yaml.safe_dump_all(objects, sort_keys=False))
RENDER_TEMPLATE
kube apply -f "$demo/template.yaml"
kube -n fred-sandbox-system patch deployment fred-sandbox-broker \
  --type=strategic --patch-file "$source/broker-files.patch.yaml"
kube -n fred-sandbox-system rollout status deployment/fred-sandbox-broker --timeout=180s

K3D_CLUSTER="$cluster" "$repo_root/bin/k3d-agent-sandbox.sh" render-fred-values
python3 - "$repo_root/k3d-apps/fred/sandbox-secondary.yaml" "$cache/fred-values.yaml" "$demo/fred-values.yaml" <<'PY'
import sys
from pathlib import Path
import yaml
agents = yaml.safe_load(Path(sys.argv[1]).read_text())['applications']['fred-agents']['extraEnvVars']
base = yaml.safe_load(Path(sys.argv[2]).read_text())['applications']
secret = {'name': 'fred-sandbox-file-gateway', 'key': 'secret', 'optional': False}
agents += [
    {'name': 'FRED_SANDBOX_FILE_GATEWAY_SECRET', 'valueFrom': {'secretKeyRef': secret}},
    {'name': 'FRED_SANDBOX_FILE_MOUNTS_ENABLED', 'value': 'true'},
]
env = {'name': 'SANDBOX_FILE_GATEWAY_SECRET', 'valueFrom': {'secretKeyRef': secret}}
values = {'applications': {'fred-agents': {'extraEnvVars': agents}}}
for app in ('knowledge-flow-backend', 'knowledge-flow-worker'):
    values['applications'][app] = {'extraEnvVars': base[app]['extraEnvVars'] + [env]}
Path(sys.argv[3]).write_text(yaml.safe_dump(values, sort_keys=False))
PY
printf 'Sandbox file demo ready. Deploy Fred with VALUES="k3d-apps/fred/sandbox-secondary.yaml %s"\n' "$demo/fred-values.yaml"
