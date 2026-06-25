#!/usr/bin/env bash
set -Eeuo pipefail

# fredlab-sessions.sh — READ-ONLY visibility into conversation persistence.
#
# Conversations span three tables in the `fred` Postgres DB, owned by two services:
#   - session_metadata        (control-plane) : the session row shown in the UI list
#   - session_history         (fred-runtime)  : the chat messages
#   - v2_langgraph_checkpoint*(fred-runtime)  : the LangGraph state (keyed by thread_id = session_id)
#   - session_purge_queue     (control-plane) : deferred-delete / retention queue
#
# This tool only ever runs SELECTs. It never deletes. Purge/retention is owned by the
# control-plane policy engine (resolve_purge / lifecycle runner) — drive deletes there,
# not with raw SQL, or you orphan checkpoints and bypass REBAC/cancel_on_rejoin/audit.
#
# Usage:
#   bin/fredlab-sessions.sh                 # summary dashboard (default)
#   bin/fredlab-sessions.sh summary         # counts + sizes + drift + purge-queue + age
#   bin/fredlab-sessions.sh drift           # sample offending session ids (orphans/empties)
#   bin/fredlab-sessions.sh top [N]         # biggest sessions by message count (default 15)
#   bin/fredlab-sessions.sh session <id>    # full cross-table detail for one session
#   bin/fredlab-sessions.sh queue           # the session_purge_queue contents
#   bin/fredlab-sessions.sh psql            # interactive psql shell on the fred DB (escape hatch)
#
# Environment overrides:
#   NAMESPACE (default: default)   POSTGRES_POD (default: postgres-0)
#   PGUSER (default: fred)         PGDB (default: fred)
#   SECRET_NAME (default: fredlab-infra-secrets)  PW_KEY (default: POSTGRES_FRED_PASSWORD)

NAMESPACE="${NAMESPACE:-default}"
POSTGRES_POD="${POSTGRES_POD:-postgres-0}"
PGUSER="${PGUSER:-fred}"
PGDB="${PGDB:-fred}"
SECRET_NAME="${SECRET_NAME:-fredlab-infra-secrets}"
PW_KEY="${PW_KEY:-POSTGRES_FRED_PASSWORD}"

# Help must not require cluster access — handle it before any kubectl/secret call.
case "${1:-}" in -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

for bin in kubectl base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 2; }
done

if [[ -t 1 ]]; then B=$'\e[1m'; D=$'\e[2m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; D=""; Y=""; R=""; N=""; fi

PGPW="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.$PW_KEY}" 2>/dev/null | base64 -d || true)"
if [[ -z "$PGPW" ]]; then
  echo "Could not read $PW_KEY from secret $SECRET_NAME in ns $NAMESPACE." >&2
  exit 2
fi

# Run a SQL string (read-only). Quiet psql chrome; aligned table output.
q() {
  kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -i -- \
    env PGPASSWORD="$PGPW" psql -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 -P pager=off "$@"
}

section() { printf "\n%s── %s %s%s\n" "$B" "$1" "────────────────────────────────────────" "$N"; }

# Which of the known tables actually exist (runtime tables are absent until fred-agents
# runs on Postgres — itself a useful signal).
EXISTING="$(q -tAc "SELECT relname FROM pg_class
  WHERE relkind='r' AND relname = ANY(ARRAY[
    'session_metadata','session_history','session_purge_queue',
    'v2_langgraph_checkpoint','v2_langgraph_checkpoint_blob','v2_langgraph_checkpoint_write'])" 2>/dev/null || true)"
has() { grep -qx "$1" <<<"$EXISTING"; }

warn_runtime_tables() {
  has session_history && return 0
  printf "  %s⚠ session_history not found in this DB%s — fred-agents is not (yet) Postgres-backed.\n" "$Y" "$N"
  printf "  %s  Conversation messages/checkpoints are still ephemeral; apply the durability fix + redeploy.%s\n" "$D" "$N"
}

