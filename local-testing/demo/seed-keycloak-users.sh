#!/usr/bin/env bash
# Populates Keycloak with the 15 named identities the demo bundle expects
# (alice, bob, marc, priya, ...), one command instead of hand-running
# keycloak-add-user.sh 15 times. The mirror of bench's `--count`/`--prefix`
# bulk mode, but for a fixed cast of named personas instead of synthetic
# sequential ones — so it reads the username list from `fred`'s own fixture
# (the source of truth for the demo cast, see ../demo/README.md) instead of
# duplicating it here.
#
# Usage:
#   ./seed-keycloak-users.sh                  # expects a sibling ../../../fred checkout
#   SWIFT_SRC=/path/to/fred ./seed-keycloak-users.sh
#
# Elaborates on keycloak-add-user.sh (single-user mode) rather than
# reimplementing it — for 15 users the per-user kcadm round-trip is fine;
# only the 3000-user bench scenario needs the bulk partialImport path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../scripts/keycloak-lib.sh

# Assumes `fred` and `fred-deployment-factory` are sibling checkouts under the
# same parent directory (three levels up from here: demo/ -> local-testing/ ->
# fred-deployment-factory/ -> parent). Same SWIFT_SRC convention as the
# Makefile's own check-swift-src/sync-openfga-model (Makefile:522) — override
# with SWIFT_SRC=/path/to/fred if your checkout isn't laid out that way.
SWIFT_SRC="${SWIFT_SRC:-../../../fred}"
USERS_JSON_REL="apps/control-plane-backend/tests/fixtures/import_export/demo_provisioning/users.json"
echo "Looking for the demo fixture at: $SWIFT_SRC/$USERS_JSON_REL"
require_swift_path "$SWIFT_SRC" "$USERS_JSON_REL" "$0"
USERS_JSON="$SWIFT_SRC/$USERS_JSON_REL"

usernames=$(jq -r '.[].username' "$USERS_JSON")
total=$(echo "$usernames" | wc -l)
created=0
skipped=0
failed=0

echo "Seeding $total Keycloak identities from $USERS_JSON ..."
for username in $usernames; do
  if output=$(../scripts/keycloak-add-user.sh "$username" 2>&1); then
    created=$((created + 1))
    echo "  created: $username"
  elif echo "$output" | grep -q "already exists"; then
    skipped=$((skipped + 1))
    echo "  already exists: $username"
  else
    failed=$((failed + 1))
    echo "  FAILED: $username" >&2
    echo "$output" | sed 's/^/    /' >&2
  fi
done

echo
echo "Done: $created created, $skipped already existed, $failed failed (of $total)."

if [ "$failed" -gt 0 ]; then
  exit 1
fi
