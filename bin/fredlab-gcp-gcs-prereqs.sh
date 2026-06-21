#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
REGION="${REGION:-europe-west1}"
NAMESPACE="${NAMESPACE:-default}"
BUCKET="${BUCKET:-${PROJECT_ID}-knowledge-flow}"
GSA_NAME="${GSA_NAME:-fredlab-knowledge-flow-gcs}"
GSA_EMAIL="${GSA_EMAIL:-${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Space-separated list of future Kubernetes service accounts allowed to use the GSA.
KSA_NAMES="${KSA_NAMES:-knowledge-flow-backend knowledge-flow-worker}"

echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Namespace: ${NAMESPACE}"
echo "GCS bucket: gs://${BUCKET}"
echo "Google service account: ${GSA_EMAIL}"
echo "Kubernetes service accounts: ${KSA_NAMES}"

gcloud services enable \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"

if gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
  echo "GCS bucket already exists."
  gcloud storage buckets update "gs://${BUCKET}" \
    --uniform-bucket-level-access \
    --public-access-prevention >/dev/null
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

if gcloud iam service-accounts describe "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Google service account already exists."
else
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Fredlab Knowledge Flow GCS access"
fi

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectUser" >/dev/null

# Required if the application later generates signed URLs with Application Default Credentials.
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null

for ksa_name in ${KSA_NAMES}; do
  gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${ksa_name}]" \
    --role="roles/iam.workloadIdentityUser" >/dev/null
done

cat <<EOF
GCS prerequisites are ready.

Future Helm values should use:
  bucket: ${BUCKET}
  gcpServiceAccount: ${GSA_EMAIL}

Future Kubernetes service accounts must be annotated with:
  iam.gke.io/gcp-service-account: ${GSA_EMAIL}

Prepared Workload Identity bindings for:
$(for ksa_name in ${KSA_NAMES}; do echo "  - ${NAMESPACE}/${ksa_name}"; done)
EOF