cmd_summary() {
  printf "%s┌─ Session persistence — ns=%s db=%s ─────────────%s\n" "$B" "$NAMESPACE" "$PGDB" "$N"

  section "Row counts"
  q -c "SELECT
    (SELECT count(*) FROM session_metadata)                                        AS sessions_listed,
    $(has session_history       && echo "(SELECT count(DISTINCT session_id) FROM session_history)" || echo "NULL") AS sessions_with_msgs,
    $(has session_history       && echo "(SELECT count(*) FROM session_history)"                   || echo "NULL") AS message_rows,
    $(has v2_langgraph_checkpoint && echo "(SELECT count(DISTINCT thread_id) FROM v2_langgraph_checkpoint)" || echo "NULL") AS threads_checkpointed,
    (SELECT count(*) FROM session_purge_queue)                                     AS purge_queue_rows;"

  section "Storage sizes"
  q -c "SELECT relname AS table,
               pg_size_pretty(pg_total_relation_size(quote_ident(relname))) AS total_size,
               n_live_tup AS approx_rows
        FROM pg_stat_user_tables
        WHERE relname IN ('session_metadata','session_history','session_purge_queue',
                          'v2_langgraph_checkpoint','v2_langgraph_checkpoint_blob','v2_langgraph_checkpoint_write')
        ORDER BY pg_total_relation_size(quote_ident(relname)) DESC;"

  section "Drift (two-layer consistency)"
  warn_runtime_tables
  if has session_history; then
    q -c "SELECT
      (SELECT count(*) FROM session_metadata m
         LEFT JOIN (SELECT DISTINCT session_id FROM session_history) h ON h.session_id=m.session_id
         WHERE h.session_id IS NULL)                              AS listed_but_empty,
      (SELECT count(DISTINCT h.session_id) FROM session_history h
         LEFT JOIN session_metadata m ON m.session_id=h.session_id
         WHERE m.session_id IS NULL)                              AS msgs_without_session
      $(has v2_langgraph_checkpoint && echo ",
      (SELECT count(*) FROM session_metadata m
         LEFT JOIN (SELECT DISTINCT thread_id FROM v2_langgraph_checkpoint) c ON c.thread_id=m.session_id
         WHERE c.thread_id IS NULL)                               AS listed_no_checkpoint,
      (SELECT count(DISTINCT c.thread_id) FROM v2_langgraph_checkpoint c
         LEFT JOIN session_metadata m ON m.session_id=c.thread_id
         WHERE m.session_id IS NULL)                              AS checkpoints_without_session" || echo "");"
    printf "  %slisted_but_empty>0 = sessions that show in the UI but reopen blank (the SQLite-wipe signature).%s\n" "$D" "$N"
  fi

  section "Purge queue by status"
  q -c "SELECT status, count(*) AS rows, min(due_at) AS earliest_due,
               count(*) FILTER (WHERE due_at < now()) AS overdue
        FROM session_purge_queue GROUP BY status ORDER BY status;"

  section "Session age (by updated_at)"
  q -c "SELECT
    count(*) FILTER (WHERE updated_at >  now()-interval '1 day')                                   AS last_24h,
    count(*) FILTER (WHERE updated_at <= now()-interval '1 day'  AND updated_at > now()-interval '7 days')  AS d1_7,
    count(*) FILTER (WHERE updated_at <= now()-interval '7 days' AND updated_at > now()-interval '30 days') AS d7_30,
    count(*) FILTER (WHERE updated_at <= now()-interval '30 days')                                  AS older_30d
    FROM session_metadata;"
  printf "%s└──────────────────────────────────────────────────────%s\n" "$D" "$N"
}

cmd_drift() {
  warn_runtime_tables
  has session_history || return 0
  section "Listed but empty — metadata row, no messages (sample 20)"
  q -c "SELECT m.session_id, m.team_id, m.user_id, left(coalesce(m.title,''),30) AS title, m.updated_at
        FROM session_metadata m
        LEFT JOIN (SELECT DISTINCT session_id FROM session_history) h ON h.session_id=m.session_id
        WHERE h.session_id IS NULL ORDER BY m.updated_at DESC LIMIT 20;"
  section "Messages without a session row — orphaned history (sample 20)"
  q -c "SELECT h.session_id, count(*) AS msgs, max(h.timestamp) AS last_msg
        FROM session_history h
        LEFT JOIN session_metadata m ON m.session_id=h.session_id
        WHERE m.session_id IS NULL GROUP BY h.session_id ORDER BY last_msg DESC LIMIT 20;"
  if has v2_langgraph_checkpoint; then
    section "Checkpoints without a session row — leaked state (sample 20)"
    q -c "SELECT c.thread_id, count(*) AS checkpoints
          FROM v2_langgraph_checkpoint c
          LEFT JOIN session_metadata m ON m.session_id=c.thread_id
          WHERE m.session_id IS NULL GROUP BY c.thread_id LIMIT 20;"
  fi
}

cmd_top() {
  local n="${1:-15}"
  has session_history || { warn_runtime_tables; return 0; }
  section "Top $n sessions by message count"
  q -c "SELECT m.session_id, m.team_id, m.user_id, left(coalesce(m.title,''),30) AS title,
               count(h.rank) AS msgs, max(h.timestamp) AS last_msg
        FROM session_metadata m
        LEFT JOIN session_history h ON h.session_id=m.session_id
        GROUP BY m.session_id, m.team_id, m.user_id, m.title
        ORDER BY msgs DESC NULLS LAST LIMIT ${n};"
}

cmd_session() {
  local sid="${1:-}"
  [[ -z "$sid" ]] && { echo "usage: fredlab-sessions.sh session <session_id>"; exit 1; }
  section "metadata"
  q -c "SELECT * FROM session_metadata WHERE session_id='${sid}';"
  if has session_history; then
    section "history"
    q -c "SELECT rank, timestamp, role, channel, left(parts_json::text,80) AS parts
          FROM session_history WHERE session_id='${sid}' ORDER BY rank;"
  fi
  if has v2_langgraph_checkpoint; then
    section "checkpoints"
    q -c "SELECT checkpoint_ns, checkpoint_id, parent_checkpoint_id
          FROM v2_langgraph_checkpoint WHERE thread_id='${sid}';"
  fi
  section "purge_queue"
  q -c "SELECT * FROM session_purge_queue WHERE session_id='${sid}';"
}

cmd_queue() {
  section "session_purge_queue (ordered by due_at)"
  q -c "SELECT session_id, team_id, user_id, status, due_at,
               (due_at < now()) AS overdue, created_at
        FROM session_purge_queue ORDER BY due_at LIMIT 50;"
}

cmd_psql() {
  printf "%s⚠ interactive psql on %s/%s — this shell CAN write. Purge via the control-plane engine, not DELETE.%s\n" "$Y" "$PGUSER" "$PGDB" "$N"
  kubectl exec -it -n "$NAMESPACE" "$POSTGRES_POD" -- env PGPASSWORD="$PGPW" psql -U "$PGUSER" -d "$PGDB"
}

ACTION="${1:-summary}"
case "$ACTION" in
  summary) cmd_summary ;;
  drift)   cmd_drift ;;
  top)     cmd_top "${2:-15}" ;;
  session) cmd_session "${2:-}" ;;
  queue)   cmd_queue ;;
  psql)    cmd_psql ;;
  -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "Unknown command: $ACTION"; sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
