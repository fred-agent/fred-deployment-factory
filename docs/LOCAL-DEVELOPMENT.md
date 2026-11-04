# Local development stack

The recommended starting point is **Weaver alone on k3d**, documented in the
[README](../README.md). This file is the technical
reference for infrastructure, application hooks and diagnostics.

For **Swift and Weaver side by side**, see
[their boundaries](SWIFT-WEAVER.md), which also covers the reset
procedure. The Docker walkthrough and the Swift/published-release subsection below
are legacy Swift workflows; they are not Weaver startup instructions. Weaver's
current local deployment path is k3d.

For raw Compose internals (network, `.env`, per-service files), see
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
post-install job, so the Keycloak realm and every volume come
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
`make temporal-up`, …).

## Full bootstrap walkthrough: from `docker-up` to a validated platform

`make docker-up` only gives you empty infra (§"What `docker-up` / the local `k3d-up` commands provisions"
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
make docker-up   # Keycloak, Postgres, OpenSearch, Temporal — infra only, zero business data
```

**1. Prepare the three backends' `.env` files** (`fred` repo root)

```bash
make setup-env
```

Creates each backend's `.env` from its `.env.template` if missing, fills in every
blank secret placeholder (Keycloak client secrets, Postgres/
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

Fred never creates accounts in Keycloak, on purpose: **Keycloak authenticates, Fred
authorizes** (`docs/swift/platform/REBAC.md` in the `fred` repo) — the same
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
authorization-at-scale testing)? See [`local-testing/bench/README.md`](../local-testing/bench/README.md).

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

`STACK` selects Docker Compose services only. The k3d commands use a fixed base infrastructure:

| `STACK` | Services |
|---------|----------|
| `base` (default) | Minimal stack — Docker drops ClickHouse, Langfuse, Redis, Prometheus, Grafana |
| `extended` | Full stack, including ClickHouse, Langfuse (+ Redis, Docker only), Prometheus, Grafana |

The local k3d commands always use the base infrastructure with Prometheus,
Grafana and Fluent Bit. There is no stack/profile override on those commands.

## k3d: one local installation

Use the [README](../README.md) for the public commands. `make k3d-up`,
`make k3d-up-swift` and `make k3d-up-weaver` prepare COTS and their namespace,
database and Temporal boundaries only. No checkout or model key is required.
Deploy applications separately with `make k3d-app APP=fred DIR=/path/to/checkout`
(or `RELEASE` for a published version). There is one fixed cluster (`fred`) and
no environment or instance selector. Docker's `STACK` does not apply to k3d.

`bin/k3d-local` derives infrastructure dependencies and application placement.
A Weaver checkout has `apps/control-plane/Cargo.toml` and uses `fred-weaver`;
published Swift and other applications use `fred`. Application inputs remain
available through `k3d-app`, `k3d-app-validate` and `k3d-app-uninstall`.

The coordinator rejects conflicting infrastructure requests before changing the
cluster. A ConfigMap records the requested infrastructure before preparing the
application boundaries. Existing Helm releases and the Weaver namespace are also
inspected when adopting an older lab. An unreachable cluster is an error, never
an empty installation: use `make k3d-start` to resume it. A local lock serializes
operator commands across factory checkouts for the same OS user.

`k3d/infrastructure.mk` owns COTS reconciliation; `bin/k3d-app.sh` owns application
render/build/import/hooks/sync. The infrastructure commands never call the application
engine. Source selection uses `DIR`, not `local-checkouts.json`.

Weaver always uses database `fred_weaver`. The infrastructure's `fred` database
retains Swift's extension initialization; the product bootstrap initializes
Weaver's separate database. See [database bootstrap](../k3d-apps/fred/README-postgres.md).

`make k3d-validate` renders infrastructure only. `make k3d-app-validate` renders
the selected application, using cached image references when available. Neither
proves that builds or user journeys work. `make k3d-app` builds the selected checkout. `make k3d-wipe` removes the cluster and this checkout's generated
application cache; no retained Helm payload containing old ingestion Secret references
is reused after that reset.

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

These inputs are available on `make k3d-app`, `make k3d-app-validate` and
`make k3d-app-uninstall`. Infrastructure startup remains separate.

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
| `registration.yaml` | no | What it registers with Fred: its own entry only (below, "Registering with Fred") |
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
`K3D_HOST_PORT_GRAFANA`, `K3D_PUBLIC_URL`, `K3D_REALM_URL`, `RELEASE`, `K3D_APP_CHECKOUT`, `FRED_LIBS` and `FRED_REPO` (below,
"Work on unreleased fred"). Without a build, the charts' own images run.
A cluster call targets `--context "$KUBE_CONTEXT"`, never the current context.

the internal application engine (`bin/k3d-app.sh`) checks and renders first (a mistake costs seconds, not
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

What an application can rely on, the **platform contract**: the derived application namespace (`fred` for Swift,
`fred-weaver` for Weaver); the
infrastructure services by name (`postgres:5432`,
`opensearch:9200`, `temporal:7233`, `seaweedfs:8333`); the OIDC issuer
from `K3D_REALM_URL` (realm `app`); and the credentials
of `fred-secrets` (`k3d/templates/secret.yaml`), plus the operator's own Secrets
(`fred-model-credentials`), read by `secretKeyRef`, never copied into a values file. Fred learns about an application through its
`registration.yaml` (below).

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
`fred-secrets` keeps every key its template does not manage, so `make k3d-up` and its solo variants never drop
an application's secret. The platform's own identities (the realm, the `app` client and its
roles, Fred's backend clients) stay in `k3d/files/scripts/keycloak-post-install-k8s.sh`,
which shares its Keycloak functions with `bin/k3d-identities` (`keycloak-lib.sh`).

Docker Compose does not read these files: it is the fast loop to debug an app, and
`docker/keycloak/keycloak-post-install.sh` gives the apps fixed identities with local
default secrets.

**Registering with Fred.** Fred serves an application through two lists that must agree,
the control plane's `application_sources` and the frontend gateway's
`FRONTEND_APPLICATIONS_JSON`, and lets a Knowledge Base publish through
`knowledge_bases.publishers`. Helm replaces lists, so no values file may hold a share of
them: each application declares its own entry, and only its own, as a Fred values file
holding only `registrations` (the shape the fred chart takes from ThalesGroup/fred#3211
on), keyed by `app_id` or `client_id`:

```yaml
# deploy/k3d/registration.yaml
registrations:
  applications:
    acme-forecast:                 # the app_id
      ui_prefix: /apps/acme-forecast
      version: 1.0.0
      icon: insights
      display_name: { en: "Forecast", fr: "Prévisions" }
      description: { en: "...", fr: "..." }
      enabled: true
      gateway:                     # what the frontend gateway proxies to
        ui_upstream: http://acme-forecast-ui.fred.svc.cluster.local:8080
        service_upstream: http://acme-forecast-api.fred.svc.cluster.local:8000
        service_required: true
  knowledgeBasePublishers:         # a Knowledge Base's client and the prefix it owns
    kb-fred.opentext:
      prefix: fred.opentext
```

the internal application engine stores it, before the sync, in a ConfigMap `fred-registration-<name>`
(`<name>`: `APP`, or the application's directory) labelled
`fred-deployment-factory/registration`, and passes every stored registration to the
helmfiles as `K3D_REGISTRATIONS` (a JSON object, name → `registration.yaml` text; when
validating, the application's own only). Fred's `k3d-apps/fred/registrations.yaml.gotmpl`
merges them into `registrations` for a chart that takes it (a checkout with #3211, or a
published release from 3.9.0), and otherwise builds the three lists an earlier chart takes;
`k3d-apps/fred/helmfile.yaml.gotmpl` decides which. It refuses a key other than
`registrations.applications` and `registrations.knowledgeBasePublishers`, an application
without `gateway.ui_upstream`, and an `app_id` or a `client_id` registered twice. When the registration
changed, the internal application engine first redeploys Fred as it was last deployed (`APP`, `DIR`,
`RELEASE`, `VALUES`, kept in the ConfigMap `fred-registrations-server`), without a build,
so that Fred knows a Knowledge Base's client before its publish Job runs. A Fred not yet
deployed this way serves it after its next `make k3d-app` command. `make k3d-app-uninstall`
removes the registration the same way. Registration alone grants nothing: a platform admin
enables an application or a Knowledge Base per team (**Admin > Features**).

Once built, the standard Helmfile commands work on their own:

```bash
helmfile -f k3d-apps/fred/helmfile.yaml.gotmpl --kube-context k3d-fred -n fred template --skip-deps
```

## Application library development

Select application source with `DIR` on `make k3d-app`. The product build hook
owns its library build. `FRED_LIBS=local FRED_REPO=/path/to/fred` remains available
for satellite builds against local Fred libraries; it does not select a namespace.

## Infrastructure and initial data

Docker Compose commands start backing services. The local k3d `k3d-up` commands
start only the required COTS and prepare their application boundaries. Fred
applications require a separate `make k3d-app` command. Both begin
with an empty Keycloak realm (self-registration enabled), PostgreSQL and Temporal.
Neither creates business data. There are no demo users, no Keycloak groups and no app roles baked in by either
backend. The imported Keycloak realm template never carries team groups, and no
script in this repo ever creates a Keycloak group.

The k3d foundation creates `fred` (Swift), `keycloak`, `data` (tabular/vector),
`openfga` (reserved for adding Swift), `evaluation`, `temporal` and
`temporal_visibility`. Selecting Weaver also prepares `fred_weaver`.

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
