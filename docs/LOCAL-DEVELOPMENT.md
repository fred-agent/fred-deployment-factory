# Local development stack

Run Fred's backing services on your laptop — for day-to-day development against a local Fred,
or to host the auth/isolation validation release gate, which now lives in the sibling `fred`
monorepo's own `validation/README.md` (run `make integration-test-docker` or
`make integration-test-k3d` from that checkout after preparing the test prerequisites). Fred itself
can run on just ChromaDB + SQLite + the local filesystem; this repo gives the fuller
experience (real Postgres, Keycloak, OpenFGA, OpenSearch, Temporal, plus optional
Prometheus / Grafana / ClickHouse / Langfuse).

Two ways to run it:

- **Docker Compose** (default, simplest). The infrastructure runs in containers and the Fred
  apps run on your machine (`make run` in `fred`). Start at "Quick start" below.
- **k3d**. The infrastructure and the Fred apps all run in a local Kubernetes cluster, with
  the production Helm chart. Go straight to
  ["k3d: the full stack in Kubernetes"](#k3d-the-full-stack-in-kubernetes).

For the raw Compose internals (shared network, `.env`, per-service files) see
[`../docker/README.md`](../docker/README.md).

**Prerequisites (Compose):** Docker, Docker Compose (`docker compose`), `bash`.

## Quick start (Docker Compose)

```bash
make docker-up                  # base stack: core Fred services
make docker-up STACK=extended   # + Prometheus, Grafana, ClickHouse, Langfuse
```

Optional — browser SSO callbacks to Keycloak on localhost:

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

The Keycloak post-install ensures that browser access tokens include the `app`
audience required by Fred's local C3 API profiles. This does not enable delegated
execution. To repair an existing realm after updating this checkout, run:

```bash
KEYCLOAK_FORCE_RELOGIN=false bash docker/keycloak/keycloak-post-install.sh
```

Then sign out and sign in again to obtain a new token. Re-running the script
updates the same audience mapper without creating duplicates.

Pausing and resuming (a reboot, or closing the laptop for the day):

```bash
make docker-stop     # stop the containers, keep them
make docker-start    # resume them, in dependency order
```

`docker-start` is not `docker-up`: it recreates no container and re-runs no
post-install job, so the Keycloak realm, the OpenFGA store and every volume come
back untouched. Use it whenever the stack exists but is down; use `docker-up`
only to build the stack from nothing. Services carry `restart: unless-stopped`,
so after a host reboot they come back on their own — unless you stopped them
with `docker-stop`, which is remembered.

Cleanup:

```bash
make docker-down       # stop AND remove the containers (next start re-provisions)
make docker-wipe       # containers & volumes
make docker-destroy    # containers, volumes, network, and images
```

Extended-profile endpoints: Prometheus `:9090`, Grafana `:3002`, ClickHouse `:8123/play`,
Langfuse `:3001`. Per-service targets also exist (`make keycloak-up`, `make opensearch-up`,
`make openfga-up`, `make temporal-up`, …).

## Full bootstrap walkthrough: from `docker-up` to a validated platform

`make docker-up` only gives you empty infra (§"What `docker-up` / `k3d-up` provisions"
below) — zero users, zero teams, zero apps running. This is the exact, copy-pasteable
sequence to go from that empty infra to a `platform_admin` account, demo data, all four
Fred apps running prod-like, and both automated and UI-driven validation green. **Every
step matters — skipping step 1 is the single most common cause of "works on my machine,
fails in review."** All `make` commands below run inside the sibling `fred` monorepo
checkout, not this repo.

> **Fast path.** `make setup-env` (once) → `make run` → `cd apps/control-plane-backend
> && make bootstrap-local BOOTSTRAP_USER=<you> BOOTSTRAP_PASSWORD=<pw>` gets you steps
> 1-3 in one line, pausing only for the one step that has to stay manual (registering
> yourself in Keycloak, see step 3 below). Before importing the demo bundle (step 4),
> populate its 15 named users in Keycloak — one command from **this** repo,
> `local-testing/demo/seed-keycloak-users.sh` (see step 4). Then `make
> activate-all-capabilities BOOTSTRAP_USER=<you> BOOTSTRAP_PASSWORD=<pw>` (step 5b) — or
> the same two actions from the UI once the frontend is up, **Admin > Migration** and
> **Admin > Capabilities**. Read on if you want to understand each step, if something
> fails and you need to debug by hand, or if you don't want the demo bundle.

> **Since CAPAB-01 / CTRLP-14 (2026-07-17): don't skip step 5b.** Every tool (MCP
> server) and every agent template is now admin-gated by default, platform-wide —
> matching production policy. Importing the demo bundle (step 4) creates the demo
> teams with **zero usable tools and zero visible agent templates** — that's expected,
> not broken. If you stop after step 2 and jump straight to the frontend or
> `make validation-report`, every demo user looks like they have no agents at all.
> Step 5b is the one-time admin action that turns that on — it's still a manual step
> today (we're converging on a better default — see the note at the end of 5b) but it
> only takes two commands, or one click of "select all" in **Admin > Capabilities**.

**0. Infra up** (this repo)

```bash
make docker-up   # Keycloak, Postgres, OpenFGA, OpenSearch, Temporal — infra only, zero business data
```

**1. Prepare the three backends' `.env` files** (`fred` repo root)

```bash
make setup-env
```

Creates each backend's `.env` from its `.env.template` if missing, fills in every
blank secret placeholder (Keycloak client secrets, `OPENFGA_API_TOKEN`, Postgres/
OpenSearch/MinIO passwords) with the same fixed local value this repo seeds
everywhere (`Azerty123_`), points `CONFIG_FILE` at `configuration_prod.yaml` in all
three — the one config each app ships that actually matches deployed behaviour (real
ports, `bootstrap_token_file`, real backends) — and prompts once for a model provider
API key. Never overwrites a value you already set; safe to re-run any time.

**2. Start every Fred app** (`fred` repo root)

```bash
make run          # control-plane :8222, fred-agents :8000, knowledge-flow :8111, frontend :5173
```

One terminal, `Ctrl+C` stops all four. (Prefer separate terminals for debugging one
app at a time? `make run-control-plane`, `make run-fred-agents`,
`make run-knowledge-flow`, `make run-frontend` — each also exist standalone.)

**3. Become `platform_admin` — the AUTHZ-07 root bootstrap** (second terminal, `fred/apps/control-plane-backend`)

Fred never creates accounts in Keycloak, on purpose: **Keycloak authenticates, Fred/
OpenFGA authorizes** (`docs/swift/platform/REBAC.md` in the `fred` repo) — the same
boundary a real SSO deployment has, so a compromised or buggy Fred can never mint
identities in your corporate IdP. That means the one unavoidable manual step: self-
register a user through **Keycloak's own** registration screen — no Fred frontend
needed yet: open `http://localhost:8080/realms/app/account` → "Register". Then:

```bash
make bootstrap-local BOOTSTRAP_USER=<your-username> BOOTSTRAP_PASSWORD=<your-password>
```

Runs `bootstrap-token` (writes `target/bootstrap-token`; never overwrites, never
printed by the app), pauses once for you to confirm you've registered above, then
logs in and bootstraps in one shot. One-shot and permanent — a second run reports
"already platform_admin" instead of erroring. You are now the platform's root
`platform_admin`.

**4. Import the demo dataset**

The import assigns teams/roles to the 15 named demo users (`alice`, `bob`, `marc`, …). Unlike
step 3's identity boundary, the import path *can* create a missing Keycloak identity for
you (when the bundle entry carries a `password`, which the demo fixture's entries all
do) — but relying on that is slower per-user than a bulk seed, and it still fails closed
(aborts the whole import, doesn't silently skip) on any username it can't resolve either
way. Populate them first, one command, from **this** repo:

```bash
cd ../fred-deployment-factory/local-testing/demo
./seed-keycloak-users.sh    # reads the 15 usernames from fred's users.json, idempotent
```

This script (and this repo's other `local-testing/` scripts) assume `fred` and
`fred-deployment-factory` are checked out as **sibling directories** under the same
parent — override with `SWIFT_SRC=/path/to/fred ./seed-keycloak-users.sh` if yours
isn't laid out that way. The script prints exactly which path it's checking before it
can fail, so a wrong layout is never a silent mystery.

Then, back in `fred/apps/control-plane-backend`:

```bash
TOKEN=$(curl -s http://localhost:8080/realms/app/protocol/openid-connect/token \
  -d grant_type=password -d client_id=app \
  -d username=<your-username> -d password=<your-password> \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

make build-demo-bundle    # zips tests/fixtures/import_export/demo_provisioning/ → target/demo-provisioning-bundle.zip

curl -s -X POST http://localhost:8222/control-plane/v1/import-export/import \
  -H "Authorization: Bearer $TOKEN" -F file=@target/demo-provisioning-bundle.zip
```

Same effect as uploading from **Admin → Migration** in the UI once the frontend is up.
See the `fred` monorepo's `validation/README.md` for who's who and why, or this repo's
[`local-testing/demo/README.md`](../local-testing/demo/README.md) for a local quick-reference.
Import runs async (returns a `task_id`); give it a few seconds before moving on.

Want a much larger, statistically-varied dataset instead (3000 users / 100 teams, for
OpenFGA-at-scale testing)? See [`local-testing/bench/README.md`](../local-testing/bench/README.md).

**5. (merged into step 2)** Every app — `fred-agents`, `knowledge-flow-backend`,
`frontend` — is already running: `make run` in step 2 started all four together.
Nothing further to do here.

**5b. Authorize Tools and Agents for the demo teams (CAPAB-01 / CTRLP-14)**

Every capability — every MCP tool *and* every agent template — is `admin_gated`: a
team can't see or use one until a `platform_admin` explicitly grants it. Nothing
earlier in this walkthrough does that (import only provisions
identities/teams/roles, not capability grants), so right now every demo team has an
empty toolbox and an empty agent-template list. Simplest local-dev fix: flip every
capability to platform-wide `default_on` — a deliberate admin action via this API,
not a manifest default, so it doesn't violate the "nothing ships
admin-gated-by-default" policy it's gating.

`fred-agents` is already up since step 2, so this works right away — no ordering
gotcha to worry about. From `fred/apps/control-plane-backend`:

```bash
make activate-all-capabilities BOOTSTRAP_USER=<your-username> BOOTSTRAP_PASSWORD=<your-password>
```

Wraps the same GET `/admin/capabilities` → PUT `.../default-on` loop this used to be —
one command, no `jq` dependency, an actionable error if `fred-agents` isn't reachable
yet (check its terminal from step 2) instead of a silent empty list.

A capability with *required* team settings refuses default-on (`409`, reported, not
fatal) — it needs a value only a team can supply, so it can't have a platform-wide
default. For those, grant it to one demo team explicitly instead, with whatever
settings it needs (needs a token — reuse the snippet from step 4):

```bash
curl -s -X PUT "http://localhost:8222/control-plane/v1/admin/capabilities/<id>/teams/<team_id>" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"settings": {}}'
```

None of the current demo/stock capabilities require this — `activate-all-capabilities`
above is normally enough. Same effect as **Admin → Capabilities** in the UI once the frontend is up —
a "Tools" / "Agents" toggle at the top filters the same catalog by `kind`, and both
are just admin actions on top of what this step already did.

*Why this is a manual step today:* the demo bundle predates per-team capability
grants and doesn't provision them; the "right" fix is a better default at import
time, still being worked out. Until then, this is the one extra hop — do it once,
right after step 5, and everything downstream (agents having tools, templates being
visible, `validation-report`, the self-test) behaves exactly like before.

**6. Run the automated cross-app validation suite** (from the `fred` repo root)

Prepare password-grant login and the test team's agent/capability/model access as
explained in [Fred's validation prerequisites](https://github.com/ThalesGroup/fred/blob/swift/validation/README.md#prerequisites).
A successful browser login does not prove that password-grant login is enabled.
For the Docker setup in this walkthrough:

```bash
make integration-test-docker
```

Logs in as every demo user from step 4 and asserts the full authorization matrix
end-to-end. Writes `validation/report.md` (PASS/FAIL grouped by real-world claim, not
by test name) and returns pytest's exit code. See `fred`'s `validation/README.md` for
what it checks.

Failures here that look like "no tools available", "template not found", or an agent
answering with none of its expected capabilities almost always mean step 5b was
skipped — go back and run it.

**7. Finish with the UI self-test** (VALID-02 — real pipeline, no mocks, browser-driven)

Log into the frontend (`http://localhost:5173`) as the `platform_admin` from step 3 →
**Admin → Self-test** (`/admin/self-test`) → run it. It drives create-folder → ingest →
real agent execution → assert marker → delete through the actual browser UI — the one
check the pytest suite in step 6 cannot do for you.

## Identity provider portability

The default `make docker-up` path remains the Keycloak baseline. These opt-in
local profiles accompany [Fred issue #2862](https://github.com/ThalesGroup/fred/issues/2862)
and [draft PR #2863](https://github.com/ThalesGroup/fred/pull/2863). Follow the
full bootstrap walkthrough above for each profile; run `make validation-report`
from the sibling `fred` checkout after starting its applications. The UI
self-test still needs a browser. Use a fresh test deployment when comparing
provider identities, personal spaces or administrator bootstrap state.

1. **Keycloak baseline:** run the walkthrough above without an OIDC overlay.
   Save it with `make checkpoint-save NAME=kc-baseline` before changing the realm.
2. **Keycloak with generic OIDC claims:** run `make keycloak-generic-oidc STRICT=1`,
   generate the three Fred backend configs with
   `scripts/prepare_identity_provider_configs.py --profile generic_oidc`, and restart
   the Fred applications. Run `local-testing/demo/seed-keycloak-users.sh`, then
   `local-testing/scripts/warm-local-directory.sh` before importing the demo
   bundle. The strict profile removes legacy role claims and Keycloak Admin API
   rights from the service accounts. Use `make keycloak-generic-oidc-revert` to
   restore the baseline realm settings.
3. **Mock OIDC, without Keycloak:** run `make mock-oidc-up`, generate the
   Fred configs with `scripts/prepare_identity_provider_configs.py --profile mock_oidc`,
   restart Fred, and stop
   Keycloak with `docker stop app-keycloak`. The mock issuer is
   `http://localhost:8090/fred`. After testing, run `make mock-oidc-down` and
   restore the Keycloak checkpoint.
4. **Microsoft Entra ID:** follow the app registrations and generator command in
   `fred/docs/swift/platform/IDENTITY-PROVIDERS.md`. Supply six public UUIDs,
   workload secrets through the environment and the configured token lifetime;
   then run the Fred validation report and UI self-test against that tenant.
5. **ZITADEL:** run `make zitadel-configure SWIFT_SRC=../fred` or the matching
   Fred VS Code launch task. The factory provisions clients and generates
   configs and a private credentials file under `/tmp/fred-idp-tests/zitadel/`.
   Follow the ZITADEL procedure below for identity and delegation checks.

Use `make checkpoint-restore NAME=kc-baseline` followed by `make docker-up` to
return to the saved baseline without reprovisioning from scratch. Keep each
profile's complete configuration in a separate temporary `CONFIG_FILE`.
Use the Fred generator or the ZITADEL provisioner: the tracked example overlays
are references, not launchable `CONFIG_FILE` values. These commands prepare
host-run Fred applications; Kubernetes provider rollout uses Fred's chart and
migration guide and still needs a fresh deployment and administrator self-test.

## Stack profiles: `base` vs `extended`

`STACK` selects which services launch, for both `make docker-up` and `make k3d-up`:

| `STACK` | Services |
|---------|----------|
| `base` (default) | Minimal stack — Docker drops ClickHouse, Langfuse, Redis, Prometheus, Grafana; k3d drops ClickHouse only |
| `extended` | Full stack, including ClickHouse, Langfuse (+ Redis, Docker only), Prometheus, Grafana |

For Helm this maps to the chart value `stack` (`--set stack=<profile>`). On k3d,
observability (Prometheus, Grafana, Fluent Bit log collection) is part of both profiles,
each behind its own `enabled` flag; ClickHouse deploys only when `stack=extended` and
`clickhouse.enabled`.

## k3d: the full stack in Kubernetes

The infrastructure **and** the applications run in a local k3d cluster. This repository
owns the infrastructure (`make k3d-up`, chart `k3d/`). Each application (Fred, the
evaluation application, a knowledge base...) is deployed from **its own repository**, with
its own chart and its own k3d values, by `make k3d-app DIR=<its checkout>` (see "The k3d
application contract" below). Fred's k3d values keep the posture production uses (security
profile `c3`, delegation, migration Job, every credential read from one Foundation Secret).
The k3d stack is independent of the Docker Compose stack: don't run both at once, because
they use the same host ports.

**Prerequisites:** Docker, [`k3d`](https://k3d.io)
(`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`), `kubectl`,
`helm` (3 or 4), [Helmfile](https://github.com/helmfile/helmfile/releases) (verify the
archive against its published checksums; tested: Helmfile 1.8.1, Helm 3.21.2), `jq`, and
a `fred` checkout. Disk: `make k3d-create`, `k3d-up` and `k3d-app` stop under 10 GiB free
where Docker stores its data, and warn under 30 (`K3D_DISK_FAIL_GB`, `K3D_DISK_WARN_GB`). They
name the cleanup commands and never run them.

**1. Make `keycloak` resolve to your machine** (once). Fred sends the browser to
`http://keycloak:8080` to log in, the same address the pods use inside the cluster:

```bash
grep -qw keycloak /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

**2. Infrastructure** (this repo): creates the cluster `fred` and installs the release
`fred-stack` into the namespace `fred`:

```bash
make k3d-up
```

**3. Your model API key** (once per cluster), as an operator supplies it before installing
Fred anywhere: a Secret the Fred values read by reference. `make k3d-app APP=fred` stops
until it exists; Fred's pods would not start without it.

```bash
kubectl --context k3d-fred -n fred create secret generic fred-model-credentials \
  --from-literal=OPENAI_API_KEY=<your key>
```

The k3d values call Mistral through its OpenAI-compatible API: the key is a Mistral key.
To turn web research (Brave Search) on, add its Secret and a values file:

```bash
kubectl --context k3d-fred -n fred create secret generic fred-web-research-credentials \
  --from-literal=WEB_RESEARCH_PROVIDER_KEY=<your key>
cat > web-research.yaml <<'YAML'
applications:
  fred-agents:
    configuration:
      web_research:
        enabled: true
YAML
make k3d-app APP=fred VALUES=web-research.yaml
```

**4. Fred** (this repo): installs the release `fred-app` from Fred's published chart and
images, at the version pinned in `k3d-apps/fred/helmfile.yaml.gotmpl` (`RELEASE=<version>`
for another one), waiting until every pod is ready. No checkout, no build. As long as
nobody is `platform_admin` yet, it ends with a command to retrieve the root bootstrap
token:

```bash
make k3d-app APP=fred
```

To test the PyMuPDF variant of knowledge-flow (the `knowledge-flow-backend-pymupdf` image
and the PyMuPDF processors in every profile), add `VALUES=k3d-apps/fred/pymupdf.yaml`;
redeploy without it to go back. Published releases only.

To deploy your own `fred` checkout instead, add `DIR=../fred`: its chart, and the four
images its `deploy/k3d/build` builds and copies into the cluster, with the same values.

**5. First login, in Fred.** Open <http://localhost:8088>. Fred sends you to the Keycloak
login page: create your account with **Register** (Fred never creates accounts itself).
Back in Fred, a page asks for the bootstrap token: retrieve it with the command `make k3d-app` prints, then paste it.
Your account becomes the platform's `platform_admin`; this works once per platform, the
first account keeps the role. Then turn the tools and agent templates on in
**Admin > Capabilities** (select all).

**6. The evaluation application** (optional, this repo): deploys its published chart and
images next to Fred (`DIR=../fred-agent-evaluator` to build a checkout instead). Fred
already knows the application (`application_sources` in `k3d-apps/fred/values.yaml`); it
shows up once a platform admin enables `evaluation` for a team in **Admin > Features**
(filter "app").

```bash
make k3d-app APP=fred-evaluator
```

**7. The Knowledge Bases** (optional, this repo): `APP=webdav-kb` deploys the WebDAV
Knowledge Base's published chart and image (`DIR=../webdav-knowledge-base` to build a
checkout instead). Fred already lets it publish (`knowledge_bases.publishers` in
`k3d-apps/fred/values.yaml`); it shows up once a platform admin enables it for a team in
**Admin > Features > Knowledge Bases**.

```bash
make k3d-app APP=webdav-kb
```

| URL | What |
| --- | --- |
| <http://localhost:8088> | Fred: the frontend and every app API, through the Traefik ingress |
| <http://localhost:8088/apps/evaluation/> | The evaluation application, inside Fred |
| <http://keycloak:8080> | Keycloak: login, registration, admin console |
| <http://localhost:8233> | Temporal UI |
| <http://localhost:3002> | Grafana (`admin` / `Azerty123_`): folder **Fred**, the dashboards of the Fred checkout (with `DIR`) |
| <http://localhost:9090> | Prometheus: the apps' KPIs, scraped from every `metrics` port |
| <http://localhost:5601> | OpenSearch Dashboards (`admin` / `FredOpensearch123!!`): Discover on `k3d-logs*` (every pod's output), `k3d-events*` (Kubernetes events), `app-logs-index*` |

Other infrastructure host ports, for tools running on your machine: Postgres `:5432`,
SeaweedFS S3 `:8333`, OpenSearch `:9200`, OpenFGA HTTP `:9080` / gRPC `:9081`, Temporal
gRPC `:7233`. With `STACK=extended`, you also get ClickHouse `:8123`. Override any of
them with `K3D_HOST_PORT_*`.

**Finding a problem.** Fluent Bit ships every pod's output and the Kubernetes events to
OpenSearch; Prometheus scrapes the apps' KPIs. `make k3d-health` (or `bin/k3d-observe
health`) shows, on one screen, the containers restarted and why (OOMKilled...), the
Kubernetes warnings, the errors and HTTP 5xx per service, the features a service switched
off at startup, the Prometheus targets down and the workflows running. Then
`bin/k3d-observe trace <run, workflow or document id>`, `logs '<query>'`, `kpi` and
`promql '<expr>'`. The `k3d-observability` skill describes the method.

**Day to day** (this repo):
- `make k3d-app APP=fred DIR=../fred` (or `DIR=<checkout>` for an application defined in
  its own repository) after any change, in code or in the application's values: it rebuilds
  (from Docker's cache), copies the images and rolls out whatever changed. Without `DIR`,
  `make k3d-app APP=<app>` goes back to the published release. `VALUES="a.yaml b.yaml"`
  adds values files, last, to every release.
- `make k3d-app-validate APP=<app>` (or `DIR=<checkout>`) lints and renders,
  schema-checked, without a build or a cluster change (with the images of the last build,
  if any).
- `make k3d-status` shows the pods.

**Tear down** (this repo):
- `make k3d-app-uninstall APP=<app>` (or `DIR=<checkout>`) removes an application's releases (it refuses a
  release that owns volumes). The infrastructure holding their data stays.
- `make k3d-down` stops the cluster and frees the host ports; `make k3d-up` starts it again.
- `make k3d-delete` deletes the cluster.
- `make k3d-wipe` uninstalls the infrastructure release and deletes the cluster; use it to
  restart from scratch.

`make k3d-up` and `make k3d-app` are both safe to rerun: they converge. Optional Cilium
(`K3D_USE_CILIUM=true`) is only needed for `CiliumNetworkPolicy` / air-gap flows.

### Prepare k3d for Fred integration tests

Run the harness from the **Fred checkout**, after deploying the applications and
importing the demo bundle through **Admin > Migration**. The factory provisions
infrastructure; it does not prepare all the authorizations required by these tests.
The detailed, authoritative procedure lives in
[Fred's validation README](https://github.com/ThalesGroup/fred/blob/swift/validation/README.md#run-against-the-existing-k3d-deployment).

Before the first run:

- **Use the trusted realm address.** The workstation's `keycloak` alias must resolve
  to `127.0.0.1`. Fred's pods trust `http://keycloak:8080/realms/app`; requesting a
  token through `localhost` can produce an issuer they reject. Fred's public APIs
  use the ingress on `http://localhost:8088`.
- **Allow the harness to log in as the demo users.** In the Keycloak admin console
  at `http://keycloak:8080`, select realm **app**, then
  `Clients > app > Settings > Capability config`. Switch **Direct access grants**
  **On** and **Save**.
  Record the original value. The factory defaults it to **Off**: browser sign-in
  uses the authorization-code flow, whereas the harness needs the password grant
  to exercise each demo identity without a browser. This enables authentication;
  it does not give those users additional Fred roles. No restart is needed.
- **Allow the test agent, document capability and model for the test team.** In
  Fred's **Admin > Features**, enable **Test Assistant (no LLM)**,
  **document_access** and the configured default chat model for `fredlab` (or your
  `FRED_TEST_TEAM`), via a platform default or explicit team grant. Record changes.
  A running runtime pod does not imply team access. Graph-agent activation checks
  model authorization even when the diagnostic agent makes no chat LLM call.
  Document tests also require the Knowledge Flow worker and working embeddings.

Then, from your Fred checkout:

```bash
make integration-test-k3d
```

This selects the endpoint URLs and writes `validation/report.md` and
`validation/report.xml`. It does not deploy services, import demos, or change
Keycloak/Fred permissions. `make validation-report` remains the configurable
entry point; its default direct application ports do not target k3d.

**Keep the prerequisites enabled for the whole manual testing session**, including
reruns. Restore the recorded settings when that session ends. If they are restored
between runs, the next Make invocation fails again. Recheck after a fresh cluster
or infrastructure reprovisioning; do not change the shared realm templates or
production settings to accommodate local tests.

Repeated setup errors mentioning `Keycloak login/refresh failed for 'alice'` and
`Keycloak rejected the password grant` mean the common setup could not authenticate
its demo administrator. They do not represent hundreds of independent isolation
failures. `ModelNotUsableError` means the test team's configured model is unavailable.
The **Admin > Self-test** UI uses the already signed-in browser token, so its success
does not verify the harness's password-grant prerequisite.

### The k3d application contract

An application is defined by the files below, in one of two places:

- **here, `k3d-apps/<APP>/`**, for Fred's open-source applications (`fred`, `fred-evaluator`,
  `webdav-kb`):
  the instance's values, deployed from the published chart and images (`APP=<app>`,
  `RELEASE=<version>` or the version the helmfile pins, bumped by a Renovate PR after each release and validated by `.github/workflows/validate.yml`). Their
  repositories keep only `deploy/k3d/build`: with `DIR=<checkout>`, the engine runs it and
  exports `K3D_APP_CHECKOUT`, from which the helmfile takes the chart. `RELEASE` and `DIR`
  exclude each other; a `RELEASE` that is not a version (`latest`) is refused.
- **in the application's repository**, for any other application: `DIR` is a checkout whose
  `deploy/k3d/` holds them, or that directory itself (a repository with several applications,
  e.g. `DIR=../fred-samples/knowledge-bases/webdav`). Nothing about it lives here.

| File | Required | What |
| --- | --- | --- |
| `helmfile.yaml.gotmpl` | yes | Its releases: its charts, its k3d values, then `K3D_IMAGE_VALUES` when set. Ordinary Helmfile, no `exec`; one hook only, for a checkout's chart with dependencies (a Knowledge Base's on Fred's `knowledge-base`): `bin/k3d-chart-stage` copies it to `$K3D_APP_OUT/chart` and fetches them there, from `FRED_REPO` with `FRED_LIBS=local` |
| `values.yaml` | by convention | Its k3d values, every block labelled `address`, `secret`, `posture`, `choice`, `models` or `sizing` |
| `identities.yaml` | no | Its service clients in Keycloak, the `fred-secrets` key of each one's secret, and the roles granted (below) |
| `build` | no | Builds its images; writes `$K3D_APP_OUT/images.txt` (one reference per line, tagged by content) and `$K3D_APP_OUT/images.yaml` (the Helm values selecting them) |
| `prepare` | no | Runs before the sync (read-only checks: Fred, its operator Secret exists; the evaluator, Fred runs). Never writes a credential |
| `finish` | no | Runs after the sync (Fred: its Grafana dashboards, how to log in) |

With `APP=<name> DIR=<checkout>`, a `deploy/k3d/helmfile.yaml.gotmpl` in the
checkout takes precedence over the factory definition, including its identities
and prepare/finish hooks. Without it, the factory definition is unchanged.
`K3D_FACTORY_ROOT` exposes this factory checkout for shared instance values;
`K3D_APP_VALUES` lists the absolute extra values paths, one per line, so a
prepare hook can render the same configuration as the deployment.

`build`, `prepare` and `finish` are executables run from their directory with
`KUBE_CONTEXT`, `K3D_CLUSTER`, `K3D_NAMESPACE`, `K3D_APP_OUT`, `K3D_HOST_PORT_FRONTEND`,
`K3D_HOST_PORT_GRAFANA`, `ENV`, `K3D_PUBLIC_URL`, `K3D_REALM_URL`, `RELEASE`, `K3D_APP_CHECKOUT`, `FRED_LIBS` and `FRED_REPO` (below,
"Work on unreleased fred"). Without a build, the charts' own images run.
A cluster call targets `--context "$KUBE_CONTEXT"`, never the current context.

`make k3d-app` (`bin/k3d-app.sh`) checks and renders first (a mistake costs seconds, not
a build), runs `build`, renders again with the new images, copies them into every node,
provisions the identities, runs `prepare`, recovers each release Helm would refuse (`bin/k3d-helm-recover.sh`),
syncs with `--wait`, then runs `finish`. The factory passes the kube context and the
namespace (`K3D_NAMESPACE`, default `fred`); the current kubectl context is left unchanged.
Build logs and image values stay in this repository's ignored
`.cache/k3d-apps/<cluster>/<namespace>/<application>-<checkout-hash>/`.
Build hooks receive an `IMAGE_TAG` specific to that cluster and checkout; product
Makefiles must honor it, then publish content-tagged references in `images.txt`. Helm's
lint keeps the `null` deletion markers the fred schema refuses, so lint skips the schema;
**template and sync enforce it**.

What an application can rely on, the **platform contract**: the namespace `fred`; the
infrastructure services by name (`postgres:5432`,
`opensearch:9200`, `openfga:9080`, `temporal:7233`, `seaweedfs:8333`); the OIDC issuer
from `K3D_REALM_URL` (realm `app`); and the credentials
of `fred-secrets` (`k3d/templates/secret.yaml`), plus the operator's own Secrets
(`fred-model-credentials`), read by `secretKeyRef`, never copied into a values file. Fred learns about an application through its own k3d values
(`application_sources`, `FRONTEND_APPLICATIONS_JSON`).

**Identities.** The application says what it needs; this repository decides how:

```yaml
# deploy/k3d/identities.yaml
clients:
  - id: fred-evaluation-worker                 # a confidential client with a service account
    secret: KEYCLOAK_EVAL_WORKER_CLIENT_SECRET # its key in fred-secrets
    grants: [app/service_agent]                # <client>/<role> for its service account
```

`bin/k3d-identities` generates the secret once into `fred-secrets` when the key is absent
(and never rewrites it), creates or fixes the client in the realm `app` with that secret,
and adds each grant. It never deletes. The application's values read the secret by
`secretKeyRef`; nothing in the application holds Keycloak's admin. Refused: a platform
client id (those of `k3d/files/keycloak/app-realm.json.template`, and `fred-delegation`)
and any `realm-management` role beyond `query-users`, `view-users`, `manage-users`.
`fred-secrets` keeps every key its template does not manage, so `make k3d-up` never drops
an application's secret. The platform's own identities (the realm, the `app` client and its
roles, Fred's backend clients) stay in `k3d/files/scripts/keycloak-post-install-k8s.sh`,
which shares its Keycloak functions with `bin/k3d-identities` (`keycloak-lib.sh`).

Docker Compose does not read these files: it is the fast loop to debug an app, and
`docker/keycloak/keycloak-post-install.sh` gives the apps fixed identities with local
default secrets.

Once built, the standard Helmfile commands work on their own:

```bash
helmfile -f k3d-apps/fred/helmfile.yaml.gotmpl --kube-context k3d-fred -n fred template --skip-deps
```

### Agent code sandbox on k3d

Use a Fred checkout containing `apps/sandbox-broker` and `deploy/sandbox/agent-sandbox.yaml`.
This local bootstrap currently requires an x86_64 host, `yq` v4 and Python PyYAML for the Fred values overlay.
Create the cluster with its own registry and a kubelet limit of 512 PIDs per Pod.
The limit also applies to Keycloak and OpenSearch, which need more than 64:

```bash
make k3d-up ENV=secondary K3D_AGENT_SANDBOX=true FRED_REPO=../fred
make k3d-sandbox-smoke ENV=secondary
```

With `K3D_AGENT_SANDBOX=true`, `k3d-up` installs the checksum-pinned gVisor release on each k3d node, then
the checksum-pinned SIG Agent Sandbox manifest and four CRDs. The controller
image is pinned by digest. The command also installs the
checksum-pinned rclone CSI chart in the privileged `fred-sandbox-csi` namespace,
and applies Fred's `fred-sandbox-webdav` StorageClass. Custom RBAC limits the CSI
controller's Secret reads to `fred-sandbox`. Broker file-mount RBAC is deferred
until Fred's file-backed profile is enabled.
The CSI node plugin needs FUSE and privileged host mount access; it does not run
inside sandbox Pods. The command pushes the approved
`python:3.12-slim` image and the broker built from `FRED_REPO` to the cluster's registry,
using digest references in the SandboxTemplate and broker Deployment. The namespace has
a deny-all NetworkPolicy, Restricted Pod Security, a resource quota, and broker RBAC.
It checks CNI enforcement with a control Pod before starting the broker.
The `SandboxWarmPool` has zero replicas. The smoke command executes Python and Bash
through the live HTTPS broker, checks that the Pod runs under gVisor with the
registry image, and mounts a disposable read-only WebDAV file into another gVisor
Pod through rclone CSI. Broker credentials and its local CA stay in `.cache/agent-sandbox/`
and Kubernetes Secrets, not in Git.
For document analysis, replace the slim guest image with a pinned image containing
`openpyxl`, `pypdf`, `python-docx`, `python-pptx`, `pandas` and `duckdb`, installed with `uv` from
this repository's `k3d/agent-sandbox/python-documents.Dockerfile`:

```bash
make k3d-sandbox-up ENV=secondary FRED_REPO=../fred SANDBOX_PYTHON_PROFILE=documents
make k3d-sandbox-smoke ENV=secondary
```

This rebuilds only the sandbox components. The default `slim` profile remains
available for a smaller execution image. Both profiles are pushed to the local
registry by digest; neither is selected by the agent or by code inside the guest.
If the file gateway uses a private CA, create its CA ConfigMap in `fred-sandbox-csi`
and pass an operator-owned Helm values overlay with `SANDBOX_CSI_VALUES=<path>`.
The overlay can mount that CA into the controller and node plugin and set
`SSL_CERT_FILE`; it is reapplied on every `k3d-up` so a restart keeps TLS trust.

`k3d-create` skips an existing cluster. If it was created without
`K3D_AGENT_SANDBOX=true`, the sandbox step fails because its registry is missing.
`make k3d-sandbox-up` remains available to reconcile the sandbox components without
redeploying the infrastructure release.
Recreate only a disposable environment after backing up anything needed; deleting a
cluster deletes its data. For a standalone test with no Fred infrastructure:

```bash
k3d cluster create fred-sandbox-test --servers 1 --agents 0 --wait \
  --kubeconfig-switch-context=false \
  --registry-create fred-sandbox-test-registry \
  --k3s-arg '--kubelet-arg=pod-max-pids=512@server:*'
K3D_CLUSTER=fred-sandbox-test KUBE_CONTEXT=k3d-fred-sandbox-test \
  FRED_REPO=../fred bin/k3d-agent-sandbox.sh up
K3D_CLUSTER=fred-sandbox-test KUBE_CONTEXT=k3d-fred-sandbox-test \
  bin/k3d-agent-sandbox.sh smoke
k3d cluster delete fred-sandbox-test
```

After the full infrastructure is ready, configure the reproducible local file gateway, private CA, approved skills volume and broker profile. This step reads the model key from a local file and creates Kubernetes Secrets; neither the key nor the generated CA is committed:

```bash
make k3d-sandbox-files-demo ENV=secondary FRED_REPO=../fred \
  MODEL_API_KEY_FILE=/path/to/local/model-api-key
make k3d-app ENV=secondary K3D_AGENT_SANDBOX=true APP=fred DIR=../fred \
  FRED_LIBS=local FRED_REPO=../fred \
  VALUES="k3d-apps/fred/sandbox-secondary.yaml .cache/agent-sandbox/fred-secondary/files-demo/fred-values.yaml"
```

`k3d-sandbox-files-demo` creates the private CA and TLS-only internal gateway, mounts that CA into rclone CSI, creates an approved read-only `/skills` PVC, configures the broker's `rclone_csi` profile, and writes the final Fred values overlay under `.cache/agent-sandbox/`. It is idempotent on the same cluster. The gateway forwards only read methods to Knowledge Flow's sandbox mount endpoint. Knowledge Flow authorizes each listing and read. The sandbox sees `/inputs/corpus`, `/inputs/attachments`, and `/skills` with no selection tool. The fixture serves `summarize-document` and `tabular-evidence`; the latter calls a Python script on an authorized CSV under `/inputs`. New authorized corpus documents and conversation attachments appear after the short CSI directory cache refresh; the sandbox Pod is not restarted.

The sandbox flag adapts the factory's instance values to the current Fred checkout's registration contract. The secondary overlay leaves application and Knowledge Base registrations empty, matching the secondary cluster's disabled optional apps. Enable `code_sandbox` for the intended team in Fred's admin UI. The local Python gateway and skill source are test fixtures; a production cluster should provide an operator-managed TLS gateway and approved skill source. The smoke command proves CSI mechanics, while a conversation test must still prove corpus and attachment authorization.

## Work on unreleased fred

fred publishes its Python libraries (PyPI) and its charts (`oci://ghcr.io/thalesgroup/fred-helm`)
only when it releases. Between releases, every application built on fred (agent pods,
Knowledge Bases, the evaluator, RAGS) is tested against the fred checkout next to it with one
switch, the same in every repository:

| | `FRED_LIBS=pypi` (default) | `FRED_LIBS=local` |
| --- | --- | --- |
| Python environment | `make dev`: the committed `uv.lock` | `make dev-local`: fred's libraries installed editable from `FRED_REPO` over it; `make dev-pypi` goes back |
| Image | `make docker-build`: the lock's versions | `FRED_LIBS=local make docker-build`: the Dockerfile installs fred's libraries from `FRED_REPO` (`--build-context fred=...`) over the lock |
| k3d release | the published chart, at the version the helmfile pins | the chart in `$FRED_REPO/deploy/charts/` |

`FRED_REPO` is the path of your fred checkout; it has no default, anywhere: with
`FRED_LIBS=local` and no `FRED_REPO`, every command stops and says what to set. For days on
the latest swift:

```bash
export FRED_LIBS=local
export FRED_REPO=/path/to/your/fred
cd fred-deployment-factory && make k3d-app DIR=/path/to/the/application
```

`make k3d-app` prints which fred it builds against (`libraries and charts from ... (swift @
<commit>)`) and refuses a path that is not a fred checkout. The committed lock never points at a checkout:
CI and a fresh clone always resolve the published versions, and `make ecosystem-audit`
reports an application missing one of the three switches.

What an application provides for it:

- **Makefile** of each Python project: `FRED_LIBS ?= pypi`, `FRED_REPO` without a default
  (`dev-local` and a local `docker-build` stop with a clear message when it is unset),
  `dev-local` and `dev-pypi`, and `docker-build` passing `--build-arg FRED_LIBS` and, when
  local, `--build-context fred=$(FRED_REPO)`.
- **Dockerfile**: `ARG FRED_LIBS=pypi`, a `base-local` stage copying `libs` from the `fred`
  context, and after `uv sync --frozen`, `uv pip install` of the fred packages it uses from
  there. dt-agents' `dockerfiles/Dockerfile` is the reference.
- **`deploy/k3d/helmfile.yaml.gotmpl`**: the chart from `$FRED_REPO/deploy/charts/<chart>` when
  `FRED_LIBS=local`, else the published one at a pinned version:

  ```yaml
  {{- $local := eq (env "FRED_LIBS") "local" }}
  releases:
    - name: dt-agents
      chart: {{ if $local }}{{ env "FRED_REPO" }}/deploy/charts/agent-pod{{ else }}oci://ghcr.io/thalesgroup/fred-helm/agent-pod{{ end }}
      {{- if not $local }}
      version: 3.5.0
      {{- end }}
  ```

## What `docker-up` / `k3d-up` provisions

One mode, no flags. Both backends provision the same thing: Keycloak with an **empty realm**
(self-registration enabled), OpenFGA with an **empty store** whose authorization model each
Fred service publishes at startup, Postgres, and Temporal - infrastructure only, zero business
data. There are no demo users, no Keycloak groups, no app roles, and no OpenFGA tuples baked
in by either backend. The imported Keycloak realm template never carries team groups, and no
script in this repo ever creates a Keycloak group.

Databases created: `fred` (Fred), `keycloak`, `data` (tabular/vector), `openfga`, `temporal`,
`temporal_visibility`.

Keycloak also gets the `fred-delegation` client with its `delegation_caller` role, granted
to the `agentic` service account: holding it is what lets fred-agents speak for a person
once the Fred apps turn delegation on. For apps run on the host, the fred repository's
`make delegation` checks the workload token and switches it on; for the k3d `fred-app`
release, set `security.delegation.act_for_people: true` in the fred-agents configuration
and `security.delegation.accept_delegated_calls: true` in the control-plane-backend and
knowledge-flow-backend configurations.

Every identity and role - platform (`platform_admin`/`platform_observer`) and team
(`team_admin`/`team_editor`/`team_analyst`/`team_member`) - is provisioned afterwards by
`fred`/control-plane-backend's declarative platform-import feature
(`POST /import-export/import`), not by this repo. See "Full bootstrap walkthrough" above
for the exact step-by-step sequence (`make bootstrap-token` → become `platform_admin` →
`make build-demo-bundle` + import), and [`../docker/README.md`](../docker/README.md)
("Platform and demo-data provisioning now lives in `fred`") for the underlying contract.
Capability grants (which tools/agents each team can use) are a separate, later step —
none of the above provisions them; see step 5b.

## Configuration

`make docker-up` regenerates `docker/.env` from `docker/.env.template` — edit
the template for custom values. Keycloak backend client secrets:

- **Compose:** `KEYCLOAK_AGENTIC_CLIENT_SECRET`, `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`,
  `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET` in `docker/.env.template`.
- **k3d:** `auth.keycloak*ClientSecret` in `k3d/values.yaml`. They land in the `fred-secrets`
  Secret, which the Fred apps read by reference (`k3d-apps/fred/values.yaml`): one place to
  change them.

## Real non-Keycloak provider: ZITADEL

This opt-in profile runs ZITADEL v4.19.2, its Login UI, a private PostgreSQL and
an HTTP/2 proxy on **http://localhost:8091**. It has its own Compose project and
volumes; it neither resets Fred nor changes Keycloak. Compose configuration
follows [ZITADEL's local deployment](https://zitadel.com/docs/self-hosting/deploy/compose).

From deployment-factory:

```bash
make zitadel-configure SWIFT_SRC=../fred
make zitadel-status
```

The first start downloads images. Local credentials are generated once in
`docker/zitadel/.env` (ignored, owner-only). The bootstrap operator PAT and
resumable provisioning state are also ignored under `docker/zitadel/state/`.
Do not publish these files. The provider is bound to loopback and is a local
HTTP development deployment, not a production configuration.

Provisioning creates the Fred project, a public SPA using code + PKCE and JWT
access tokens, and three machine users with client secrets. Only `agentic`
holds `delegation_caller`; all three workloads hold `service_agent`. A
[complement-token action](https://zitadel.com/docs/apis/actions/complement-token)
projects roles from this specific project into Fred's flat `roles` claim.
The project ID is the API audience requested through ZITADEL's project scope.
M2M requests also explicitly request the assigned role scopes; requesting only
the audience does not include the workload roles.
People keep their provider-issued non-UUID IDs; Fred normalizes them.

Complete schema-validated configs, the conversation policy catalog and a private
`service-credentials.env` are generated under `/tmp/fred-idp-tests/zitadel/`.
For manual launches, source the credentials in each backend terminal, select
that directory's CONFIG_FILE, set FRED_LOCAL_DELEGATION_FILE empty and
FRED_JWT_MAX_LIFETIME_SECONDS=5400; use the Fred identity-provider launch guide.
Existing backend `.env` files still supply database, storage and model settings.
The new secrets use ZITADEL-specific environment names and do not replace the
Keycloak secrets.

With the matching Fred checkout, VS Code task **IDP zitadel — launch all** handles
preparation and all six applications. Run **Fred — kill all** before switching.
Visit http://localhost:8091/ui/console and log in as
`fred-admin@zitadel.localhost` (the generated file records the exact login).
The provisioner creates this console administrator separately because initial
machine bootstrapping does not create a human administrator. Display its initial
login details locally; the first login may require a password change:

```bash
cat docker/zitadel/state/admin-login.json
```

Create test users in the console, then sign in to Fred in a private window.
If Fred was already bootstrapped with another provider, its root admin marker
is retained: a new ZITADEL identity cannot reuse bootstrap. For a fresh admin
walkthrough, use an explicitly reset/checkpointed test platform or have an
existing Fred admin assign the role after the new person has authenticated.
ZITADEL administrator status does not grant Fred platform administrator status.

The generated ZITADEL configs enable CGU version `v1` in all three backends.
Restart Fred after regeneration; a new user must accept before entering the app.
Previously accepted `v1` is retained. Root bootstrap is deployment-wide and is
not reopened when changing providers.

Check CGU acceptance for a new user, personal-space identity,
local user lookup, the JWT self-test, document/agent delegation, and isolation
between two users. The live checks are independent from Keycloak. Keep optional
samples/evaluator runtimes in mind when selecting an agent.

```bash
make zitadel-down  # preserves users and volumes; does not stop Fred
```

`docker-wipe` targets the usual Foundation stack, not the opt-in ZITADEL project.
If deliberately wiping ZITADEL, also remove its ignored provisioning state before
running configure again; retained IDs otherwise refer to deleted resources.

Verification (2026-09-28): all four ZITADEL containers reached readiness;
discovery and the console responded; the SPA authorization request with PKCE
reached the real login page; all three workload JWT signatures, issuer,
audience, expiration and assigned roles were verified using Fred's installed JWT
library. All three generated configs passed their JSON schemas and Fred provider
validation. Offline tests cover required claims and exclusive delegation roles.
The Fred PR #2863 local ZITADEL walkthrough was declared successful by the developer on 2026-10-01; no exported administrator self-test report is attached. Fresh Kubernetes acceptance remains separate.


## Two persistent k3d environments

`ENV=swift` is the default and keeps the existing cluster `fred`. `ENV=secondary`
selects `fred-secondary`. The literal profiles in `k3d/environments/*.env` are shared
by Make, application hooks and `bin/k3d-observe`. Unknown environments fail before
any cluster operation. Make command-line overrides remain available.

| Service | Swift host port | Secondary host port |
| --- | --- | --- |
| Fred frontend | 8088 | 18088 |
| Keycloak | 8080 | 18080 |
| PostgreSQL | 5432 | 15432 |
| S3 | 8333 | 18333 |
| OpenSearch | 9200 | 19200 |
| OpenSearch Dashboards | 5601 | 15601 |
| OpenFGA HTTP / gRPC | 9080 / 9081 | 19080 / 19081 |
| Temporal frontend / UI | 7233 / 8233 | 17233 / 18233 |
| Prometheus | 9090 | 19090 |
| Grafana | 3002 | 13002 |
| ClickHouse HTTP / native | 8123 / 9002 | 18123 / 19002 |

Kubernetes API ports are allocated by k3d and recorded in kubeconfig. Internal
service ports, the `fred` namespace and Helm release names stay the same in both
clusters. PVCs, databases, buckets, search indices, realms, secrets and Temporal
workflows belong to their own cluster. Both clusters still share the host's CPU,
memory, disk and Docker image cache.

For browser access, keep `127.0.0.1 keycloak` in `/etc/hosts` for Swift and add:

```text
127.0.0.1 keycloak-secondary secondary.localhost
```

Swift keeps `http://localhost:8088` and `http://keycloak:8080`. The secondary environment uses
`http://secondary.localhost:18088` and `http://keycloak-secondary:18080`. Distinct hostnames
separate browser cookies as well as application local storage. Use
`secondary.localhost` for the secondary environment's Grafana, Dashboards and Temporal UI too.
Keycloak publishes one fixed issuer per cluster. In the secondary environment, a Kubernetes Service
named `keycloak-secondary` exposes port 18080 to pods, forwarding to Keycloak's
unchanged container port 8080. Browser and backend discovery therefore agree on
the exact issuer. The stable internal `keycloak:8080` service remains available
for infrastructure administration.

```bash
# Infrastructure, once per environment; reruns upgrade the selected stack.
make k3d-up
make k3d-up ENV=secondary

# The operator supplies the model Secret separately in each cluster.
# Use your normal local secret-loading method with --context k3d-fred or
# --context k3d-fred-secondary. Neither environment copies the other's secrets.

# Independent checkouts or Git worktrees, each on its own branch.
# These paths are examples; choose any two directories.
make k3d-app APP=fred DIR=~/work/current/fred
make k3d-app ENV=secondary APP=fred DIR=~/work/experiment/fred

# Daily operations target only the selected cluster.
make k3d-env ENV=secondary
make k3d-status ENV=secondary
make k3d-health ENV=secondary
ENV=secondary bin/k3d-observe logs 'ERROR' --since 30m
make k3d-down ENV=secondary           # stop the secondary environment, preserve its data; Swift keeps running
make k3d-up ENV=secondary             # start it and reconcile the infrastructure
```

All factory Kubernetes and Helm calls specify their context; neither normal
operations nor cluster creation switch the global current context. Cluster
creation serializes k3d's kubeconfig updates. Logs, generated values and mutable
build tags are isolated by cluster and checkout. A Swift build cannot select the
secondary environment's cached image values. Separate worktrees/checkouts remain the
operator's choice; the factory does not modify source branches.

Fred keeps its original `k3d-apps/fred/values.yaml` for the default Swift mode.
Only `ENV=secondary` adds `k3d-apps/fred/secondary.yaml.gotmpl`: environment URLs and
empty application/Knowledge Base registrations, for testing Fred alone.
`DIR` selects the source checkout; `ENV` never changes branches or selects a
different application architecture.

Satellite support in the secondary environment is out of scope. Existing evaluator and external
application deployment commands remain available in the default Swift mode;
their configuration is unchanged. The generic deployment script contains no
satellite-specific dispatch or configuration.
