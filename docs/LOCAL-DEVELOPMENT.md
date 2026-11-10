# Local development stack

Two local forms of Fred Weaver, both documented in the [README](../README.md):
**k3d**, which deploys as production does, and **Docker Compose**, the fast loop to
debug an application on the host. This file is the technical reference for
infrastructure, applications and diagnostics.

For **Swift and Weaver side by side on k3d**, see [their boundaries](SWIFT-WEAVER.md),
which also covers the reset procedure. Swift on Docker Compose stays on branch `swift`.

For raw Compose internals (network, `.env`, per-service files), see
[`../docker/README.md`](../docker/README.md).

**Prerequisites (Compose):** Docker, Docker Compose (`docker compose`), `bash`, `jq`,
`curl`, plus the build tools of a Fred Weaver checkout (Rust, uv, Node).

## Docker Compose: Weaver on the host

The Compose services and k3d publish the same host ports: stop one before starting the
other (`make k3d-stop`, `make docker-stop`).

```bash
make docker-up                  # base stack: PostgreSQL, Keycloak, SeaweedFS, OpenSearch, Temporal
make docker-up STACK=extended   # + Prometheus, Grafana, ClickHouse, Langfuse
```

`make docker-up` prepares what Weaver relies on, as `make k3d-up` does for the line
`weaver`, on `localhost` ports; the token issuer is `http://keycloak:8080/realms/app`, as
on k3d:

| Service | What Weaver gets |
| --- | --- |
| PostgreSQL `:5432` | The empty database `fred_weaver`. Its roles and schemas are Fred's `deploy/postgres/bootstrap.sql` |
| Keycloak `:8080` | Realm `app`, the clients `app`, `agentic`, `knowledge-flow`, `control-plane`, `knowledge-flow-worker` and the delegation client `fred-delegation` |
| SeaweedFS `:8333` | The documents bucket `app-content-documents` |
| OpenSearch `:9200` | Security initialized; Fred creates its indexes and search pipeline |
| Temporal `:7233` | The namespace `fred-weaver` |

Every application connects with the administrator of each service (OpenSearch, S3)
and the local default secrets (`Azerty123_`). The least-privilege identities of k3d
are not provisioned on Docker.

`make docker-prepare DIR=<checkout>` then prepares that checkout to run on the host, as
`make k3d-app` deploys it, and starts nothing. `bin/docker-prepare` types, in the checkout:

| Step | What it does | On k3d |
| --- | --- | --- |
| `make setup-env` | `config/.env` of each application: local secrets, bootstrap token, the exported `MISTRAL_API_KEY`/`OPENAI_API_KEY` | `fred-secrets`, `fred-model-credentials` |
| `make docker-prepare` | Database roles and schemas, Control Plane schema, worker contract (replayable) | The chart's `postgresBootstrap` hook and migration Jobs |
| `make run`, typed by you or your coding assistant | The six processes, each with its `configuration_prod.yaml` (`configuration_worker.yaml` for the worker) | The six deployments, with `values-weaver.yaml` |

The configurations carry k3d's values with `localhost` addresses; only the log format
differs (text, not JSON). The monitor needs Kubernetes and does not run on Docker.
The first login is Fred's [first start](https://github.com/ThalesGroup/fred/blob/weaver/deploy/k3d/README.md#first-start),
the same as on k3d.

To repair an existing realm after updating this checkout, run
`KEYCLOAK_FORCE_RELOGIN=false bash docker/keycloak/keycloak-post-install.sh`, then sign
out and sign in again. The script is idempotent.

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

Weaver is installed from scratch only: after a Fred schema change, `make docker-wipe`,
then `make docker-up` and `make docker-prepare` again.

Extended-profile endpoints: Prometheus `:9090`, Grafana `:3002`, ClickHouse `:8123/play`,
Langfuse `:3001`. Per-service targets also exist (`make keycloak-up`, `make opensearch-up`,
`make temporal-up`, …).

## Identity provider portability

