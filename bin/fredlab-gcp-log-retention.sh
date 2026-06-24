#!/usr/bin/env bash
set -Eeuo pipefail

# Cap Cloud Logging cost on the playground project. Idempotent and replayable.
#
#   1. Set retention on the _Default log bucket (caps storage cost on kept logs).
#   2. Add/update an exclusion on the _Default sink that drops low-value,
#      high-volume container logs BEFORE ingestion — ingestion is the main cost
#      driver, so this is the lever that actually saves money.
#
# Safe by default: prints the intended changes unless --apply is given. The
# exclusion add/update is detected automatically, so re-running is idempotent.

usage() {
  cat <<'EOF'
fredlab-gcp-log-retention.sh — cap Cloud Logging cost

USAGE
  bin/fredlab-gcp-log-retention.sh [--apply] [-h|--help]

WHAT IT DOES
  Two cost levers on the project's _Default logging bucket/sink:
    retention   shorten how long logs are kept   (storage cost)
    exclusion   drop sub-WARNING container logs   (ingestion cost — the big one)
                in NAMESPACE before they are ingested.
  Idempotent: retention is re-set to the same value; the exclusion is created on
  first run and updated thereafter (never a duplicate-name error).

MODES
  (default)  PREVIEW: prints the exact gcloud commands it would run, changes
             nothing.
  --apply    LIVE: applies the retention change and the exclusion filter.

ENV OVERRIDES (defaults in parentheses)
  PROJECT_ID          GCP project              (gcloud config project)
  LOG_BUCKET          log bucket / sink name   (_Default)
  LOG_LOCATION        bucket location          (global)
  LOG_RETENTION_DAYS  retention                (7)
  NAMESPACE           k8s namespace to trim    (default)
  EXCLUSION_NAME      exclusion identifier     (fredlab-drop-app-info)
  EXCLUSION_FILTER    full exclusion filter    (k8s_container in NAMESPACE,
                                                severity < WARNING)

NOTES
  The exclusion drops logs you will not be able to query later. Keep it narrow:
  by default it only drops sub-WARNING logs in one namespace; warnings, errors,
  and all infra/system logs are untouched. Widen EXCLUSION_FILTER at your own
  risk, and disable it while actively debugging an ingestion.

EXAMPLES
  bin/fredlab-gcp-log-retention.sh                       # preview
  bin/fredlab-gcp-log-retention.sh --apply               # apply defaults
  LOG_RETENTION_DAYS=14 bin/fredlab-gcp-log-retention.sh --apply
  # Remove the exclusion later:
  gcloud logging sinks update _Default --remove-exclusions=fredlab-drop-app-info
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
LOG_BUCKET="${LOG_BUCKET:-_Default}"
LOG_LOCATION="${LOG_LOCATION:-global}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
NAMESPACE="${NAMESPACE:-default}"
EXCLUSION_NAME="${EXCLUSION_NAME:-fredlab-drop-app-info}"
EXCLUSION_FILTER="${EXCLUSION_FILTER:-resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"${NAMESPACE}\" AND severity<WARNING}"

[[ -z "$PROJECT_ID" ]] && { echo "No project set (gcloud config or PROJECT_ID)." >&2; exit 1; }

echo "Project:        ${PROJECT_ID}"
echo "Log bucket/sink:${LOG_BUCKET} (${LOG_LOCATION})"
echo "Retention:      ${LOG_RETENTION_DAYS} days"
echo "Exclusion:      ${EXCLUSION_NAME}"
echo "  filter:       ${EXCLUSION_FILTER}"
echo "Mode:           $([[ "$APPLY" == "1" ]] && echo APPLY || echo PREVIEW)"
echo

# Detect whether the named exclusion already exists on the sink so re-runs update
# instead of failing with a duplicate-name error.
EXCL_FLAG="--add-exclusion"
if gcloud logging sinks describe "${LOG_BUCKET}" --format='value(exclusions[].name)' 2>/dev/null \
    | tr ';,' '\n' | grep -qx "${EXCLUSION_NAME}"; then
  EXCL_FLAG="--update-exclusion"
fi

if [[ "$APPLY" == "1" ]]; then
  echo "Setting retention on ${LOG_BUCKET}..."
  gcloud logging buckets update "${LOG_BUCKET}" \
    --location="${LOG_LOCATION}" --retention-days="${LOG_RETENTION_DAYS}"

  echo "${EXCL_FLAG/--/} exclusion ${EXCLUSION_NAME}..."
  gcloud logging sinks update "${LOG_BUCKET}" \
    "${EXCL_FLAG}=name=${EXCLUSION_NAME},description=fredlab playground cost control,filter=${EXCLUSION_FILTER}"

  echo
  echo "Done. Inspect with:"
  echo "  gcloud logging sinks describe ${LOG_BUCKET}"
  echo "  gcloud logging buckets describe ${LOG_BUCKET} --location=${LOG_LOCATION}"
else
  echo "PREVIEW — would run:"
  echo "  gcloud logging buckets update ${LOG_BUCKET} \\"
  echo "    --location=${LOG_LOCATION} --retention-days=${LOG_RETENTION_DAYS}"
  echo "  gcloud logging sinks update ${LOG_BUCKET} \\"
  echo "    ${EXCL_FLAG}=name=${EXCLUSION_NAME},description=fredlab playground cost control,filter=${EXCLUSION_FILTER}"
  echo
  echo "Re-run with --apply to make these changes live."
fi
