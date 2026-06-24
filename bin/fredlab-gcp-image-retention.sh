#!/usr/bin/env bash
set -Eeuo pipefail

# Cap Artifact Registry + Cloud Build storage growth. Idempotent and replayable.
#
#   1. Artifact Registry cleanup policy on the image repo:
#        keep    the most recent KEEP_COUNT versions of every package
#        delete  UNTAGGED versions older than UNTAGGED_OLDER_THAN
#        delete  TAGGED   versions older than TAGGED_OLDER_THAN
#      Keep rules win over Delete, so the newest builds (including whatever is
#      currently deployed) are never pruned.
#   2. Lifecycle rule on the Cloud Build staging bucket (the source tarballs
#      `gcloud builds submit` uploads on every build).
#
# Safe by default: the cleanup policy is written in DRY-RUN mode (it logs what it
# WOULD delete and removes nothing) unless --apply is given.

usage() {
  cat <<'EOF'
fredlab-gcp-image-retention.sh — cap Artifact Registry + Cloud Build storage

USAGE
  bin/fredlab-gcp-image-retention.sh [--apply] [-h|--help]

WHAT IT DOES
  Sets an Artifact Registry cleanup policy on the image repo and a lifecycle rule
  on the Cloud Build staging bucket, so old images and build tarballs are pruned
  automatically. Idempotent — safe to re-run; re-applies the same policy.

  Cleanup policy (Keep wins over Delete — newest builds are always protected):
    keep    most recent KEEP_COUNT versions per package
    delete  UNTAGGED versions older than UNTAGGED_OLDER_THAN
    delete  TAGGED   versions older than TAGGED_OLDER_THAN

MODES
  (default)  DRY-RUN: writes the policy in dry-run mode (records what it WOULD
             delete to Cloud Logging, removes nothing) and skips the bucket
             change. Inspect, then re-run with --apply.
  --apply    LIVE: enables the cleanup policy (real deletions on AR's schedule)
             and applies the staging-bucket lifecycle rule.

ENV OVERRIDES (defaults in parentheses)
  PROJECT_ID           GCP project          (gcloud config project)
  REGION               AR repo location     (europe-west1)
  REPOSITORY           AR repository name    (fredlab-repo)
  KEEP_COUNT           versions to keep      (10)
  UNTAGGED_OLDER_THAN  untagged TTL          (3d)
  TAGGED_OLDER_THAN    tagged TTL            (30d)
  CLOUDBUILD_BUCKET    staging bucket        (<project>_cloudbuild)
  CLOUDBUILD_AGE_DAYS  staging tarball TTL   (14)

EXAMPLES
  bin/fredlab-gcp-image-retention.sh                 # preview (dry-run)
  bin/fredlab-gcp-image-retention.sh --apply         # enable for real
  KEEP_COUNT=20 TAGGED_OLDER_THAN=60d bin/fredlab-gcp-image-retention.sh --apply
EOF
}

APPLY=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --apply)   APPLY=1 ;;
  "")        : ;;
  *) echo "Unknown argument: $1" >&2; echo; usage; exit 1 ;;
esac

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
KEEP_COUNT="${KEEP_COUNT:-10}"
UNTAGGED_OLDER_THAN="${UNTAGGED_OLDER_THAN:-3d}"
TAGGED_OLDER_THAN="${TAGGED_OLDER_THAN:-30d}"
CLOUDBUILD_BUCKET="${CLOUDBUILD_BUCKET:-${PROJECT_ID}_cloudbuild}"
CLOUDBUILD_AGE_DAYS="${CLOUDBUILD_AGE_DAYS:-14}"

[[ -z "$PROJECT_ID" ]] && { echo "No project set (gcloud config or PROJECT_ID)." >&2; exit 1; }

echo "Project:            ${PROJECT_ID}"
echo "AR repository:      ${REGION}/${REPOSITORY}"
echo "Keep most recent:   ${KEEP_COUNT} versions/package"
echo "Delete untagged >:  ${UNTAGGED_OLDER_THAN}"
echo "Delete tagged   >:  ${TAGGED_OLDER_THAN}"
echo "Cloud Build bucket: gs://${CLOUDBUILD_BUCKET} (age ${CLOUDBUILD_AGE_DAYS}d)"
echo "Mode:               $([[ "$APPLY" == "1" ]] && echo APPLY || echo DRY-RUN)"
echo

POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
cat > "$POLICY_FILE" <<EOF
[
  { "name": "keep-recent", "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": ${KEEP_COUNT}} },
  { "name": "delete-untagged", "action": {"type": "Delete"},
    "condition": {"tagState": "UNTAGGED", "olderThan": "${UNTAGGED_OLDER_THAN}"} },
  { "name": "delete-old-tagged", "action": {"type": "Delete"},
    "condition": {"tagState": "TAGGED", "olderThan": "${TAGGED_OLDER_THAN}"} }
]
EOF

if [[ "$APPLY" == "1" ]]; then
  echo "Applying Artifact Registry cleanup policy (LIVE)..."
  gcloud artifacts repositories set-cleanup-policies "${REPOSITORY}" \
    --location="${REGION}" --policy="${POLICY_FILE}" --no-dry-run

  echo "Applying Cloud Build staging bucket lifecycle..."
  if gcloud storage buckets describe "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
    LC_FILE="$(mktemp)"
    printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":%s}}]}\n' "${CLOUDBUILD_AGE_DAYS}" > "$LC_FILE"
    gcloud storage buckets update "gs://${CLOUDBUILD_BUCKET}" --lifecycle-file="${LC_FILE}"
    rm -f "$LC_FILE"
  else
    echo "  (bucket gs://${CLOUDBUILD_BUCKET} not found — skipping. Regional builds may use a"
    echo "   different staging bucket; set CLOUDBUILD_BUCKET to the real name and re-run.)"
  fi
  echo
  echo "Done. Inspect the policy anytime with:"
  echo "  gcloud artifacts repositories describe ${REPOSITORY} --location=${REGION}"
else
  echo "Setting Artifact Registry cleanup policy in DRY-RUN (deletes nothing)..."
  gcloud artifacts repositories set-cleanup-policies "${REPOSITORY}" \
    --location="${REGION}" --policy="${POLICY_FILE}" --dry-run
  echo
  echo "Dry-run set: the policy now records what it WOULD delete to Cloud Logging."
  echo "Review, then re-run with --apply to enable real deletions + the bucket rule:"
  echo "  bin/fredlab-gcp-image-retention.sh --apply"
fi
