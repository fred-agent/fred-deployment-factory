# Concurrency benchmarks on k3d

For Fred developers testing parallel requests, contention and isolation. Start with
a working [Weaver installation](../README.md#k3d). Add Swift only if you need a
[comparison](SWIFT-WEAVER.md). Run factory commands from this repository.

The request path is **load client -> Fred -> mock OpenAI -> Fred -> load client**.
Calling the mock directly checks the mock, not Fred's concurrency.

## 1. Deploy the shared mock

With the mock checkout at `~/Work/common/mock-openai-server`:

```bash
make k3d-app-validate FRED=bench DIR="$HOME/Work/common/mock-openai-server"
make k3d-app FRED=bench DIR="$HOME/Work/common/mock-openai-server"
kubectl --context k3d-fred -n fred-bench logs -f deployment/mock-openai-server
```

This builds and imports the image, then deploys one mock in `fred-bench`. Its
default benchmark profile returns fixed text after a non-blocking one-second
delay. Repeat deployment after changing the mock. Its `deploy/k3d/values.yaml`
owns the benchmark settings; root `config.yaml` is for local `make dev`.
The mock checkout's README documents `VALUES` overrides and local port forwarding.

## 2. Connect a benchmark agent

Deploying the mock does **not** change Fred's model configuration. Configure and
explicitly select a dedicated chat model for a benchmark agent:

| Setting | Value |
| --- | --- |
| Base URL, from either Fred namespace | `http://mock-openai-server.fred-bench.svc.cluster.local:8383/v1` |
| Protocol | OpenAI Chat Completions |
| Upstream model | `gpt-4o` |
| Disposable mock API key | `key-1` |

On Swift, use an OpenAI profile in `models_catalog` with `settings.base_url` and
the matching client credential. On Weaver, declare a dedicated source with this
`inference.api_root`, `wire: openai_chat`, a credential binding and a declared
`gpt-4o` offer; allow it through the organization/space model policies. Keep real
model credentials and corpus embeddings unchanged. The mock is shared; model
configuration and agent identifiers remain specific to each Fred installation.

Start with a plain chat agent, without tools, RAG or reasoning. Send one request
through Fred and confirm the fixed answer and a corresponding mock request before
increasing load. The user's JWT authenticates to Fred; `key-1` authenticates Fred
to the mock. They are different credentials.

## 3. Select a compatible load client

Fred's `developer_tools/benchmarks/README.md` documents its Go SSE client and JSON
reports. It currently targets **Swift managed SSE**, using `agent_instance_id`
and `runtime_context.team_id`. Supply a real authorized user JWT via
`AGENTIC_TOKEN`; do not put it in reports or command output.

From a Swift checkout, with `AGENTIC_TOKEN`, `AGENT_INSTANCE_ID` and `TEAM_ID` set:

```bash
cd /path/to/swift/fred/developer_tools/benchmarks
mkdir -p results
make run ARGS="-protocol=sse \
  -url=http://swift.localhost:8088/fred/agents/v2/agents/execute/stream \
  -agent-instance-id=$AGENT_INSTANCE_ID -sse-team-id=$TEAM_ID \
  -message=Hello -clients=1 -requests-per-client=1 \
  -ramp-duration=0s -timeout=30s -json-report=results/smoke.json"
```

**Weaver is not ready for this command unchanged.** The copy of the client in
Weaver still sends `team_id`, whereas Weaver requires `runtime_context.space_id`.
Adapt it against the current execution/session contract and verify one successful
request before measuring load. The factory deploys the mock; it does not supply
a completed Weaver load-client adaptation.

The existing Swift client measures execution through the final SSE event. It does
not include browser rendering or UI preparation calls. For an end-to-end comparison,
include preparation and conversation creation consistently on both versions.

## 4. Increase concurrency and inspect the result

Run 1, then 5, 10 and 20 independent conversations with the same request count,
agent configuration and mock delay. The client keeps a separate session per client
and sends turns sequentially within it. Run Swift and Weaver successively, since
they share the machine and infrastructure. Separate warm-up from measured requests.

Compare completed requests, errors, throughput, total latency p50/p95, in-flight
model calls and pod CPU/memory. With one model call per turn and a one-second
mock delay, independent requests should overlap; growing latency can reveal a
queue, a pool limit or resource saturation. Inspect resource use before attributing
the result to application serialization. The mock's summary logs measure only its
own requests, not Fred's total latency; their `errors` count covers HTTP 5xx only.

Then test separately: simultaneous sends to one conversation (expected admission
or rejection), and execution across multiple Fred replicas (shared-state correctness).
Use a no-delay profile to examine overhead and fixed delays to examine waiting concurrency.
This mock emits its text in one SSE chunk; it does not simulate progressive token
generation. Local k3d results demonstrate behavior under this setup, not production
user capacity.

## Remove the mock

Restore any agent/model selection still using it, then remove only its release:

```bash
make k3d-app-uninstall FRED=bench DIR="$HOME/Work/common/mock-openai-server"
```

This leaves the namespace and the Fred installations in place. `make k3d-wipe`
would instead delete the entire cluster and all application data.
