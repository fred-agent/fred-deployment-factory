# Local development stack

Run Fred's backing services on your laptop — for day-to-day development against a local Fred,
or to host the auth/isolation validation release gate, which now lives in the sibling `fred`
monorepo's own `validation/README.md` (run `cd ../fred && make validation-report`). Fred itself
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

```bash
make validation-report
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

The infrastructure **and** the Fred apps run in a local k3d cluster. The apps are deployed
with Fred's official Helm chart (`fred` repository, `deploy/charts/fred`) and this
instance's values, `k3d-apps/fred/values.yaml`: the same layering as any other instance,
so k3d exercises the chart and the posture production uses (security profile `c3`,
delegation, migration Job, every credential read from one Foundation Secret). It is
independent of the Docker Compose stack: don't run both at once, because they use the
same host ports.

**Prerequisites:** Docker, [`k3d`](https://k3d.io)
(`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`), `kubectl`,
`helm` (3 or 4), and a `fred` checkout. `FRED_DIR` points at it; it defaults to `../fred`.

**1. Make `keycloak` resolve to your machine** (once). Fred sends the browser to
`http://keycloak:8080` to log in, the same address the pods use inside the cluster:

```bash
grep -qw keycloak /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

**2. Your model API key** (once, in the `fred` checkout): `make setup-env` writes
`apps/*/config/.env` and asks for it. `make k3d-app` copies `OPENAI_API_KEY` from
`apps/fred-agents/config/.env` into the cluster's `fred-secrets`.

**3. Infrastructure** (this repo): creates the cluster `fred` and installs the release
`fred-stack` into the namespace `fred`:

```bash
make k3d-up
```

**4. Fred** (this repo): builds the four images from `FRED_DIR`, copies them into the
cluster and installs the release `fred-app`, waiting until every pod is ready. As long as
nobody is `platform_admin` yet, it ends with a command to retrieve the root bootstrap token:

```bash
make k3d-app FRED_DIR=../fred
```

**5. First login, in Fred.** Open <http://localhost:8088>. Fred sends you to the Keycloak
login page: create your account with **Register** (Fred never creates accounts itself).
Back in Fred, a page asks for the bootstrap token: retrieve it with the command `make k3d-app` prints, then paste it.
Your account becomes the platform's `platform_admin`; this works once per platform, the
first account keeps the role. Then turn the tools and agent templates on in
**Admin > Capabilities** (select all).

**6. The evaluation application** (optional, this repo): builds fred-agent-evaluator's API,
worker and UI from `EVALUATOR_DIR` (default `../fred-agent-evaluator`) and deploys its chart
with `k3d-apps/fred-evaluator/values.yaml`. Fred already knows the application
(`application_sources` in `k3d-apps/fred/values.yaml`); it shows up once a platform admin
enables `evaluation` for a team in **Admin > Features** (filter "app").

```bash
make k3d-evaluator EVALUATOR_DIR=../fred-agent-evaluator
```

| URL | What |
| --- | --- |
| <http://localhost:8088> | Fred: the frontend and every app API, through the Traefik ingress |
| <http://localhost:8088/apps/evaluation/> | The evaluation application, inside Fred |
| <http://keycloak:8080> | Keycloak: login, registration, admin console |
| <http://localhost:8233> | Temporal UI |
| <http://localhost:3002> | Grafana (`admin` / `Azerty123_`): folder **Fred**, the dashboards of the Fred checkout |
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
- `make k3d-app` after any change, in code or in `k3d-apps/fred/values.yaml`: it rebuilds
  (from Docker's cache), copies the images and rolls out whatever changed.
- `make k3d-app-validate FRED_DIR=../fred` runs lint and schema-checked rendering
  without builds or cluster mutations. Set `FRED_IMAGE_VALUES=/absolute/path/to/images.json`
  to check prepared image overrides too; otherwise it checks installation values only.
- This slice supports the local checkout chart only. Published OCI charts and other
  deployment environments are outside this workflow.
- `make k3d-status` shows the pods.

**Tear down** (this repo):
- To remove only Fred, use `helm --kube-context k3d-fred uninstall fred-app -n fred`.
  `make k3d-evaluator-uninstall` removes the evaluation application. Neither command
  removes the infrastructure holding their data.
- `make k3d-down` stops the cluster and frees the host ports; `make k3d-up` starts it again.
- `make k3d-delete` deletes the cluster.
- `make k3d-wipe` uninstalls the infrastructure release and deletes the cluster; use it to
  restart from scratch.

`make k3d-up` and `make k3d-app` are both safe to rerun: they converge. Optional Cilium
(`K3D_USE_CILIUM=true`) is only needed for `CiliumNetworkPolicy` / air-gap flows.

### Helmfile and local image preparation

Install Helmfile from its official release and verify the archive against the published
checksums (tested: Helmfile 1.8.1, Helm 3.21.2). No Helm plugins are needed for this flow.
`helmfile.yaml.gotmpl` describes only `fred-app`; `make k3d-up` still owns infrastructure.
There are no product variants in this slice; `STACK=base|extended` remains an infrastructure
choice. Evaluator continues to use its existing command.

`make k3d-app` validates, builds the four images with Fred's existing Make targets,
validates again with their content-derived tags, imports the images using the existing
helper, recovers the Fred release with the PVC guard, prepares the model key, runs Helmfile
sync, then installs Fred's dashboards. Every cluster call targets `k3d-$K3D_CLUSTER` explicitly;
the current kubectl context is left unchanged. Failed builds/renders stop deployment.
Helm 3's lint retains `null` deletion markers from the storage overrides, so its schema
check is skipped; **template and sync still enforce the complete chart schema**.

Values precedence: chart defaults, `FRED_VALUES` (one file, default
`k3d-apps/fred/values.yaml`), generated image values. Wrapper paths are resolved relative
to this factory checkout, even when the script is invoked from elsewhere. Absolute paths
and spaces are supported. `FRED_RELEASE`, `K3D_CLUSTER` and `K3D_NAMESPACE` default to
`fred-app`, `fred` and `fred`. The local rollout timeout is 20 minutes.

After a successful build/import, the standard Helmfile commands are usable directly:

```bash
export FRED_DIR="/absolute/path/to/fred"
export FRED_IMAGE_VALUES="$FRED_DIR/.cache/k3d/images.json"
helmfile --skip-deps lint --args '--skip-schema-validation'
helmfile --skip-deps template > /dev/null
helmfile --skip-deps sync
```

Direct Helmfile commands do not build/import images, recover a failed release, update
the model key or install dashboards; use `make k3d-app` for the complete local loop.
Build logs and generated image values live in Fred's ignored `.cache/k3d/` directory.
Model keys stay in the local environment or Fred `.env` and in `fred-secrets`; neither
model keys nor bootstrap tokens are printed by the deployment command.

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
