#!/usr/bin/env bash
#
# kea-data-restore.sh — restore the "data" topic (migration step 2).
#
# Mirrors the local dump back into object storage, KEY-FOR-KEY, creating buckets
# if needed. Run it after `make docker-up`, before the metadata import. Never
# touches Postgres — the metadata import (step 3) is what repopulates fred_kea.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${DATA_DIR:-${REPO_DIR}/dumps/data}"
NETWORK="${NETWORK:-fred-shared-network}"
S3_ENDPOINT="${S3_ENDPOINT:-http://app-seaweedfs:8333}"
S3_KEY="${S3_KEY:-admin}"
S3_SECRET="${S3_SECRET:-Azerty123_}"
MC_IMAGE="${MC_IMAGE:-minio/mc}"

if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ]; then
    echo "ERROR: no data dump at ${DATA_DIR}. Run 'make kea-data-dump' first." >&2
    exit 1
fi

echo "=== Data restore (keys verbatim) ==="
echo "Mirroring ${DATA_DIR} → ${S3_ENDPOINT} ..."
docker run --rm --network "$NETWORK" \
    -e S3_ENDPOINT="$S3_ENDPOINT" -e S3_KEY="$S3_KEY" -e S3_SECRET="$S3_SECRET" \
    -v "${DATA_DIR}:/dump" \
    --entrypoint sh "$MC_IMAGE" -c '
        set -e
        # The mc image is minimal (no basename) — derive bucket name with pure shell.
        mc alias set dst "$S3_ENDPOINT" "$S3_KEY" "$S3_SECRET" >/dev/null
        found=0
        for d in /dump/*/; do
            [ -d "$d" ] || continue
            found=1
            b="${d%/}"; b="${b##*/}"
            printf "  [restore] %s\n" "$b"
            mc mb --ignore-existing "dst/$b" >/dev/null 2>&1 || true
            mc mirror --overwrite "/dump/$b" "dst/$b"
        done
        [ "$found" = "1" ] || echo "  (dump folder is empty)"
    '

echo ""
echo "✓ data restored into object storage (buckets created as needed)."
