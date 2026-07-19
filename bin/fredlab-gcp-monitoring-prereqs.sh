#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare the GCP prerequisites for the in-cluster Google Cloud Managed Service
# for Prometheus (GMP) query frontend (gcp-c1/helm/templates/gmp-frontend.yaml).
#
# The frontend is a stateless PromQL-compatible proxy in front of Cloud
# Monitoring. GKE Autopilot already collects GKE system metrics (node/pod
# resource usage) into GMP for free with no extra install; this script only
# grants the frontend pod's Kubernetes service account read access to query
# them, via Workload Identity — the same pattern as
# bin/fredlab-gcp-gcs-prereqs.sh.
#
# Idempotent and replayable: existing SA/bindings are reused, not recreated.

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
NAMESPACE="${NAMESPACE:-default}"

GSA_NAME="${GSA_NAME:-fredlab-monitoring}"
GSA_EMAIL="${GSA_EMAIL:-${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Space-separated list of Kubernetes service accounts allowed to impersonate the GSA.
# gmp-frontend queries Cloud Monitoring for the GMP-collected Prometheus metrics;
# grafana queries it directly too (Google Cloud Monitoring datasource, e.g. GCS
# bucket storage size) when grafana.datasources.cloudMonitoring.enabled.
KSA_NAMES="${KSA_NAMES:-gmp-frontend grafana}"

echo "Project: ${PROJECT_ID}"
echo "Namespace: ${NAMESPACE}"
echo "Google service account: ${GSA_EMAIL}"
echo "Kubernetes service accounts: ${KSA_NAMES}"

gcloud services enable \
  monitoring.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"

if gcloud iam service-accounts describe "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Google service account already exists."
else
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Fredlab GMP query frontend (Cloud Monitoring read access)"
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

# Read-only access to Cloud Monitoring (Metrics Explorer / GMP data) — no write,
# no access to logs, secrets, or any other project resource.
retry gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/monitoring.viewer" >/dev/null

for ksa_name in ${KSA_NAMES}; do
  retry gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${ksa_name}]" \
    --role="roles/iam.workloadIdentityUser" >/dev/null
done

cat <<EOF
Monitoring prerequisites are ready.

gcp-c1/helm/values.yaml should use:
  gmpFrontend.serviceAccount.gcpServiceAccount: ${GSA_EMAIL}
  gmpFrontend.projectId:                        ${PROJECT_ID}

Then set gmpFrontend.enabled: true and run bin/fredlab-infra-deploy.sh.

Prepared Workload Identity bindings for:
$(for ksa_name in ${KSA_NAMES}; do echo "  - ${NAMESPACE}/${ksa_name}"; done)
EOF
