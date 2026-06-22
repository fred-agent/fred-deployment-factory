#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-status.sh — consolidated platform health for the fredlab namespace.
#
# Polls every Deployment and StatefulSet until the platform reaches a stable
# state (all desired replicas Ready, no pod stuck) or a timeout elapses, then
# prints a single ✅/❌ dashboard. Exit code is 0 when stable, 1 otherwise — so
# it composes in scripts and CI.
#
# It also checks the GCP-side GCS prerequisites (bucket region + lockdown, the
# Knowledge Flow service account, and its Workload Identity bindings) and folds
# them into the same verdict. The GCS checks degrade to a yellow "skipped" (never
# red) when gcloud is unavailable or unauthenticated, so the command stays useful
# without GCP access.
#
# Usage:
#   bin/fredlab-status.sh            # wait until stable or timeout, then report
#   bin/fredlab-status.sh --once     # single snapshot, no waiting
#   bin/fredlab-status.sh --no-gcs   # skip the GCS/GCP checks
#
# Environment overrides:
#   NAMESPACE (default: default)
#   TIMEOUT   max seconds to wait for stable      (default: 300)
#   INTERVAL  seconds between polls while waiting  (default: 5)
#   CHECK_GCS 1 to check GCS prereqs, 0 to skip    (default: 1)
#   BUCKET / REGION / GSA_EMAIL / KSA_NAMES        (default to the GCS prereq script's values)

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-300}"
INTERVAL="${INTERVAL:-5}"
CHECK_GCS="${CHECK_GCS:-1}"
MODE="wait"
for arg in "$@"; do
  case "$arg" in
    --once)   MODE="once" ;;
    --no-gcs) CHECK_GCS=0 ;;
    -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 2; }
done

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; R=""; Y=""; D=""; B=""; N=""
fi

