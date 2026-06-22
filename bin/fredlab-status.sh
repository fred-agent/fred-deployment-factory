#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-status.sh — consolidated platform health for the fredlab namespace.
#
# Polls every Deployment and StatefulSet until the platform reaches a stable
# state (all desired replicas Ready, no pod stuck) or a timeout elapses, then
# prints a single ✅/❌ dashboard. Exit code is 0 when stable, 1 otherwise — so
# it composes in scripts and CI.
#
# Usage:
#   bin/fredlab-status.sh            # wait until stable or timeout, then report
#   bin/fredlab-status.sh --once     # single snapshot, no waiting
#
# Environment overrides:
#   NAMESPACE (default: default)
#   TIMEOUT   max seconds to wait for stable      (default: 300)
#   INTERVAL  seconds between polls while waiting  (default: 5)

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-300}"
INTERVAL="${INTERVAL:-5}"
MODE="wait"
[[ "${1:-}" == "--once" ]] && MODE="once"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

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

STABLE=1
start="$(date +%s)"
while :; do
  now="$(date +%s)"; elapsed="$(( now - start ))"
  # Render directly (not via $(...)): a command-substitution subshell would
  # discard the STABLE flag render() sets.
  if [[ "$MODE" == "wait" && -t 1 ]]; then printf '\033[2J\033[H'; fi
  render "$elapsed"

  if [[ "$STABLE" == "1" ]]; then
    printf "\n%s✅ PLATFORM STABLE%s — all workloads ready.\n" "$B$G" "$N"
    exit 0
  fi
  if [[ "$MODE" == "once" || "$elapsed" -ge "$TIMEOUT" ]]; then
    printf "\n%s❌ NOT STABLE%s — %s\n" "$B$R" "$N" \
      "$([[ "$MODE" == "once" ]] && echo "snapshot only" || echo "timed out after ${TIMEOUT}s")"
    exit 1
  fi
  sleep "$INTERVAL"
done
