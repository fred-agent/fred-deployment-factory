# `validation/` - black-box validation of a running Fred platform

This is **not** a test of the deployment-factory itself. It is a small pytest app
that logs in **as the real users** defined in
[`../config/configuration.yaml`](../config/configuration.yaml) (alice, bob, phil,
...) and asserts the **authorization matrix** expected by the no-grant runtime
authorization model.

The current supported mode is **localhost auth/isolation validation**: backing
services run in Docker (Keycloak, Postgres, OpenFGA, OpenSearch, Temporal, ...),
while the Fred applications run in the foreground from the `swift` checkout
(`apps/control-plane-backend`, `apps/fred-agents`, `apps/knowledge-flow`,
`apps/frontend`) using their `configuration_prod.yaml`.

It reads the user/role/team matrix straight from `../config/configuration.yaml`, so
there is **no drift**: change the users there and the assertions follow.

## Why it exists

RBAC/ReBAC is per-identity and complex. Testing it by hand from the UI is a
non-starter (a browser is one identity at a time). This driver holds **many
identities** and checks who can do what - the honest way to validate ReBAC.

## Supported validation modes

### Current mode - localhost auth/isolation

This is the current black-box release-validation mode.

1. Start the deployment-factory Docker infrastructure: Keycloak, Postgres,
   OpenFGA, OpenSearch, Temporal and the other backing services.
2. Start the Fred applications manually from the `swift` checkout, in separate
   terminals, using their `configuration_prod.yaml`:
   - `apps/control-plane-backend`
   - `apps/fred-agents`
   - `apps/knowledge-flow` / worker if the tested flow needs it
   - `apps/frontend` if you want to validate the browser-facing proxy path
3. Point `FRED_CONTROL_PLANE_URL` at the manually started control-plane, usually
   `http://localhost:8222/control-plane/v1`.
4. Point runtime calls at the same public base that a browser would use for the
   `execute_stream_url` returned by `prepare-execution`. In the current direct
   runtime setup, that is usually the manually started `fred-agents` server, not
   the control-plane port.

Important: `prepare-execution` returns ingress-relative URLs such as
`/fred/agents/v2/agents/execute/stream`. Those URLs are **not** served by the
control-plane itself. If `FRED_CONTROL_PLANE_URL` is `http://localhost:8222`,
calling `http://localhost:8222/fred/agents/v2/...` is expected to return `404`.
That is a harness/routing configuration issue, not by itself a runtime authz
failure.

### Mode B - browser/proxy path

When the frontend nginx/Vite proxy is running and exposes both `/control-plane/...`
and `/fred/agents/v2/...`, the validation can target the same public origin as
the browser. This is closer to the UI path, but it also tests the proxy routing in
addition to runtime authorization.

### Mode C - future full k3d validation

`make validate-auth-isolation-k3d` is reserved for a future mode. It will deploy
Keycloak/backing services and all Fred apps inside k3d, then run the same
black-box suite against the k3d ingress. That is the right direction for a more
deployment-representative C3 evidence path, but it is explicitly **not** required
for the current revamp validation. Track it as a follow-up task, not as a blocker
for this harness.

## Prerequisites

1. **Running backing services and Fred apps** according to one of the modes above.
   Keycloak must be seeded with the `configuration.yaml` users.
2. **Direct-grant on the `app` Keycloak client** (test realm only). The validation
   logs users in with the *password grant*; the `app` client must allow it.
   In the realm template (`docker-compose/keycloak/app-realm.json.template`), the
   `app` client must have:
   ```json
   "directAccessGrantsEnabled" : true
   ```
   Then re-import the realm (restart Keycloak / re-run the keycloak post-install).
   **Test/dev only** - do NOT enable ROPC on a real integration / C3 realm.
3. **No grant signing requirement.** This suite targets RUNTIME-07 rev. 2: the
   control-plane does not issue `ExecutionGrant`; runtime pods validate the user
   JWT and perform pod-side OpenFGA checks.

## Configuration (env vars, with local defaults)

| Var | Default | Meaning |
|---|---|---|
| `FRED_REALM_URL` | `http://localhost:8080/realms/app` | Keycloak realm URL |
| `FRED_CLIENT_ID` | `app` | Public client used for the password grant |
| `FRED_USER_PASSWORD` | `Azerty123_` | Shared password of the factory users |
| `FRED_CONTROL_PLANE_URL` | `http://localhost:8222/control-plane/v1` | Control-plane API base. In localhost auth/isolation mode this is the direct control-plane app, not the runtime/frontend origin. |
| `FRED_RUNTIME_PUBLIC_BASE` | `http://localhost:8000` via `make validate-auth-isolation-localhost` | Public origin used to resolve ingress-relative runtime URLs returned by `prepare-execution`, e.g. direct `fred-agents` or the frontend origin for proxy-path validation. |
| `FRED_CONFIG_PATH` | `../config/configuration.yaml` | Source of truth for users/roles |
| `FRED_TEST_TEAM` | `fredlab` | Collaborative team used for isolation checks |
| `FRED_TEST_AGENT_ID` | `fred.github.test_assistant` | Public no-LLM agent used for deterministic runtime execution |

## Run

From the **repo root** (creates `validation/.venv` with `python3 -m venv`, installs
deps incl. local-editable `fred-core`, `fred-sdk`, and `fred-runtime`, runs the
scenarios, fails if the stack is absent or incomplete, stops at first failure):

```bash
make validate-auth-isolation-localhost
```

Override the swift checkout location if needed:
`make validate-auth-isolation-localhost SWIFT_SRC=/path/to/swift`.

The target defaults to:

```text
FRED_CONTROL_PLANE_URL=http://localhost:8222/control-plane/v1
FRED_RUNTIME_PUBLIC_BASE=http://localhost:8000
```

Override `FRED_RUNTIME_PUBLIC_BASE` with the frontend/proxy origin when the goal is
to validate the exact browser-facing route.

## What it checks

- **Identity + ReBAC membership**: each user sees exactly their teams.
- **Catalog premise**: the chosen public test agent is visible in the team catalog.
- **prepare-execution isolation**: a team member can prepare runtime execution; a
  non-member is denied; the response contains no `execution_grant`.
- **Runtime pod-side authorization**: a member can call the SSE runtime stream with
  a Keycloak JWT; a non-member cannot bypass the control-plane by calling the pod
  directly with another user's `team_id`.
- **Identity hardening**: a forged `runtime_context.user_id` does not become the
  runtime identity.
- **Enrollment authorization**: a plain member cannot enroll an agent in a
  collaborative team; a user can enroll in their own personal space.
