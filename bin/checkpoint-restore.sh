#!/usr/bin/env bash
set -euo pipefail

CHECKPOINT_NAME="${1:?Usage: $0 <checkpoint-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-${REPO_DIR}/checkpoints}"
CHECKPOINT_DIR="${CHECKPOINT_BASE_DIR}/${CHECKPOINT_NAME}"

if [ ! -d "$CHECKPOINT_DIR" ]; then
    echo "ERROR: Checkpoint '${CHECKPOINT_NAME}' not found at ${CHECKPOINT_DIR}"
    echo ""
    echo "Available checkpoints:"
    if [ -d "$CHECKPOINT_BASE_DIR" ] && [ -n "$(ls -A "$CHECKPOINT_BASE_DIR" 2>/dev/null)" ]; then
        ls "$CHECKPOINT_BASE_DIR" | sed 's/^/  /'
    else
        echo "  (none)"
    fi
    exit 1
fi

if [ ! -f "${CHECKPOINT_DIR}/checkpoint.json" ]; then
    echo "ERROR: Invalid checkpoint directory — missing checkpoint.json"
    exit 1
fi

echo "=== Checkpoint Restore: ${CHECKPOINT_NAME} ==="
echo ""

if command -v jq >/dev/null 2>&1; then
    created_at=$(jq -r '.created_at // "?"' "${CHECKPOINT_DIR}/checkpoint.json")
    host=$(jq -r '.host // "?"' "${CHECKPOINT_DIR}/checkpoint.json")
    volumes_saved=$(jq -r '.volumes_saved // "?"' "${CHECKPOINT_DIR}/checkpoint.json")
    echo "  Created at   : ${created_at}"
    echo "  Host         : ${host}"
    echo "  Volumes saved: ${volumes_saved}"
fi

size=$(du -sh "$CHECKPOINT_DIR" | cut -f1)
echo "  Size         : ${size}"
echo ""
echo "WARNING: This will STOP the stack and REPLACE all current data with the checkpoint."
echo ""
read -p "Continue? [y/N] " -r
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

cd "$REPO_DIR"

echo ""
echo "[1/3] Stopping and wiping Docker stack..."
make docker-wipe 2>&1 | sed 's/^/  /'

echo ""
echo "[2/3] Restoring volumes from checkpoint..."

RESTORED=0

for archive in "${CHECKPOINT_DIR}"/*.tar.gz; do
    [ -f "$archive" ] || continue
    vol_name="$(basename "$archive" .tar.gz)"

    printf "  [RESTORE] %-45s " "${vol_name}..."
    docker volume create "$vol_name" >/dev/null
    docker run --rm \
        -v "${vol_name}:/data" \
        -v "${CHECKPOINT_DIR}:/backup:ro" \
        alpine \
        tar xzf "/backup/${vol_name}.tar.gz" -C /data
    echo "done"
    RESTORED=$((RESTORED + 1))
done

echo ""
echo "[3/3] Restored ${RESTORED} volumes from checkpoint '${CHECKPOINT_NAME}'."
echo ""
echo "Checkpoint restored. Start the stack with:"
echo "  make docker-up"
