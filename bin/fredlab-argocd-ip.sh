#!/usr/bin/env bash
set -Eeuo pipefail
# Reserve the global static IP for ArgoCD's Ingress. Idempotent; run once. Prints the IP.

NAME="${NAME:-fredlab-argocd-ip}"
command -v gcloud >/dev/null 2>&1 || { echo "Missing required tool: gcloud"; exit 1; }

gcloud compute addresses describe "${NAME}" --global >/dev/null 2>&1 \
  || gcloud compute addresses create "${NAME}" --global >/dev/null

gcloud compute addresses describe "${NAME}" --global --format='value(address)'
