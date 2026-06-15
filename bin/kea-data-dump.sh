#!/usr/bin/env bash
#
# kea-data-dump.sh — capture the "data" migration topic.
#
# Mirrors every kea-* object-storage bucket to a local folder, KEY-FOR-KEY (no
# key rewriting). The document_uid prefix is the only join back to metadata, so
# keys must be preserved verbatim. This is the LOCAL rehearsal of the production
# `mc mirror` step (MIGR-06). Run it before `make docker-wipe`.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${DATA_DIR:-${REPO_DIR}/dumps/data}"
NETWORK="${NETWORK:-fred-shared-network}"
S3_ENDPOINT="${S3_ENDPOINT:-http://app-seaweedfs:8333}"
S3_KEY="${S3_KEY:-admin}"
S3_SECRET="${S3_SECRET:-Azerty123_}"
BUCKET_PREFIX="${BUCKET_PREFIX:-kea}"
MC_IMAGE="${MC_IMAGE:-minio/mc}"

mkdir -p "$DATA_DIR"

echo "=== Data dump (buckets '${BUCKET_PREFIX}*', keys verbatim) ==="
echo "Mirroring from ${S3_ENDPOINT} → ${DATA_DIR} ..."
docker run --rm --network "$NETWORK" \
    -e S3_ENDPOINT="$S3_ENDPOINT" -e S3_KEY="$S3_KEY" -e S3_SECRET="$S3_SECRET" \
    -e BUCKET_PREFIX="$BUCKET_PREFIX" \
    -v "${DATA_DIR}:/dump" \
    --entrypoint sh "$MC_IMAGE" -c '
        set -e
        # The mc image is minimal (no awk/grep) — discover buckets with pure shell.
        mc alias set src "$S3_ENDPOINT" "$S3_KEY" "$S3_SECRET" >/dev/null
        buckets=$(mc ls src | while IFS= read -r line; do
            b="${line##* }"; b="${b%/}"
            case "$b" in "${BUCKET_PREFIX}"*) printf "%s\n" "$b" ;; esac
        done)
        if [ -z "$buckets" ]; then echo "  (no ${BUCKET_PREFIX}* buckets found — did you load documents?)"; exit 0; fi
        for b in $buckets; do
            printf "  [dump] %s\n" "$b"
            mc mirror --overwrite "src/$b" "/dump/$b"
        done
    '

echo ""
total="$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo '?')"
echo "✓ data dump complete (${total}) → ${DATA_DIR}"