The default `make docker-up` path remains the Keycloak baseline. These opt-in
local profiles accompany [Fred issue #2862](https://github.com/ThalesGroup/fred/issues/2862)
and [draft PR #2863](https://github.com/ThalesGroup/fred/pull/2863). Follow the
Docker Compose path above for each profile; run `make validation-report`
from the sibling `fred` checkout after starting its applications. The UI
self-test still needs a browser. Use a fresh test deployment when comparing
provider identities, personal spaces or administrator bootstrap state.

1. **Keycloak baseline:** run the Docker Compose path above without an OIDC overlay.
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

Use the [README](../README.md) for the public commands. They are thin wrappers:

| File | Owns |
| --- | --- |
| `k3d/cluster.yaml` | The cluster, for `k3d cluster create --config` |
| `helmfile.yaml` | The infrastructure release, `fred-stack` in `fred-infra` |
| `k3d/` (chart), `k3d/values.yaml` | COTS and, under `lines`, what each Fred release line gets |
| `k3d-apps/<APP>/helmfile.yaml.gotmpl` | An application, with one Helmfile environment per line it runs on |
| `k3d-apps/fred/values-<line>.yaml` | Fred's plain values on that line |
| `bin/k3d-app` | The order an operator follows: render, build and import a checkout's images, sync |

The infrastructure chart renders, for each entry of `lines`, the namespace `fred-<line>`, its
`fred-secrets`, its other Secrets and its `ExternalName` aliases, and its post-install Jobs
create the line's database and Temporal namespace. S3 identities and policies
(`s3`, `files/seaweedfs/policies.yaml`), OpenSearch accounts and the search pipeline
(`opensearch`) and Keycloak service clients (`keycloak.serviceClients`) are values too.
To add a line, add it under `lines` and give an application an environment and a values file.

A helmfile declares only the environments it supports, so Helmfile itself refuses another
line. `k3d-apps/fred` checks `DIR` against the line's `checkoutMarker`, and refuses a line
without a published release when there is no `DIR`.

Weaver uses database `fred_weaver`, whose SQL owners come from its chart's
`postgresBootstrap` hook. The infrastructure's `fred_swift` database retains Swift's
owner and extension initialization.

`make k3d-validate` renders infrastructure only. `make k3d-app-validate` renders
the selected application, using the last build's image references when available. Neither
proves that builds or user journeys work. `make k3d-app` builds the selected checkout.
`make k3d-wipe` removes the cluster and this checkout's generated application cache.

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
  use the ingress on `http://<line>.localhost:8088`.
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

Fred and its open-source applications are defined here, in `k3d-apps/<APP>/`: the
instance's values, deployed from the published chart and images (`APP=<app>`,
`RELEASE=<version>` or the version the helmfile pins, bumped by a Renovate PR after each
release and validated by `.github/workflows/validate.yml`). Their repositories keep only
`deploy/k3d/build`: with `DIR=<checkout>`, `bin/k3d-app` runs it and the helmfile takes the
chart from `DIR`. `RELEASE` and `DIR` exclude each other.

Any other application is defined in its own repository: `DIR` is a checkout whose
`deploy/k3d/` holds the files below, or that directory itself. Nothing about it lives here.

| File | Required | What |
| --- | --- | --- |
| `helmfile.yaml.gotmpl` | yes | Ordinary Helmfile: `environments` naming the lines it runs on, its releases in `namespace: fred-{{ .Environment.Name }}`, its k3d values, then `K3D_IMAGE_VALUES` when set. Use Helmfile hooks for read-only checks |
| `build` | no | Builds its images; writes `$K3D_APP_OUT/images.txt` (one reference per line, tagged by content) and `$K3D_APP_OUT/images.yaml` (the Helm values selecting them). Receives an `IMAGE_TAG` specific to that checkout, `FRED`, `FRED_LIBS` and `FRED_REPO`. Runs when `DIR` is given |

Label each block of its values `address`, `secret`, `posture`, `choice`, `models` or
`sizing`. Helm's values schema is enforced at render time. Build logs and image values stay
in this repository's ignored `.cache/k3d-apps/<line>/<application>-<checkout-hash>/`.

What an application can rely on, the **platform contract**: the namespace of its Fred release line
(`fred-swift`, `fred-weaver`, with the infrastructure in `fred-infra`); the
infrastructure services by name (`postgres:5432`,
`opensearch:9200`, `temporal:7233`, `seaweedfs:8333`); the OIDC issuer
`http://keycloak:8080/realms/app`; and the credentials of its `fred-secrets`
(`k3d/templates/lines.yaml`), plus the operator's own Secrets
(`fred-model-credentials`), read by `secretKeyRef`, never copied into a values file.

**Identities.** A service client an application needs is declared in `k3d/values.yaml`, or a
`make k3d-up VALUES=...` overlay:

```yaml
keycloak:
  serviceClients:
    fred-evaluation-worker:                        # a confidential client with a service account
      secretKey: KEYCLOAK_EVAL_WORKER_CLIENT_SECRET # its key in fred-secrets, on every line
      secret: Azerty123_                           # a local default, as in `auth`
      grants: [app/service_agent]                  # <client>/<role> for its service account
```

The Keycloak post-install Job creates or fixes each client and adds each grant, with optional
`representation` and `protocolMappers`, and never deletes. The application's values read the
secret by `secretKeyRef`; nothing in the application holds Keycloak's admin. The platform's own
identities (the realm, the `app` client and its roles, Fred's backend clients) are in
`k3d/files/scripts/keycloak-post-install-k8s.sh`.

Docker Compose does not read these files: it is the fast loop to debug an app, and
`docker/keycloak/keycloak-post-install.sh` gives the apps fixed identities with local
default secrets.

**Registering with Fred.** What Fred serves is its chart's `registrations`, keyed by `app_id`
or `client_id` (a chart from 3.9.0 on), in Fred's values:
[values-swift.yaml](../k3d-apps/fred/values-swift.yaml) for this repository's applications, or a
`VALUES` file on `make k3d-app FRED=<line> APP=fred` for yours:

```yaml
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
        ui_upstream: http://acme-forecast-ui.fred-swift.svc.cluster.local:8080
        service_upstream: http://acme-forecast-api.fred-swift.svc.cluster.local:8000
        service_required: true
  knowledgeBasePublishers:         # a Knowledge Base's client and the prefix it owns
    kb-fred.opentext:
      prefix: fred.opentext
```

Registration alone grants nothing: a platform admin enables an application or a Knowledge
Base per team (**Admin > Features**).

## Application library development

Select application source with `DIR` on `make k3d-app`. The product build hook
owns its library build. `FRED_LIBS=local FRED_REPO=/path/to/fred` reaches a satellite's
build, for local Fred libraries; it does not select a namespace.

## Infrastructure and initial data

Docker Compose commands start backing services. `make k3d-up` starts
the COTS and prepares each line's boundaries. Fred
applications require a separate `make k3d-app` command. Both begin
with an empty Keycloak realm (self-registration enabled), PostgreSQL and Temporal.
Neither creates business data. There are no demo users, no Keycloak groups and no app roles baked in by either
backend. The imported Keycloak realm template never carries team groups, and no
script in this repo ever creates a Keycloak group.

The k3d foundation creates `fred_swift` (Swift), `keycloak`, `data` (tabular/vector),
`openfga` (reserved for adding Swift), `evaluation`, `temporal` and
`temporal_visibility`; a post-install Job creates each line's database, here `fred_weaver`.

Keycloak also gets the `fred-delegation` client with its `delegation_caller` role, granted
to the `agentic`, `knowledge-flow` and `control-plane` service accounts, on Docker as on
k3d: holding it is what lets a workload speak for a person. Weaver's configurations
(k3d values, and the `configuration_prod.yaml` files run on the host) turn delegation on.

Every identity and role - platform (`platform_admin`/`platform_observer`) and team
(`team_admin`/`team_editor`/`team_analyst`/`team_member`) - is provisioned afterwards by
`fred`/control-plane-backend's declarative platform-import feature
(the **Provisioning** import), not by this repo. See the Docker Compose path above for
the first login.

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
