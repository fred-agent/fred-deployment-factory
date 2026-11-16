# Conversation benchmarks on k3d

For Fred developers comparing concurrent conversations on Swift and Weaver. Start
with a working [Weaver installation](../README.md#k3d), and add
[Swift](SWIFT-WEAVER.md) for comparison. The path measured is **client -> Fred ->
mock OpenAI -> Fred -> client**; calling the mock directly does not measure Fred.

This is an operator procedure, **not a record of an executed campaign**. Commands
below are examples to adapt and run deliberately on the local environment. Setup
changes accounts, terms, model selection and the mock deployment; load runs create
conversations. None of these actions follows from generating the input files.

## 1. Prepare the accounts and agent access

Follow [conversation identities](../local-testing/bench/CONVERSATIONS.md) to
produce the private credentials and Swift/Weaver provisioning ZIPs offline, then
perform its explicit Keycloak client and application imports. Generate the largest
pool needed once and reuse it across both targets. This is the one-team,
ordinary-member scenario, distinct from the authorization fan-out benchmark.
That document owns client configuration, issuer restrictions and partial-import
handling; do not replace the existing `app` client or relax realm/token policy.

Before continuing, identify:

- The public Fred origins reachable from the load client, and the Swift managed
  SSE URL served on the same origin as its Control Plane.
- One existing plain chat agent instance in each installation, with equivalent
  configuration: no tools, RAG or reasoning, and the dedicated mock model selected.
- The Weaver space UUID and Swift team identifier. Every selected synthetic person
  must have ordinary membership and access to that installation's agent instance.
- The generated `credentials.json`, readable only by the operator, and its local
  Keycloak issuer reachable from the client and trusted by Fred. Scenario mode
  logs real people in and renews their tokens; do not supply bearer tokens in argv.

Use the updated Fred checkout's `developer_tools/benchmarks/README.md` as the
canonical CLI/report reference, and the mock checkout's README for profile and
marker contracts. Both target adaptations run from that **same updated client
checkout**; an old client in a Swift checkout is not sufficient.

## 2. Deploy and explicitly activate the shared mock

From the factory repository, with the updated mock checkout present:

```bash
MOCK_SOURCE="$HOME/Work/common/mock-openai-server"
make k3d-app-validate FRED=bench DIR="$MOCK_SOURCE"
make k3d-app FRED=bench DIR="$MOCK_SOURCE"
```

The default k3d configuration returns one text chunk after a non-blocking
one-second delay. It does **not** activate the deterministic marker/ACK contract.
The current chart renders only `HOST` and `PORT` from its environment values:
setting `env.MOCK_BENCHMARK_PROFILE` in a values override has no effect.

For this scenario, an operator explicitly selects a supported profile on the
existing mock deployment, **triggering a rollout**:

```bash
PROFILE='reference' # or streaming, for a separate comparison
kubectl --context k3d-fred -n fred-bench set env \
  deployment/mock-openai-server "MOCK_BENCHMARK_PROFILE=$PROFILE"
kubectl --context k3d-fred -n fred-bench rollout status \
  deployment/mock-openai-server --timeout=120s
```

This override is outside the chart's managed configuration, not a persistent Helm
setting. Verify/reapply it after any redeployment; `make k3d-app` alone does not
establish the profile. The image must contain the updated mock implementation.
`reference` waits 1000 ms then emits one text fragment; `streaming` waits 1000 ms
then emits 100 logical text fragments separated by 50 ms (99 intervals), followed
by terminal events. These are fragments, not tokens, and timings are nominal lower
bounds. Profiles affect marked requests only. The Go scenario emits the markers
and validates ACK/history evidence; `-mock-profile` declares what it expects,
it does not configure the server. Unmarked UI prompts do not prove activation.

Configure the selected agent separately in each Fred installation:

| Setting | Value |
| --- | --- |
| Base URL from a Fred pod | `http://mock-openai-server.fred-bench.svc.cluster.local:8383/v1` |
| Protocol | OpenAI Chat Completions |
| Upstream model | `gpt-4o` |
| Disposable mock API key | `key-1` |

On Swift, use a dedicated OpenAI entry in `models_catalog` with
`settings.base_url` and its credential. On Weaver, use a dedicated source with
this `inference.api_root`, `wire: openai_chat`, a credential binding and declared
`gpt-4o` offer, allowed through organization/space model policies. Preserve real
model credentials and corpus embeddings. `key-1` authenticates Fred to the mock;
the synthetic people's JWTs authenticate them to Fred. Deploying or profiling the
mock does not change Fred's model selection.

## 3. Check accounts and terms outside measured work

The following examples use Bash. Replace all placeholder values, select the
installed public paths, and create a fresh private output directory. The source
checkout needs the Go toolchain specified in its README; the example selects
Go 1.24.0. Paths and endpoint values are quoted, and credentials stay in their
private file.

```bash
FRED_SOURCE='/absolute/path/to/updated/fred'
CREDS='/absolute/path/to/prepared-inputs/credentials.json'
WEAVER_ORIGIN='http://weaver.localhost:8088'
SWIFT_ORIGIN='http://swift.localhost:8088'
WEAVER_SPACE='<weaver-space-uuid>'
WEAVER_AGENT='<weaver-agent-instance-uuid>'
SWIFT_TEAM='<swift-team-id>'
SWIFT_AGENT='<swift-agent-instance-uuid>'
SWIFT_EXECUTION="$SWIFT_ORIGIN/fred/agents/v2/agents/execute/stream"
umask 077
RUN_DIR="$(mktemp -d /tmp/fred-conversations.XXXXXX)"
cd "$FRED_SOURCE/developer_tools/benchmarks"
export GOTOOLCHAIN=go1.24.0

go run . -prepare-only -target=weaver \
  -fred-origin="$WEAVER_ORIGIN" -control-plane-path=/control-plane/v1 \
  -credential-file="$CREDS" -raw-report="$RUN_DIR/weaver-preparation.jsonl"
go run . -prepare-only -target=swift \
  -fred-origin="$SWIFT_ORIGIN" -control-plane-path=/control-plane/v1 \
  -credential-file="$CREDS" -raw-report="$RUN_DIR/swift-preparation.jsonl"
```

Without `-accept-test-terms`, prepare-only checks credentials and terms without
accepting them, creating sessions or running model calls. If active terms remain
unaccepted, review them, then deliberately repeat preparation with
`-accept-test-terms=current` and **new output filenames**. This opts disposable
`bench-*` accounts into their own current terms through the ordinary public API;
it does not accept terms for an operator or disable the policy. See the
[identity setup](../local-testing/bench/CONVERSATIONS.md#explicit-operator-setup-later)
and canonical client README for the exact limits. Stop on a failed preparation.
Scenario mode separately preflights all selected identities' agent access and
preparation before its first turn; prepare-only is not evidence of model execution.

## 4. Verify one conversation, then compare the same steps

Start with **one person, one conversation, ten sequential turns** on each target.
Run the following two commands successively, never concurrently. This is a
functional check and warm-up; keep its reports separate from measured steps.
To inspect these conversations in Fred's UI, add `-delete-session=false` to
`COMMON` and sign in as the synthetic person who owns the conversation. Default
cleanup removes them; do not assume an administrator can see every person's chats.

```bash
STEPS='1'
IDENTITY_MODE='per-conversation'
COMMON=(
  -scenario=conversation -protocol=sse
  -credential-file="$CREDS" -concurrency-steps="$STEPS"
  -identity-mode="$IDENTITY_MODE" -mock-profile="$PROFILE"
  -requests-per-client=10 -timeout=30s
)

go run . "${COMMON[@]}" -target=weaver \
  -fred-origin="$WEAVER_ORIGIN" -space-id="$WEAVER_SPACE" \
  -agent-instance-id="$WEAVER_AGENT" \
  -raw-report="$RUN_DIR/weaver-turns.jsonl" \
  -json-report="$RUN_DIR/weaver-summary.json"
go run . "${COMMON[@]}" -target=swift \
  -url="$SWIFT_EXECUTION" -sse-team-id="$SWIFT_TEAM" \
  -agent-instance-id="$SWIFT_AGENT" \
  -raw-report="$RUN_DIR/swift-turns.jsonl" \
  -json-report="$RUN_DIR/swift-summary.json"
```

Require successful execution, correct mock evidence and a supported, verified
history check before increasing concurrency. Investigate failures or unsupported
history; neither is a successful correctness check. The client validates marked
user history and ACKs, not all unmarked text, all assistant history or reasoning.

For measured work, create another `RUN_DIR` with `mktemp`, set for example
`STEPS='1,5,10,20'`, then **rebuild `COMMON`** and rerun the two commands. Use the
same ten turns, steps, mock profile, identity mode and equivalent agent settings
for both targets. Each step creates independent conversations with sequential
turns and no intentional ramp; do not add `-clients` or `-ramp-duration` to this
scenario. Do not infer a tested capacity from an example upper step.

Compare two separately named runs if needed: `IDENTITY_MODE='shared'` uses one
real person across N conversations; `per-conversation` uses N distinct people
with the same ordinary rights. Generate enough users for the largest selected
step, rebuild `COMMON` after changing the mode and use another fresh output
directory. Run `reference` first; `streaming` is a separate comparison requiring
both a deliberate mock rollout and the matching client flag. Do not change the
mock between the two targets of one comparison.

Reports are created exclusively with mode 0600; existing paths are refused.
Scenario JSONL streams auth/onboarding/preflight, turn, history and step/summary
records; the summary separates first turns from subsequent turns and performance
from integrity failures. Latency statistics include successful turns only;
an ACK integrity failure is excluded even when execution itself succeeded.
History verification and cleanup happen after the step's active load;
Swift cleanup removes history only, without claiming checkpoint erasure. See the
client README for retention options, raw schemas and unsupported-history handling.
No secrets, prompts or response bodies belong in shared reports.

Compare `execution_first_text`, `execution_final` and `execution_eof` on the same
start boundary, with preparation, authentication/refresh and overall turn time
reported separately. Weaver performs per-turn preparation; historical Swift does
not. First text, final and clean EOF are different observations, and none proves
durable history. Read the history/integrity outcomes alongside latency and errors.
Neither target measures browser rendering. Local k3d results would describe this
setup, not production capacity; no campaign results are asserted here.

## 5. Inspect the bottleneck in one step

Import Fred's existing `deploy/grafana/fred-agent-runtime.json` and follow its
adjacent README for expert queries and instrumentation limits. Keep the high-level
run procedure above; use the following evidence only when explaining a slowdown.
The factory does not install this dashboard or add an exporter automatically.

Select the Fred namespace and measured time interval, excluding warm-up. Keep
Namespace/Pod on All if the scrape pipeline has no such labels. Record the step's
concurrency, mock profile, start/end times, successful/error counts and client
latencies together. The Prometheus series have no campaign identifier: concurrent
traffic and rate windows spanning adjacent steps can mix observations. Wait for
enough scraped observations before interpreting percentiles; absence is not zero.

| Question | Existing evidence | Interpretation limit |
| --- | --- | --- |
| Is time spent before execution or after final? | Client JSONL preparation, execution start, first text, final, stream close and history timestamps | Preparation is not admission; final is not EOF or proof of durable history. Use execution start for comparable SSE timings and report preparation/history separately. |
| Is admission slowing down? | Dashboard `runtime_stage_latency_ms`, grouped by `runtime_stage` | Selected Python stages only. Swift Control Plane emits `runtime_binding_internal`; Weaver Rust does not. Timers overlap and do not isolate JWT/IAM work. Use existing Control Plane request logs for route/status/duration context. |
| Is the model path saturated? | Existing model latency, first chunk, errors and `llm_active_calls` panels; mock summary logs | Runtime-active calls and mock `in_flight` have different boundaries. SDK first chunk is not client TTFT. Do not subtract percentiles. |
| Is the runtime resource-bound? | Existing process CPU/RSS and sampled `event_loop_lag_ms` panels; pod resource observations | Python process CPU is percent of one core, not throttling; RSS is not container working set. The factory scrape config has no cAdvisor/kubelet job, so CPU throttling is unavailable here. |
| Is persistence contributing? | Dashboard `persist_pool_wait_ms` and `persist_sql_ms` | Aggregate hints only: history can acquire its connection inside the SQL timer; checkpoint acquisition can include fencing SQL. `store/op` are not exported labels and SQLx is not covered. Transaction exit/commit coverage depends on the instrumented path and cannot be isolated here. |

`bin/k3d-observe kpi` and `bin/k3d-observe promql '<expression>'` reuse the existing
Prometheus endpoint. Its configured scrape jobs discover application ports named
`metrics` and attach `namespace`, `app` and `pod`; source configuration alone does
not prove a deployed target is present. Do not add a mock or Control Plane series
name to a query unless that installation actually exposes it.

The mock's periodic `[summary ...]` log supplies `in_flight`, `started`,
`completed`, `errors`, `avg_ms`, `p95_ms` and `max_ms`; it is not a Prometheus
exporter. `in_flight` is an instantaneous sample (normally every five seconds),
so short concurrency peaks can be missed. Counters include all routes, including
health checks; `errors` counts only HTTP 5xx, and disconnected requests need not
enter the completed latency sample. These values are not Fred request outcomes.

## 6. Finish the local run

Disable the dedicated benchmark client in Keycloak when finished, as described
in the identity setup. Restore any agent/model selection still using the mock,
then remove only its release from the factory repository:

```bash
make k3d-app-uninstall FRED=bench DIR="$HOME/Work/common/mock-openai-server"
```

This leaves the namespace and the Fred installations in place. `make k3d-wipe`
would instead delete the entire cluster and all application data.
