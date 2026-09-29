#!/usr/bin/env bash
set -Eeuo pipefail

# Create the Cloud Armor policy that refuses externally supplied delegation grant
# parameters. The frontend BackendConfig attaches it through
# fredFrontend.backendConfig.securityPolicyName.
#
# A delegation grant is three plain parameters. A workload inside the cluster may
# present them; a request arriving from outside may not, so the edge refuses them in
# the query. A grant in a JSON body still needs an allow-listed workload token at
# the receiver; the edge does not inspect bodies.
#
# The expression decodes the query first: Cloud Armor matches it raw, while the
# backend decodes an escaped name such as %70erson back to person. It anchors on the
# whole parameter name, because ordinary parameters on the same public backend begin
# with the same words — agent_instance_id, agent_model_override, runtime_id, run_id,
# person_id — and an unanchored match refuses real user traffic.
#
# Idempotent and replayable: an existing policy and rule are updated, not recreated,
# and an update keeps the rule's current preview or enforced mode.
#
# The rule is created in preview mode. Preview logs a would-have-denied verdict
# without refusing anything, so a mis-scoped expression cannot take the instance
# down. Read the Cloud Armor logs, confirm no hits on real traffic, then enforce:
#
#   bin/fredlab-gcp-delegation-edge-prereqs.sh --enforce

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
POLICY="${POLICY:-fredlab-delegation-edge}"
PRIORITY="${PRIORITY:-1000}"
EXPRESSION='request.query.urlDecode().matches("(^|&)(person|run|agent)=")'
MODE="${1:-apply}"

case "${MODE}" in
  apply | --enforce) ;;
  *)
    echo "Usage: $0 [--enforce]" >&2
    exit 2
    ;;
esac

if [[ -z "${PROJECT_ID}" ]]; then
  echo "PROJECT_ID is not set and gcloud has no configured project." >&2
  exit 1
fi

echo "project: ${PROJECT_ID}"
echo "policy:  ${POLICY}"

if [[ "${MODE}" == "--enforce" ]]; then
  gcloud compute security-policies rules update "${PRIORITY}" \
    --security-policy="${POLICY}" \
    --project="${PROJECT_ID}" \
    --no-preview
  echo "Rule ${PRIORITY} enforced: grant parameters from outside are refused."
  exit 0
fi

if gcloud compute security-policies describe "${POLICY}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  policy exists, reusing"
else
  echo "  creating policy"
  gcloud compute security-policies create "${POLICY}" \
    --project="${PROJECT_ID}" \
    --description="Refuse externally supplied delegation grant parameters"
fi

RULE_ARGS=(
  --security-policy="${POLICY}"
  --project="${PROJECT_ID}"
  --expression="${EXPRESSION}"
  --action=deny-403
  --description="delegation grant parameters may not enter from outside"
)

if gcloud compute security-policies rules describe "${PRIORITY}" \
     --security-policy="${POLICY}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "  updating rule ${PRIORITY}; its preview or enforced mode is kept"
  gcloud compute security-policies rules update "${PRIORITY}" "${RULE_ARGS[@]}"
  echo
  echo "Rule ${PRIORITY} updated."
  exit 0
fi

echo "  creating rule ${PRIORITY} in preview"
gcloud compute security-policies rules create "${PRIORITY}" "${RULE_ARGS[@]}" --preview

cat <<EOS

Created in preview: nothing is refused yet.

  1. Set fredFrontend.backendConfig.securityPolicyName: "${POLICY}" in
     gcp-c1/helm/fredlab-secrets.values.yaml and upgrade the infrastructure release,
     so the frontend BackendConfig attaches this policy.
  2. Watch the Cloud Armor logs for this policy. A hit on agent_instance_id,
     runtime_id, run_id or person_id means the expression is wrong — fix it first.
  3. Once preview shows no hits on real traffic, enforce:
       $0 --enforce
EOS