# Render one snapshot. Sets global STABLE=0/1. Prints the dashboard.
render() {
  local elapsed="$1"
  local workloads pods bad_pods
  workloads="$(kubectl get deploy,statefulset -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | [(.kind), (.metadata.name), (.spec.replicas // 0), (.status.readyReplicas // 0)] | @tsv')"

  # Pods that are neither fully Running+Ready nor Succeeded (jobs), with a reason.
  bad_pods="$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase != "Succeeded")
    | if (.status.phase == "Running") and ((.status.containerStatuses // []) | length > 0)
         and (all(.status.containerStatuses[]; .ready)) then empty
      else [ .metadata.name,
             ( [ .status.containerStatuses[]? | select(.ready | not)
                 | (.state.waiting.reason // .state.terminated.reason // "NotReady") ] | first )
             // .status.phase ] | @tsv
      end')"

  STABLE=1
  printf "%s┌─ Fredlab platform ─ ns=%s ─ %ss elapsed ─────────────%s\n" "$B" "$NAMESPACE" "$elapsed" "$N"
  printf "%s%-12s %-26s %-7s %s%s\n" "$D" "KIND" "NAME" "READY" "STATUS" "$N"

  local kind name desired ready icon label
  while IFS=$'\t' read -r kind name desired ready; do
    [[ -z "${name:-}" ]] && continue
    if [[ "$desired" == "0" ]]; then
      icon="⚪"; label="${D}disabled${N}"
    elif [[ "$ready" == "$desired" ]]; then
      icon="✅"; label="${G}ready${N}"
    else
      icon="⏳"; label="${Y}progressing${N}"; STABLE=0
    fi
    printf "%-12s %-26s %-7s %s %b\n" "$kind" "$name" "${ready}/${desired}" "$icon" "$label"
  done <<< "$workloads"

  if [[ -n "${bad_pods//[$'\t\n ']/}" ]]; then
    STABLE=0
    printf "%s└─ problem pods ───────────────────────────────────────%s\n" "$R" "$N"
    local pname reason
    while IFS=$'\t' read -r pname reason; do
      [[ -z "${pname:-}" ]] && continue
      printf "  %s✗%s %-26s %s%s%s\n" "$R" "$N" "$pname" "$R" "$reason" "$N"
    done <<< "$bad_pods"
  else
    printf "%s└──────────────────────────────────────────────────────%s\n" "$D" "$N"
  fi
}

# One pass/fail line. Sets GCS_OK=0 on failure.
gcs_check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "1" ]]; then
    printf "  %s✓%s %-38s %s%s%s\n" "$G" "$N" "$label" "$D" "$detail" "$N"
  else
    printf "  %s✗%s %-38s %s%s%s\n" "$R" "$N" "$label" "$R" "${detail:-FAIL}" "$N"
    GCS_OK=0
  fi
}

# Verify the GCS prerequisites. Sets GCS_OK=0/1 and GCS_SKIPPED=0/1. Prints a section.
render_gcs() {
  GCS_OK=1; GCS_SKIPPED=0
  local skip_reason=""
  if [[ "$CHECK_GCS" != "1" ]]; then skip_reason="--no-gcs"; fi
  if [[ -z "$skip_reason" ]] && ! command -v gcloud >/dev/null 2>&1; then skip_reason="gcloud not installed"; fi

  local project=""
  if [[ -z "$skip_reason" ]]; then
    project="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
    [[ -z "$project" ]] && skip_reason="no active gcloud project"
  fi

  if [[ -n "$skip_reason" ]]; then
    GCS_SKIPPED=1
    printf "%s┌─ GCS prerequisites ──────────────────────────────────%s\n" "$D" "$N"
    printf "  %s⚪ skipped%s — %s\n" "$Y" "$N" "$skip_reason"
    printf "%s└──────────────────────────────────────────────────────%s\n" "$D" "$N"
    return
  fi

  local region="${REGION:-europe-west9}"
  local bucket="${BUCKET:-${project}-knowledge-flow}"
  local gsa_email="${GSA_EMAIL:-${GSA_NAME:-fredlab-knowledge-flow-gcs}@${project}.iam.gserviceaccount.com}"
  local ksa_names="${KSA_NAMES:-knowledge-flow-backend knowledge-flow-worker}"

  printf "%s┌─ GCS prerequisites ─ project=%s ──────────────────────%s\n" "$B" "$project" "$N"

  # Bucket: existence + region + lockdown. Tolerant to gcloud-storage (snake_case)
  # and JSON-API (camelCase iamConfiguration) shapes.
  local desc
  if desc="$(gcloud storage buckets describe "gs://${bucket}" --format=json 2>/dev/null)"; then
    local loc pap ubla
    loc="$(jq -r '(.location // "") ' <<< "$desc")"; loc="${loc,,}"
    pap="$(jq -r '(.public_access_prevention // .iamConfiguration.publicAccessPrevention // "unknown")' <<< "$desc")"
    ubla="$(jq -r '((.uniform_bucket_level_access | if type=="object" then .enabled else . end) // .iamConfiguration.uniformBucketLevelAccess.enabled // false) | tostring' <<< "$desc")"
    gcs_check "bucket gs://${bucket}" 1 "exists"
    gcs_check "location = ${region}" "$([[ "$loc" == "${region,,}" ]] && echo 1 || echo 0)" "$loc"
    gcs_check "public access prevention = enforced" "$([[ "$pap" == "enforced" ]] && echo 1 || echo 0)" "$pap"
    gcs_check "uniform bucket-level access = on" "$([[ "$ubla" == "true" ]] && echo 1 || echo 0)" "$ubla"
  else
    gcs_check "bucket gs://${bucket}" 0 "missing"
  fi

  # Service account + Workload Identity bindings.
  if gcloud iam service-accounts describe "$gsa_email" --project="$project" >/dev/null 2>&1; then
    gcs_check "service account" 1 "$gsa_email"
    local policy ksa member has
    policy="$(gcloud iam service-accounts get-iam-policy "$gsa_email" --project="$project" --format=json 2>/dev/null || echo '{}')"
    for ksa in $ksa_names; do
      member="serviceAccount:${project}.svc.id.goog[${NAMESPACE}/${ksa}]"
      has="$(jq -r --arg m "$member" '[.bindings[]? | select(.role=="roles/iam.workloadIdentityUser") | .members[]? | select(.==$m)] | length' <<< "$policy")"
      gcs_check "workloadIdentityUser: ${NAMESPACE}/${ksa}" "$([[ "${has:-0}" -ge 1 ]] && echo 1 || echo 0)" ""
    done
  else
    gcs_check "service account ${gsa_email}" 0 "missing"
  fi

  if [[ "$GCS_OK" == "1" ]]; then
    printf "%s└──────────────────────────────────────────────────────%s\n" "$D" "$N"
  else
    printf "%s└─ run bin/fredlab-gcp-gcs-prereqs.sh to repair ───────%s\n" "$R" "$N"
  fi
}

STABLE=1; GCS_OK=1; GCS_SKIPPED=0
start="$(date +%s)"
while :; do
  now="$(date +%s)"; elapsed="$(( now - start ))"
  # Render directly (not via $(...)): a command-substitution subshell would
  # discard the STABLE flag render() sets.
  if [[ "$MODE" == "wait" && -t 1 ]]; then printf '\033[2J\033[H'; fi
  render "$elapsed"

  # Settle once workloads are stable, or on a one-shot snapshot / timeout. We only
  # query GCP at that point, so the poll loop stays fast.
  if [[ "$STABLE" == "1" || "$MODE" == "once" || "$elapsed" -ge "$TIMEOUT" ]]; then
    render_gcs

    if [[ "$STABLE" == "1" && ( "$GCS_OK" == "1" || "$GCS_SKIPPED" == "1" ) ]]; then
      printf "\n%s✅ PLATFORM STABLE%s — all workloads ready" "$B$G" "$N"
      [[ "$GCS_SKIPPED" == "1" ]] && printf " %s(GCS checks skipped)%s" "$Y" "$N" \
                                  || printf "; GCS prerequisites OK"
      printf ".\n"
      exit 0
    fi

    reasons=()
    [[ "$STABLE" != "1" ]] && reasons+=("workloads $([[ "$MODE" == "once" ]] && echo "not ready" || echo "timed out after ${TIMEOUT}s")")
    [[ "$GCS_OK" != "1" && "$GCS_SKIPPED" != "1" ]] && reasons+=("GCS prerequisites failing")
    printf "\n%s❌ NOT STABLE%s — %s.\n" "$B$R" "$N" "$(IFS='; '; echo "${reasons[*]}")"
    exit 1
  fi
  sleep "$INTERVAL"
done
