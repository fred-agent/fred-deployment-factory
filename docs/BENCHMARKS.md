# Weaver benchmarks

Start with a working [k3d installation](../README.md#k3d) and local Fred/mock checkouts. Run deployment
commands from this repository. The mock replaces the model provider; bench calls Fred.

**1. Install the mock.** Skip this if it is already deployed.

```bash
make k3d-app FRED=bench DIR=~/Work/common/mock-openai-server
```

**2. Deploy Weaver with the mock connection.** Both model API keys from the installation steps are
needed for this demo setup.

```bash
make k3d-app FRED=weaver APP=fred DIR=~/Work/weaver/fred \
  VALUES=k3d-apps/fred/models-mock.yaml.gotmpl
```

This reuses the Mistral/Acme and OpenAI/Globex demo configuration and adds
`bench-mock` to Acme, including after bootstrap. Existing model policies stay unchanged.
**Keep the same `VALUES` when redeploying.**

**3. Complete bootstrap and import the Weaver ZIP** ([installation steps 5–6](../README.md#5-become-the-platform-administrator)).
Skip this if already done. The model source is assigned from configuration automatically.

**4. Enable and select the model in Fred.**

- As **Alice**, select **Acme → Features → Models**, click **Refresh**, then enable **Bench Mock GPT-4o**.
- As **Bob**, open **Research** and select that model for the assistant you will benchmark.
- Send a question. The default mock replies **“Mock benchmark response.”**

**5. Run the benchmark.** Requires Go 1.24.0; build again after updating Fred.

```bash
cd ~/Work/weaver/fred/developer_tools/benchmarks
./build.sh
./bench run --mode performance
```

Sign in as Bob and select the same space and assistant. Performance mode measures
1,000 questions with up to 10 concurrent conversations, without requesting server
traces. Results are saved under `.bench/`; `./bench --help` lists the options.

For paced streaming, redeploy the **mock** with `VALUES=k3d-apps/bench/streaming.yaml`.
Fred's values configure the connection and Acme's access, not mock responses.

## Diagnostic traces

Optional developer diagnostics. In `k3d/values.yaml`, update these fields under
`otelCollector`, keeping its other settings:

```yaml
otelCollector:
  enabled: true
  fredCheckout: /absolute/path/to/weaver/fred
```

From this repository, prepare the Collector and redeploy Weaver with both
values files:

```bash
make k3d-up
make k3d-app FRED=weaver APP=fred DIR=~/Work/weaver/fred \
  VALUES="k3d-apps/fred/models-mock.yaml.gotmpl k3d-apps/fred/diagnostic.yaml"
```

Keep these options on later deployments. Then run from the benchmark directory:

```bash
./bench run --mode diagnostic
```

Diagnostic mode requests traces for 10 questions in one conversation. Fred's YAML
selects `observability.tracer: diagnostic`; no tracing environment variable is needed.
The bench retrieves available technical spans without prompts or answers. Changing
bench modes needs no redeployment. Traces may be incomplete; this is not production
observability. Collector files rotate at 50 MiB with five backups; a cluster wipe
deletes them.

For advanced scenarios, see the [bench client guide](https://github.com/ThalesGroup/fred/blob/weaver/developer_tools/benchmarks/README.md).
For separate test accounts, see [identity setup](../local-testing/bench/CONVERSATIONS.md).
