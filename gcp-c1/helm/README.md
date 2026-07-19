# Fredlab Infra

Helm chart for Fredlab Playground on GKE Autopilot.

## Scope

| Component | Visibility | Internal DNS | Public host |
| --- | --- | --- | --- |
| PostgreSQL | Private | `postgres:5432` | none |
| Keycloak | Public | `keycloak:8080` | `keycloak.playground.fredlab.dev` |
| OpenFGA | Private | `openfga:8080`, `openfga:8081` | none |
| OpenSearch | Private | `opensearch:9200` | none |
| Temporal | Private | `temporal:7233` | none |
| Temporal UI | Protected admin UI | `temporal-ui:8080` | `temporal.playground.fredlab.dev` |
| Control Plane backend | Private | `control-plane-backend:8080` | none |
| Fred frontend | Public | `fred-frontend:8080` | `studio.playground.fredlab.dev` |
| GMP query frontend | Private | `gmp-frontend:9090` | none |
| Grafana | Protected admin UI | `grafana:3000` | `grafana.playground.fredlab.dev` |

All services use `ClusterIP`. Public routing is handled by the GKE `gce` Ingress named `fredlab-infra-ingress`.

Public hostnames must exist in DNS outside Helm and point to the reserved GCP global IP `8.233.26.38`.

Each public hostname has its own GKE `ManagedCertificate`, all attached to the same Ingress:

- `fredlab-infra-cert` for Keycloak
- `fredlab-temporal-cert` for Temporal UI
- `fredlab-studio-cert` for Studio
- `fredlab-grafana-cert` for Grafana

This avoids mutating an already-attached Google-managed certificate when new public hosts are added.

## Naming Rules

The chart avoids Helm release-name prefixes for service DNS:

- infrastructure services use fixed short names: `postgres`, `keycloak`, `openfga`, `opensearch`, `temporal`
- app backends use `[app-name]-backend`
- app frontends use `[app-name]-frontend`
- admin UIs use `[component]-ui`

## Security

The chart is designed for GKE Autopilot:

- no privileged containers
- no node-level `sysctl`
- no privileged `chown` init jobs
- explicit CPU and memory requests
- real secrets live in `fredlab-secrets.values.yaml`, ignored by Git

OpenSearch runs as an internal single-node StatefulSet for playground search workloads. It deliberately uses `node.store.allow_mmap=false` instead of requiring the forbidden node-level `vm.max_map_count` sysctl. It is not exposed through Ingress.

Temporal UI has no built-in authentication, so it is gated by **Keycloak OIDC**: the UI
requires a Keycloak login (realm `app`) before it is shown. This is configured under
`temporal.ui.auth` and backed by the confidential `temporal-ui` client provisioned by the
`keycloak-provision` job. An optional Cloud Armor IP allowlist can be layered in front via
`adminAccess.securityPolicyName` (empty = not used).

**Login alone isn't enough — a second, role-based gate runs after authentication.** Any
realm user can pass Keycloak login, but a custom browser flow bound only to the
`temporal-ui` client (`temporal-ui-gate`, built by `keycloak-provision`) then denies anyone
who doesn't hold the Keycloak client role named in `temporal.ui.auth.allowedAppRole`
(default `temporal_operator`). Studio and the gRPC services are untouched by this flow —
it's scoped to the `temporal-ui` client only. Set `allowedAppRole: ""` to drop the gate
entirely (any authenticated realm user gets in).

This role is deliberately **not** named `admin`/`editor`/`viewer` — those are Swift's
deleted legacy Keycloak-role bridge (AUTHZ-05/07; `bin/fred-preflight.sh` treats their
reappearance as a critical regression). `temporal_operator` means one thing only — "may
view the Temporal admin UI" — and is never referenced by `fred-core`/OpenFGA.

