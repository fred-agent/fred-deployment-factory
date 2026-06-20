#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
REGION="${REGION:-europe-west1}"
REPOSITORY="${REPOSITORY:-fredlab-repo}"
CLOUDBUILD_BUCKET="${CLOUDBUILD_BUCKET:-${PROJECT_ID}_cloudbuild}"

LEGACY_CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
COMPUTE_CLOUDBUILD_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Artifact Registry repository: ${REPOSITORY}"

gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"

if gcloud artifacts repositories describe "${REPOSITORY}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Artifact Registry repository already exists."
else
  gcloud artifacts repositories create "${REPOSITORY}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Fred playground images" \
    --project="${PROJECT_ID}"
fi

for service_account in "${LEGACY_CLOUDBUILD_SA}" "${COMPUTE_CLOUDBUILD_SA}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${service_account}" \
    --role="roles/artifactregistry.writer" >/dev/null

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${service_account}" \
    --role="roles/logging.logWriter" >/dev/null
done

if gcloud storage buckets describe "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
  for service_account in "${LEGACY_CLOUDBUILD_SA}" "${COMPUTE_CLOUDBUILD_SA}"; do
    gcloud storage buckets add-iam-policy-binding "gs://${CLOUDBUILD_BUCKET}" \
      --member="serviceAccount:${service_account}" \
      --role="roles/storage.objectViewer" >/dev/null
  done
else
  echo "Cloud Build staging bucket gs://${CLOUDBUILD_BUCKET} does not exist yet."
  echo "If the first build creates it and then fails on storage.objects.get, rerun this script once."
fi

echo "GCP build prerequisites are ready."
