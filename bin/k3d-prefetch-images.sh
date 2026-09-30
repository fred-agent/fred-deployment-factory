#!/usr/bin/env bash
set -Eeuo pipefail

# Put images into every node of a k3d cluster, downloading each one at most once.
#
#   bin/k3d-prefetch-images.sh <cluster> <image>...
#
# An image already in every node is left alone: no download, no copy. An image
# missing from a node is taken from the host's Docker cache, pulled into it
# first only if absent, then copied into the nodes that lack it. Every node is
# checked afterwards; the script fails if one still lacks an image.
#
# Images are exported for the host platform only: a plain `docker save` of a
# multi-platform image writes an index naming platforms never downloaded, and
# the node rejects the whole archive. With Docker's containerd image store, an
# image can also be impossible to export (a layer it shares with another image
# was unpacked without its compressed blob). Such an image is left to the
# cluster, which pulls it itself when a pod needs it: slower, never broken.
#
# Environment: IMAGE_PULL_RETRIES (default 3), IMAGE_PULL_RETRY_DELAY (default 5s).

c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_info='\033[0;36m'; c_reset='\033[0m'
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
info() { printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }

[[ $# -ge 2 ]] || fail "usage: $0 <cluster> <image>..."
cluster="$1"; shift
images=("$@")
retries="${IMAGE_PULL_RETRIES:-3}"
retry_delay="${IMAGE_PULL_RETRY_DELAY:-5}"

# The name containerd records for an image reference: docker.io/library/alpine:latest
# for `alpine`, unchanged for a reference that already names its registry.
normalize() {
  local ref="$1" first="${1%%/*}"
  if [[ "$ref" != */* ]]; then
    ref="docker.io/library/$ref"
  elif [[ "$first" != *.* && "$first" != *:* && "$first" != localhost ]]; then
    ref="docker.io/$ref"
  fi
  local last="${ref##*/}"
  [[ "$last" == *:* || "$ref" == *@* ]] || ref="$ref:latest"
  printf '%s\n' "$ref"
}

# Images of `images` that node $1 lacks, one per line.
missing_in_node() {
  local present image
  present="$(docker exec "$1" ctr -n k8s.io images ls -q)"
  for image in "${images[@]}"; do
    grep -qxF "$(normalize "$image")" <<<"$present" || printf '%s\n' "$image"
  done
}

pull() {
  local image="$1" attempt=1
  until docker pull --quiet --platform "$platform" "$image" >/dev/null; do
    [[ $attempt -lt $retries ]] || fail "pull $image failed after $attempt attempt(s)"
    warn "pull $image failed (attempt $attempt/$retries), retrying in ${retry_delay}s"
    sleep "$retry_delay"
    attempt=$((attempt + 1))
  done
}

mapfile -t nodes < <(docker ps --filter "label=k3d.cluster=$cluster" \
  --format '{{.Names}} {{.Label "k3d.role"}}' | awk '$2 == "server" || $2 == "agent" {print $1}')
[[ ${#nodes[@]} -gt 0 ]] || fail "no running node found for k3d cluster '$cluster'"

platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"

declare -A lacking=()   # image -> nodes lacking it, space-separated
for node in "${nodes[@]}"; do
  while IFS= read -r image; do
    [[ -n "$image" ]] && lacking[$image]+="$node "
  done < <(missing_in_node "$node")
done

if [[ ${#lacking[@]} -eq 0 ]]; then
  ok "All ${#images[@]} images already in every node; nothing downloaded"
  exit 0
fi
info "${#lacking[@]} of ${#images[@]} images to copy into the cluster (platform $platform)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
left_to_cluster=()
for image in "${!lacking[@]}"; do
  if docker image inspect --platform "$platform" "$image" >/dev/null 2>&1; then
    origin="host cache"
  else
    pull "$image"
    origin="downloaded"
  fi
  if ! docker save --platform "$platform" -o "$tmp/image.tar" "$image" 2>"$tmp/save.err"; then
    warn "$image cannot be exported from Docker ($(head -n1 "$tmp/save.err")); the cluster pulls it itself"
    left_to_cluster+=("$(normalize "$image")")
    continue
  fi
  for node in ${lacking[$image]}; do
    docker exec -i "$node" ctr -n k8s.io images import - <"$tmp/image.tar" >/dev/null \
      || fail "import of $image into $node failed"
  done
  rm -f "$tmp/image.tar"
  ok "$image ($origin) -> ${lacking[$image]% }"
done

for node in "${nodes[@]}"; do
  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    printf '%s\n' "${left_to_cluster[@]}" | grep -qxF "$(normalize "$image")" \
      || fail "$node still lacks $image after import"
  done < <(missing_in_node "$node")
done
ok "Every node has every image$([[ ${#left_to_cluster[@]} -eq 0 ]] || echo " but ${#left_to_cluster[@]} left to the cluster")"
