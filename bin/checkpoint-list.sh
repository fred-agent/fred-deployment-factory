#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-${REPO_DIR}/checkpoints}"

if [ ! -d "$CHECKPOINT_BASE_DIR" ] || [ -z "$(ls -A "$CHECKPOINT_BASE_DIR" 2>/dev/null)" ]; then
    echo "No checkpoints found in ${CHECKPOINT_BASE_DIR}"
    exit 0
fi

echo "Available checkpoints:"
echo ""
printf "  %-30s  %-25s  %-8s  %s\n" "NAME" "CREATED AT" "VOLUMES" "SIZE"
printf "  %-30s  %-25s  %-8s  %s\n" "------------------------------" "-------------------------" "-------" "----"

for checkpoint_dir in "${CHECKPOINT_BASE_DIR}"/*/; do
    [ -d "$checkpoint_dir" ] || continue
    name="$(basename "$checkpoint_dir")"

    created_at="?"
    volumes_saved="?"
    if [ -f "${checkpoint_dir}/checkpoint.json" ] && command -v jq >/dev/null 2>&1; then
        created_at=$(jq -r '.created_at // "?"' "${checkpoint_dir}/checkpoint.json")
        volumes_saved=$(jq -r '.volumes_saved // "?"' "${checkpoint_dir}/checkpoint.json")
    fi

    size=$(du -sh "$checkpoint_dir" 2>/dev/null | cut -f1 || echo "?")
    printf "  %-30s  %-25s  %-8s  %s\n" "$name" "$created_at" "$volumes_saved" "$size"
done

echo ""
