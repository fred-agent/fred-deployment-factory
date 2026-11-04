#!/usr/bin/env bash
set -Eeuo pipefail

# Free space where Docker keeps the k3d nodes, their images and volumes, checked
# before `make k3d-create` (so `make k3d-up`) and `make k3d-app`. Read-only: it
# names the cleanup commands and never runs them, since they act on the whole host.
#
#   K3D_DISK_FAIL_GB  stop under this many GiB free (default 10: under it OpenSearch,
#                     k3d/templates/opensearch.yaml, nears its index-creation block)
#   K3D_DISK_WARN_GB  warn under this many GiB free (default 30: an image is 1 to 3 GiB)

fail_gb="${K3D_DISK_FAIL_GB:-10}"
warn_gb="${K3D_DISK_WARN_GB:-30}"
root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "$root" && -d "$root" ]] || root=/
free_gb=$(( $(df -Pk "$root" | awk 'NR == 2 { print $4 }') / 1024 / 1024 ))

advice() {
  printf '%s\n' \
    "  Free space on the host, as you decide (they act on the whole machine):" \
    "    docker system df              what is reclaimable" \
    "    docker builder prune -a       the build cache" \
    "    docker image prune -a         images no container uses" \
    "  Never 'docker volume prune': it deletes the Docker Compose stack's data." >&2
}

if (( free_gb < fail_gb )); then
  printf '\033[1;31m[FAIL]\033[0m %s\n' "${free_gb} GiB free on $root (minimum ${fail_gb} GiB, K3D_DISK_FAIL_GB)." >&2
  advice
  exit 1
elif (( free_gb < warn_gb )); then
  printf '\033[1;33m[WARN]\033[0m %s\n' "${free_gb} GiB free on $root: under ${warn_gb} GiB (K3D_DISK_WARN_GB), image pulls may fill it." >&2
  advice
fi
