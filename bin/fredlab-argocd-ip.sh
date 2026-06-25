#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-argocd-ip.sh — reserve the global static IP for ArgoCD's own Ingress.
#
# Step 1 of exposing ArgoCD at https://argocd.playground.fredlab.dev (its own Ingress +
# ManagedCertificate, because ArgoCD lives in the `argocd` namespace and a GCE Ingress
# cannot route across namespaces, so it cannot share the existing fredlab-infra Ingress).
#
# Idempotent and harmless: reserving an address routes no traffic and exposes nothing.
# After it prints the IP, YOU create the DNS A record (DNS is managed outside Helm).

NAME="${NAME:-fredlab-argocd-ip}"
HOST="${HOST:-argocd.playground.fredlab.dev}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

command -v gcloud >/dev/null 2>&1 || { echo "Missing required tool: gcloud"; exit 1; }

echo "Project: ${PROJECT_ID}"
echo "Reserving global static IP '${NAME}' (idempotent)..."

if gcloud compute addresses describe "${NAME}" --global >/dev/null 2>&1; then
  echo "Already reserved."
else
  gcloud compute addresses create "${NAME}" --global
fi

IP="$(gcloud compute addresses describe "${NAME}" --global --format='value(address)')"

cat <<EOF

Reserved IP: ${IP}   (name: ${NAME})

NEXT (yours to do — DNS is outside Helm):
  Create a DNS A record:
    ${HOST}  ->  ${IP}

Then tell me, and we do step 2 (the ArgoCD Ingress + ManagedCertificate).
Nothing is exposed yet — this only reserves the address.
EOF
