# Conversation benchmarks on k3d

For Fred developers comparing concurrent conversations on Swift and Weaver. Start
with a working [Weaver installation](../README.md#k3d), and add
[Swift](SWIFT-WEAVER.md) for comparison. The path measured is **client -> Fred ->
mock OpenAI -> Fred -> client**; calling the mock directly does not measure Fred.

This is an operator procedure, **not a record of an executed campaign**. Commands
below are examples to adapt and run deliberately on the local environment. Setup
changes accounts, terms, model selection and the mock deployment; load runs create
conversations. None of these actions follows from generating the input files.

## 1. Install once, or update the existing lab

Clone the versions containing this recipe (until merged, Weaver's branch is
`chore/bench`, **not** `weaver`). Build both targets from checkouts:

```bash
git clone --branch weaver https://github.com/fred-agent/fred-deployment-factory.git
git clone --branch chore/bench https://github.com/ThalesGroup/fred.git fred-weaver
git clone --branch swift https://github.com/ThalesGroup/fred.git fred-swift
git clone --branch swift https://github.com/fred-agent/mock-openai-server.git
cd fred-deployment-factory
WEAVER_SOURCE="$(realpath ../fred-weaver)"
SWIFT_SOURCE="$(realpath ../fred-swift)"
MOCK_SOURCE="$(realpath ../mock-openai-server)"
PROFILE=reference
```

On a **new machine/lab**, follow [machine prerequisites](../README.md#k3d), add
`127.0.0.1 keycloak app-keycloak weaver.localhost swift.localhost` to `/etc/hosts`,
run `make k3d-up`, then complete the documented
[OpenSearch HTTPS preparation](LOCAL-DEVELOPMENT.md#new-installation-renewal-and-rollback).
Keep its generated operator files private and persistent; they are produced by
that procedure, not copied from another developer. An existing installation skips
infrastructure creation/TLS setup. Never wipe a lab containing conversations.

Deploy the shared mock and both Fred versions with the **same commands on first
install and every full redeploy**:

```bash
make k3d-app FRED=bench DIR="$MOCK_SOURCE" BENCH="$PROFILE"
make k3d-app FRED=swift APP=fred DIR="$SWIFT_SOURCE" BENCH="$PROFILE"
make k3d-app FRED=weaver APP=fred DIR="$WEAVER_SOURCE" BENCH="$PROFILE"
```

Replace `k3d-app` with `k3d-app-validate` to render without building or modifying
the cluster. No private values overlay, ConfigMap edit or `kubectl set env` is
needed. The normal build includes the checked-in SDK fix. The mock defaults to
`none`; `BENCH=reference|streaming` explicitly selects its Helm-managed profile.
Repeat the option when updating. A Fred release already containing the benchmark
model refuses a sync that omits `BENCH`, before building or rolling out, rather
than withdrawing a source still referenced by saved agents. `BENCH=none` is not
an uninstall shortcut. Custom `VALUES` are applied last: do not pass former
private copies of model/environment arrays that would replace these additions.

The Fred overlay appends only `bench.chat.mock` (Swift) / `bench-mock` (Weaver),
with upstream `gpt-4o`, OpenAI Chat Completions and disposable key `key-1` at
`http://mock-openai-server.fred-bench.svc.cluster.local:8383/v1`. Workers inherit
the same catalog/credential configuration. Real providers, existing credentials,
corpus embeddings and saved policies/defaults are retained. If the model Secret
does not exist, the command creates a disposable placeholder to let this
**chat-only** lab start without a paid API key; real model calls and RAG remain
unavailable until their actual keys are configured. No model call is made by setup.

In benchmark mode Weaver's automatic `organization_models` initializer is empty:
imports do not discover paid providers or establish real defaults. Existing SQL
policies remain intact; fresh organizations have no default. The dedicated agent
selects the mock explicitly. Later real-provider initialization is a deliberate
operator action, not part of benchmark preparation or redeployment.

`reference` waits 1000 ms then emits one text fragment; `streaming` waits 1000 ms
then emits 100 logical text fragments separated by 50 ms (99 intervals), followed
by terminal events. These are fragments, not tokens; timings are nominal lower
bounds. Only marked requests use this contract. The Go client's `-mock-profile`
declares its expectation; it does not configure the server.

## 2. Bootstrap and prepare synthetic people and agents

For a fresh lab, log in to each UI, claim its platform bootstrap token printed
by deployment and personally accept active terms. Build the existing demo bundles:

```bash
make -C "$WEAVER_SOURCE" bundle-demo
make -C "$SWIFT_SOURCE/apps/control-plane-backend" build-demo-bundle
```

Import Weaver's `apps/control-plane/target/demo-provisioning-bundle.zip` in
**Admin > Provisioning** and Swift's
`apps/control-plane-backend/target/demo-provisioning-bundle.zip` in
**Admin > Migration**; wait for the Swift task to succeed. Existing labs reuse
their spaces and do not need these imports again. Use ordinary administration to
activate `fred.github.assistant` for the target organization/team. The applying
operator needs platform import rights **and** organization management/team agent
creation rights (platform administration alone grants no business authority).
Grant these through the normal UI, with team membership on Weaver.

Copy [setup.example.json](../local-testing/bench/setup.example.json) outside Git.
Set the checkout/output paths, pool size, team names/IDs and Weaver organization
name/UUID from the UI. Default demo names are Swift `fredlab` and Weaver
`Acme` / `Research`; IDs belong to your installation. Set three paths to private
files containing only current bearer tokens: each admitted Fred operator, and a
Keycloak realm administrator. Obtain them from the authenticated browser's
network requests after normal login; do not put tokens/passwords in JSON, argv
or shell history. Write a clipboard token without echoing it, for example:

```bash
umask 077
read -rs -p 'Paste the bearer token: ' TOKEN; echo
printf '%s' "$TOKEN" > /absolute/path/to/private/operator-token
unset TOKEN
```

Repeat for the three files and use their paths in the config. Parent directories
must already exist. OAuth tokens expire; refreshing these files never requires
regenerating synthetic passwords. The setup command uses the normal public APIs
and the deployment-owner `assign-model-source` CLI, never direct SQL.

```bash
make k3d-bench-prepare CONFIG=/absolute/path/to/setup.json
# Review the generated private setup.json and all selected scopes, then apply:
make k3d-bench-prepare CONFIG=/absolute/path/to/setup.json APPLY=1
```

The first command is entirely offline and refuses an existing output directory.
`APPLY=1` checks operator admission, matching space names/IDs and available
assistant template before importing anything. It creates the dedicated OAuth
client only if absent, imports the same ordinary-member bundles on replay, waits
for Swift's import result, assigns only `bench-mock` to the selected organization,
refreshes its declared inventory, and appends its one permitted offer with revision
checking. Defaults/title/embedding/vision/reasoning policy fields are preserved.
An explicit local denial is respected. It creates a plain `Bench conversations`
agent in each team, or reuses an equivalent existing one; it never overwrites a
different agent. No terms are accepted, conversation created or load launched.

Keep the output directory (0700/files 0600). `credentials.json` is the client
input; `agents.json` gives the two agent instance IDs and team/space IDs. Resume a
partial setup with the same `APPLY=1` command and original files: accepted Swift
imports are tracked by task ID, existing agents and source assignments reused.
A failed/ambiguous import requires inspection in administration, not blind new
input generation. Details and manual API/UI equivalents remain in
[conversation identities](../local-testing/bench/CONVERSATIONS.md).

Use the **same updated Weaver checkout's** `developer_tools/benchmarks` client
for both targets. Before load, run the identity/terms preflight below for every
selected person, then one ten-turn conversation with runtime/history checks.
Do not treat rendering or successful setup as proof of execution correctness.

### Verify from scratch without touching another lab

This factory currently fixes cluster/context `fred` / `k3d-fred`, service host
ports and local DNS in its Makefile, Helmfiles and cluster configuration. Changing
only a k3d cluster name is **not isolation**. Run the fresh-clone procedure in a
separate machine/VM with its own Docker daemon, kubeconfig and loopback DNS.
On the current machine use rendering checks only; do not run `k3d-wipe`, create a
second cluster on these ports, or claim that a redeploy is a fresh installation.

### Offline recipe checks

With Helm, Helmfile and Python/PyYAML available, run the checked-in generation,
replay, source/default preservation and real-chart rendering checks:

```bash
FRED_WEAVER_SOURCE="$WEAVER_SOURCE" FRED_SWIFT_SOURCE="$SWIFT_SOURCE" \
  MOCK_OPENAI_SOURCE="$MOCK_SOURCE" \
  python3 -m unittest discover -s local-testing/bench -p 'test_*.py' -v
bash -n bin/k3d-app
python3 local-testing/bench/setup.py --help
```

These checks launch no service and make no real API mutation or model call.
Rendered manifests and simulated API replay are not a live fresh-install receipt.

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
make k3d-app-uninstall FRED=bench DIR="$MOCK_SOURCE"
```

This leaves the namespace and the Fred installations in place. `make k3d-wipe`
would instead delete the entire cluster and all application data.
