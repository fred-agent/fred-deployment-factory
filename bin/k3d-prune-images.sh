#!/usr/bin/env bash
set -Eeuo pipefail

# Remove images from the host's Docker and from every node of a k3d cluster.
#
#   bin/k3d-prune-images.sh <cluster> <image>...
#
# bin/k3d-app.sh calls it with the images of an application's earlier builds,
# once the new ones are rolled out: each content-tagged build is a new image of
# several GiB, and left in place they fill the disk until BuildKit evicts its
# build cache and every build starts from scratch. A reference still tagged
# elsewhere only loses this tag; an image already gone is skipped.

c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_reset='\033[0m'
ok() { printf "%b[OK]%b %s\n" "$c_ok" "$c_reset" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$1"; }
fail() { printf "%b[FAIL]%b %s\n" "$c_err" "$c_reset" "$1" >&2; exit 1; }

[[ $# -ge 2 ]] || fail "usage: $0 <cluster> <image>..."
cluster="$1"; shift

# The name containerd records for an image reference (same rule as k3d-prefetch-images.sh).
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

mapfile -t nodes < <(docker ps --filter "label=k3d.cluster=$cluster" \
  --format '{{.Names}} {{.Label "k3d.role"}}' | awk '$2 == "server" || $2 == "agent" {print $1}')

for image in "$@"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    docker image rm "$image" >/dev/null || warn "$image could not be removed from Docker"
  fi
  for node in "${nodes[@]}"; do
    if docker exec "$node" ctr -n k8s.io images ls -q | grep -qxF "$(normalize "$image")"; then
      docker exec "$node" ctr -n k8s.io images rm "$(normalize "$image")" >/dev/null \
        || warn "$image could not be removed from $node"
    fi
  done
  ok "$image removed"
done