**Granting access to a new operator** (identities are Swift-native — see `docs/DEPLOY-CLOUD.md`
§5.1 — this role is the one exception where a human still needs a Keycloak *client* role,
because Temporal UI has no concept of Fred's OpenFGA-based teams/platform roles):

```bash
kubectl -n <instance> exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh add-roles \
  -r app --uusername <their-keycloak-username> --cclientid app --rolename temporal_operator
```

## Data Ownership

PostgreSQL provisioning and application schema migrations are intentionally separated:

| Layer | Responsible object | Creates |
| --- | --- | --- |
| Database bootstrap | `postgres-provision` Helm hook | PostgreSQL users, databases, grants |
| Identity bootstrap | `keycloak-provision` Helm hook | Keycloak realm `app`, clients `app` and `control-plane` |
| Search engine | `opensearch` StatefulSet | Private OpenSearch HTTP endpoint for hybrid search |
| Control Plane schema | `control-plane-migration` Helm hook | Control Plane tables via `alembic upgrade head` |
| Control Plane runtime | `control-plane-backend` Deployment | HTTP service only |

For Swift, the current Fred repository contains multiple Alembic revisions. Fredlab applies the repository contract as-is with `alembic upgrade head`. Before a first production Swift release, decide separately whether to keep this history or squash it into a single bootstrap migration.

## Identity State

Deploying Keycloak only starts the identity server. Fred still needs a provisioned realm and clients:

- realm `app`
- public frontend client `app`
- confidential machine client `control-plane`
- matching `keycloak.clients.controlPlane.secret`
- service-account roles required by Control Plane: `realm-management` `manage-users`/`view-users`/`query-users` and `app:service_agent`. No group-scoped role (`query-groups`/`account:view-groups`) - Control Plane never calls a Keycloak group-admin API; OpenFGA is the sole authorization source (AUTHZ-05/06).
- users for the Fred Swift identity model - a Swift team is never a Keycloak group; team roles are created later through the control-plane team APIs, not by this bootstrap

The chart provisions the realm and clients with the `keycloak-provision` Helm hook. The control-plane reads the machine client secret from the exact env var `KEYCLOAK_CONTROL_PLANE_CLIENT_SECRET`.

User and team/group provisioning remains a separate application-domain step. Do not confuse it with the low-level realm/client bootstrap.

For the current Fredlab phase, only the `control-plane` service client is provisioned. Future deployments of `knowledge-flow-backend` and `fred-agents` must add their own confidential clients and secrets (`knowledge-flow` / `KEYCLOAK_KNOWLEDGE_FLOW_CLIENT_SECRET`, `agentic` / `KEYCLOAK_AGENTIC_CLIENT_SECRET`) before those services are enabled.

In Swift, Keycloak creates identity ONLY. A team is a `team_metadata` row + OpenFGA
relations, created via the control-plane APIs: `POST /teams` (platform-admin bootstrap with
an explicit `initial_team_admin_ids`), then
`POST /teams/{team_id}/members/{user_id}/roles` / `DELETE
/teams/{team_id}/members/{user_id}/roles/{relation}` to grant/revoke individual, cumulative
roles (`team_admin`/`team_editor`/`team_analyst`/`team_member`) - the same contract
`fred`'s own `validation/conftest.py::_bootstrap_collaborative_teams` exercises against a
local stack.
Platform roles (`platform_admin`/`platform_observer`) are stored-only OpenFGA relations on
`organization:fred`, seeded directly (never derived from a Keycloak group or app role).

There is not yet a Swift-native onboarding path for real GKE users - the prior Kea-legacy
onboarding script (`bin/fredlab-keycloak-identity.sh`, which provisioned Keycloak
groups/app-roles for the pre-AUTHZ-05 shape) was removed outright rather than adapted; see
**SEC-3** in `docs/BACKLOG.md` for the current state and what building a real one would need.

When validating Keycloak clients, always use `kcadm.sh --fields ...`. The full representation of the confidential `control-plane` client includes its secret.

## Legal Content

The frontend has two separate configuration phases:

- `/config.json` is read before login and before CGU acceptance.
- `/control-plane/v1/frontend/bootstrap` is read after authentication and is protected by CGU acceptance when `controlPlane.config.gcuVersion` is set.

Because of that ordering, the chart publishes `properties.gcuVersion` in `/config.json`. This lets the frontend know that CGU are required before calling protected bootstrap routes.

The frontend reads CGU/GDPR Markdown files from its public web root:

- `/gcu.fr.md`, `/gcu.md`
- `/gdpr.fr.md`, `/gdpr.md`

Fredlab overrides the generic files bundled in the frontend image with a Helm-managed ConfigMap. Edit the public files in:

```text
gcp-c1/helm/legal/
```

These files are not secrets. They should be committed, reviewed, and validated like product-facing documentation. Changing the text does not require rebuilding the frontend image; redeploy the chart or run the frontend deploy script.

If a first login shows `Control plane non accessible`, verify that `/config.json` contains `properties.gcuVersion`. Without that pre-auth value, the UI cannot reliably route the user to CGU before the protected bootstrap call fails.

## Private Values

Create one complete local secret file from:

```bash
cp gcp-c1/helm/fredlab-secrets.values.example.yaml \
   gcp-c1/helm/fredlab-secrets.values.yaml
```

Required values:

- `postgresql.admin.password`
- `postgresql.keycloak.password`
- `postgresql.openfga.password`
- `postgresql.temporal.password`
- `postgresql.fred.password`
- `keycloak.admin.password`
- `keycloak.clients.controlPlane.secret`
- `openfga.auth.apiToken`

If knowledge-flow's GCS content store is in play anywhere in this environment —
including when `knowledgeFlow.enabled: false` on **this** release, if
`migration.enabled` or `knowledgeFlowWorker.enabled` still render the
`knowledge-flow-config` ConfigMap (see STORAGE-INVENTORY.md §3) — also set:

- `knowledgeFlow.config.storage.signingServiceAccountEmail`
- `knowledgeFlow.config.models.project`

Neither has a safe empty default; leaving either blank crashes
`knowledge-flow-backend` at startup. Worse, this chart and
`gcp-c1/argocd/fred-apps` currently render the same ConfigMap name, so a
Foundation deploy with these unset can silently overwrite a correct
GitOps-managed copy with a broken one — see `docs/DEPLOYMENT-GUIDE.md` §4 for
what actually happened and how to check for this on any deploy.

Validate that the secret file is ignored:

```bash
git status --short --ignored gcp-c1/helm/fredlab-secrets.values.yaml
```

Expected:

```text
!! gcp-c1/helm/fredlab-secrets.values.yaml
```

## Deploy

Use [DEPLOYMENT-STEPS.md](./DEPLOYMENT-STEPS.md) for the canonical GKE deployment procedure.

Shared team operating agreements — image tagging, deploy round, how to read what
is live — are in [OPERATING-CONVENTIONS.md](./OPERATING-CONVENTIONS.md). Build and
deploy with the convention tag `YYYYMMDD-<shortsha>` (e.g. `20260624-9ee83e7`),
the same tag across every image in a round; the `0.2` examples below are
illustrative only.

**Everyday code redeploy** — once the stack is up, pulling a new `~/fred` and
pushing it live is one command (derives the tag, builds only what changed,
fast-redeploys control-plane + frontend + agents). See
[OPERATING-CONVENTIONS.md §C2.2](./OPERATING-CONVENTIONS.md):

```bash
bin/fredlab-ship
```

The phase-by-phase commands below use the generic `bin/fredlab-deploy.sh
<component> <action>` (components: `control-plane`, `frontend`, `agents`,
`knowledge-flow`, `evaluation`) and are for first bring-up or out-of-loop
deploys.

Foundation:

```bash
bin/fredlab-infra-deploy.sh
```

Use this script instead of a raw `helm upgrade` after application components have been enabled. It preserves the current Helm release values, so Control Plane and Studio are not accidentally disabled during a foundation upgrade.

Images:

Image builds are driven by a small committed catalog: [config/fredlab-images.tsv](../../config/fredlab-images.tsv). This keeps daily commands short while making the required conventions explicit.

```bash
bin/fredlab-gcp-build-prereqs.sh
bin/fredlab-build list
bin/fredlab-build control-plane-backend 0.2
bin/fredlab-build frontend 0.2
bin/fredlab-build fred-agents 0.2
```

The catalog assumes source repositories exist in Cloud Shell at paths such as `~/fred`, `~/dt-agents`, or `~/fred-samples`, and that each image has a Dockerfile path declared from that repository root.

GCS preparation:

Knowledge Flow and agentic components should use Google Cloud Storage on GKE, not an in-cluster MinIO replacement. The current chart only prepares GCP for this future Swift capability; it does not yet wire Knowledge Flow to GCS.

```bash
bin/fredlab-gcp-gcs-prereqs.sh
```

This creates the future Knowledge Flow bucket, a Google service account, and Workload Identity bindings for the expected Kubernetes service accounts. No JSON key, HMAC key, or secret file is created.

Control Plane runtime:

```bash
bin/fredlab-deploy.sh control-plane migrate 0.2
bin/fredlab-deploy.sh control-plane start 0.2
```

The deployment phase stays explicit: `migrate` runs Alembic database migrations first, then `start` launches the HTTP backend. On a fresh database, migrations create the initial Control Plane tables.

Control Plane does not use the image's bundled `configuration_prod.yaml` directly. The chart renders a Fredlab-specific `control-plane-config` ConfigMap and sets `CONFIG_FILE=/etc/fred/control-plane/configuration.yaml`, so cluster DNS names, Keycloak issuer, OpenFGA, Temporal, and the health path are owned by Helm values.

Frontend runtime:

```bash
bin/fredlab-deploy.sh frontend start 0.2
```

This deploys the public `fred-frontend` service at `https://studio.playground.fredlab.dev`. The frontend stays thin: Nginx serves the static UI and proxies `/control-plane/...` to `control-plane-backend:8080`. The login configuration still comes from Control Plane through `/control-plane/v1/frontend/config`.

The CGU/GDPR pages are served from `gcp-c1/helm/legal/` through a ConfigMap mounted in the frontend pod. After changing those files:

```bash
bin/fredlab-deploy.sh frontend start 0.2
```

During the first bootstrap, `fred-agents` and `knowledge-flow-backend` are not deployed yet. Their frontend upstreams intentionally point to `control-plane-backend` so Nginx can start; they must be switched to their real services when those components are deployed.

The deploy scripts preserve existing Helm release values when the release already exists, while also loading new chart defaults. That allows enabling frontend after Control Plane without accidentally disabling the components that are already running.
