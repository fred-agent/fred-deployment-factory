---
name: k3d-observability
description: Find what is wrong on the local k3d instance (Fred, the evaluation application, the infrastructure) from the logs, Kubernetes events, metrics and workflows the stack collects. Use when a developer testing on k3d reports something stuck, slow, failing or "not appearing" (an ingestion that never ends, a button that errors, a pod restarting, an evaluation run that fails), or asks for a health check of the k3d stack. Local k3d only; for the fredlab GKE cluster use fredlab-observability.
user-invocable: true
argument-hint: [optional: health | an id to trace | a symptom in words]
---

# k3d Observability

The k3d stack collects everything needed to find a problem; the skill is to read those
sources, in the right order, instead of grepping pod consoles. `bin/k3d-observe` (this
repository) queries them all.

## Preconditions

`make k3d-up` ran (observability is in the base stack), and the apps were deployed with
`make k3d-app` / `make k3d-evaluator` (their overlays open the metrics endpoints and widen
the console so one log line stays one record). Run everything from this repository's root.

## The sources, and what each one answers

| Source | Holds | Reach it |
| --- | --- | --- |
| `k3d-logs-*` (OpenSearch) | every container's output, one document per line, with `kubernetes.pod_name`, `container_name`, `labels.app` | `bin/k3d-observe logs`, or Discover on <http://localhost:5601> |
| `k3d-events-*` (OpenSearch) | Kubernetes events: `reason` (BackOff, Unhealthy, FailedScheduling...), `involvedObject.name`, `message` | `bin/k3d-observe health`, Discover |
| `app-logs-index` (OpenSearch) | the Fred apps' own structured log store (`service`, `level`) | Discover |
| Pod state (cluster) | restarts and their reason: **OOMKilled is here, not in the events** | `bin/k3d-observe health`, `kubectl -n fred get pods` |
| Prometheus | the apps' KPIs: `api_request_latency_ms` (labels `app`, `route`, `http_status`), `llm_call_latency_ms`, `agent_tool_latency_ms`, `agent_tool_failed_total`, `event_loop_lag_ms`, `rebac_call_latency_ms`, `fred_auth_m2m_*` | `bin/k3d-observe kpi` / `promql`, <http://localhost:9090>, Grafana <http://localhost:3002> (folder Fred) |
| Temporal | ingestion and evaluation workflows, their pending activities, attempts, last heartbeat | `bin/k3d-observe trace`, <http://localhost:8233> |
| Databases | the ground truth of an entity's state: `fred.kf_task_run`, `fred.metadata` (document stages), `evaluation.evaluation_run` / `evaluation_case` | `kubectl -n fred exec deploy/postgres -- psql -U admin -d <db>` |

Credentials are in the `fred-secrets` Secret; the script reads them itself.

## Method

1. **Start with `bin/k3d-observe health`.** One screen: containers not ready or restarted
   (with the termination reason), Kubernetes warnings, errors / warnings / HTTP 5xx per
   service, **features switched off at startup** (a service that logs "disabled" or "not
   configured" still answers, then fails: that is how a 503 behind a button looks),
   Prometheus targets down, workflows running.
2. **Follow the entity, not the pods.** For a run, a workflow, a document or a request id:
   `bin/k3d-observe trace <id>` gathers its log lines, its Temporal workflows and, for
   `eval-run-*`, its database row. Then check the entity's state in its database: the UI
   can be stale (a progress stream cut by a restart) while the backend is done.
3. **Search the logs** with `bin/k3d-observe logs '<query>' [--app <pod prefix>] [--since 2h]`
   (OpenSearch query string on the log line, e.g. `'ERROR AND analyze'`).
4. **Metrics for "slow" and "sometimes"**: `bin/k3d-observe kpi`, then `promql` for a
   specific route or app. No data right after a deploy is normal: pods restarted, nothing
   measured yet.
5. **Report facts, then the hypothesis**: what each source showed (with the line, the
   event, the number), what it rules out, and the cause it points to. Name what you could
   not verify.

## Known patterns

| Symptom | What the sources show | Cause |
| --- | --- | --- |
| Documents stay "in ingestion" | pod restarted with `OOMKilled`; Temporal activity `Started` with a stale heartbeat; CPU idle | the worker died mid-extraction; Temporal retries after the heartbeat timeout. Sizing: `k3d-apps/fred/values.yaml`, knowledge-flow-worker |
| UI shows "in ingestion", backend says done | `kf_task_run` `succeeded`, `metadata` stages all `done` | stale UI after a backend restart; reload |
| A button answers 503 | `health` lists a "disabled" warning at the service's startup | a capability the service could not build (e.g. the evaluator's analysis without `deepeval` in its API image) |

## Limits

- Log lines written before Fluent Bit first read a file are not collected.
- `control-plane-worker` declares no `metrics` port: Prometheus does not see it.
- The evaluation application exposes no metrics yet; its logs are collected.
