#!/usr/bin/env bash
set -euo pipefail

CHECKPOINT_NAME="${1:?Usage: $0 <checkpoint-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-${REPO_DIR}/checkpoints}"
CHECKPOINT_DIR="${CHECKPOINT_BASE_DIR}/${CHECKPOINT_NAME}"

VOLUMES=(
    "postgres_vol-postgres-data"
    "minio_vol-minio-data"
    "clickhouse_vol-clickhouse-data"
    "clickhouse_vol-clickhouse-logs"
    "opensearch_vol-opensearch-data"
    "opensearch_vol-opensearch-certs"
    "opensearch_vol-opensearch-security"
    "opensearch_vol-opensearch-dashboards"
    "langfuse_langfuse_redis_data"
    "prometheus_vol-prometheus-data"
    "grafana_vol-grafana-data"
)

if [ -d "$CHECKPOINT_DIR" ]; then
    echo "ERROR: Checkpoint '${CHECKPOINT_NAME}' already exists at ${CHECKPOINT_DIR}"
    echo "Delete it first with: make checkpoint-delete NAME=${CHECKPOINT_NAME}"
    exit 1
fi

echo "=== Checkpoint Save: ${CHECKPOINT_NAME} ==="
echo ""
echo "[1/3] Stopping Docker stack for consistent snapshot..."
cd "$REPO_DIR"
make all-down 2>&1 | sed 's/^/  /'

mkdir -p "$CHECKPOINT_DIR"

echo ""
echo "[2/3] Saving volumes..."

SAVED=0
SKIPPED=0

for vol in "${VOLUMES[@]}"; do
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "  [SKIP] ${vol} (volume not found)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    archive="${CHECKPOINT_DIR}/${vol}.tar.gz"
    printf "  [SAVE] %-45s " "${vol}..."
    docker run --rm \
        -v "${vol}:/data:ro" \
        -v "${CHECKPOINT_DIR}:/backup" \
        alpine \
        tar czf "/backup/${vol}.tar.gz" -C /data .
    size=$(du -sh "$archive" | cut -f1)
    echo "done (${size})"
    SAVED=$((SAVED + 1))
done

cat > "${CHECKPOINT_DIR}/checkpoint.json" <<EOF
{
  "name": "${CHECKPOINT_NAME}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname)",
  "volumes_saved": ${SAVED}
}
EOF

total_size=$(du -sh "$CHECKPOINT_DIR" | cut -f1)

echo ""
echo "[3/3] Saved: ${SAVED} volumes, Skipped: ${SKIPPED} volumes — ${total_size} total"
echo ""
echo "Checkpoint '${CHECKPOINT_NAME}' saved to ${CHECKPOINT_DIR}"
echo ""
echo "Restart the stack:                  make docker-up"
echo "Restore this checkpoint later:      make checkpoint-restore NAME=${CHECKPOINT_NAME}"
echo "Restore and restart in one shot:    make docker-restart-from-checkpoint NAME=${CHECKPOINT_NAME}"
