#!/usr/bin/env bash
set -euo pipefail

# Resolve this script's folder (so we can call siblings no matter where we run from)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# 1) Delete everything
"${SCRIPT_DIR}/ops-delete-all-indices.sh"

# 2) Recreate vector index (pass an optional index name as $1)
"${SCRIPT_DIR}/ops-create-vector-index.sh"

