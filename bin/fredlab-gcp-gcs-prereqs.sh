#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare the GCS prerequisites for Knowledge Flow's native GCS backends
# (content store + virtual filesystem) on GKE with Workload Identity / ADC.
#
# Knowledge Flow uses FOUR buckets (see docs/swift/platform/DEPLOYMENT_GUIDE_GKE.md):
#   content store -> <CONTENT_PREFIX>-documents / -objects / -files   (suffixed at runtime)
#   virtual fs    -> <FS_BUCKET>
# The Google service account gets roles/storage.objectAdmin on all of them, and
# the future Kubernetes service accounts are bound for Workload Identity.
#
# Idempotent and replayable: existing buckets/SA/bindings are reused, not recreated.

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
# Bucket region. Must match the GKE cluster region (fredlab-playground-gke is in
# europe-west9) so Knowledge Flow object I/O stays in-region — a bucket's location
# is immutable, so getting this right up front matters. Override REGION for other
# targets.
REGION="${REGION:-europe-west9}"
NAMESPACE="${NAMESPACE:-default}"

# Content store prefix (suffixed with -documents/-objects/-files) and VFS bucket.
# Defaults keep the project-scoped naming convention; the VFS default reuses the
# bucket created by earlier runs of this script.
CONTENT_PREFIX="${CONTENT_PREFIX:-${PROJECT_ID}-content}"
FS_BUCKET="${FS_BUCKET:-${PROJECT_ID}-knowledge-flow}"

GSA_NAME="${GSA_NAME:-fredlab-knowledge-flow-gcs}"
GSA_EMAIL="${GSA_EMAIL:-${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Space-separated list of Kubernetes service accounts allowed to impersonate the GSA.
KSA_NAMES="${KSA_NAMES:-knowledge-flow-backend knowledge-flow-worker}"

CONTENT_BUCKETS=("${CONTENT_PREFIX}-documents" "${CONTENT_PREFIX}-objects" "${CONTENT_PREFIX}-files")
BUCKETS=("${CONTENT_BUCKETS[@]}" "${FS_BUCKET}")

echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Content-store buckets: ${CONTENT_BUCKETS[*]}"
echo "Virtual-filesystem bucket: ${FS_BUCKET}"
echo "Google service account: ${GSA_EMAIL}"
echo "Kubernetes service accounts: ${KSA_NAMES}"

gcloud services enable \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"

for bucket in "${BUCKETS[@]}"; do
  if gcloud storage buckets describe "gs://${bucket}" >/dev/null 2>&1; then
    echo "Bucket gs://${bucket} already exists."
    gcloud storage buckets update "gs://${bucket}" \
      --uniform-bucket-level-access \
      --public-access-prevention >/dev/null
  else
    gcloud storage buckets create "gs://${bucket}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --uniform-bucket-level-access \
      --public-access-prevention
  fi
done

if gcloud iam service-accounts describe "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Google service account already exists."
else
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Fredlab Knowledge Flow GCS access"
fi

# IAM is eventually consistent: a service account created moments ago may not yet
# be visible to policy-binding APIs, which then fail with "... does not exist".
# Retry binding operations until the account has propagated, so a fresh first run
# completes without needing a manual second run.
retry() {
  local attempt=1 max="${RETRY_MAX:-30}"
  until "$@"; do
    if (( attempt >= max )); then
      echo "Giving up after ${max} attempts: $*" >&2
      return 1
    fi
    echo "  ...attempt ${attempt}/${max} failed, retrying in 3s (IAM propagation)" >&2
    attempt=$((attempt + 1))
    sleep 3
  done
}

# Object read/write/delete on every Knowledge Flow bucket. objectAdmin is the role
# the GKE deployment guide requires; bucket creation is never done at runtime.
for bucket in "${BUCKETS[@]}"; do
  retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/storage.objectAdmin" >/dev/null
done

# Required if the application later generates signed URLs with Application Default Credentials.
retry gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null

for ksa_name in ${KSA_NAMES}; do
  retry gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${ksa_name}]" \
    --role="roles/iam.workloadIdentityUser" >/dev/null
done

cat <<EOF
GCS prerequisites are ready.

Knowledge Flow Helm values should use:
  content_storage.bucket_name: ${CONTENT_PREFIX}     # -> ${CONTENT_PREFIX}-documents / -objects / -files
  filesystem.bucket_name:      ${FS_BUCKET}
  gcpServiceAccount:           ${GSA_EMAIL}

Future Kubernetes service accounts must be annotated with:
  iam.gke.io/gcp-service-account: ${GSA_EMAIL}

Prepared Workload Identity bindings for:
$(for ksa_name in ${KSA_NAMES}; do echo "  - ${NAMESPACE}/${ksa_name}"; done)
EOF
