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

## Why these exact users

Every user in `config/configuration.yaml` exists to prove one specific, real
claim about who can see what - not an arbitrary pile of combinations. Read
top-to-bottom, this is the complete set needed to back up every claim in fred's
`FRED-AUTHORIZATION-TARGET-MODEL-RFC.md`, not just the escalation bug that
happened to be found first:

- **nina** - a freshly onboarded person, nothing assigned yet → proves a bare
  account gets nothing by default. This is not a synthetic edge case: it's the
  everyday state of any user between "IT created their Keycloak account" and
  "someone granted them a team or role" - Keycloak issues tokens to accounts
  with zero client roles just fine.
- **oscar** - a legacy Keycloak `admin`, member of no team at all → proves admin
  can no longer see into any team (the escalation bug that was found and fixed).
- **derek** - a legacy Keycloak `admin` who is *legitimately* a manager of one
  team only → proves the fix didn't also break real, explicitly granted access.
- **priya** - the new, clean AUTHZ-05 `platform_admin` role, nothing else →
  proves the new role works standalone and still can't see team data.
- **quinn** - the new, clean AUTHZ-05 `platform_observer` role, nothing else →
  same proof, for the read-only platform role.
- **alice, bob, phil, zoe, liam, sophia, marc, nadia** - ordinary team
  members/managers/owners across real teams → the original cross-team
  isolation matrix.

If you need to add a user later, ask first: *what specific claim does this
person prove or disprove that no existing user already covers?* If there isn't
a one-sentence answer, it's noise, not signal.

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
| `FRED_KNOWLEDGE_FLOW_URL` | `http://localhost:8111/knowledge-flow/v1` | knowledge-flow-backend base, started manually like the other apps. Only required by `test_content_scope_bypass.py`; checked lazily, not at session start. |

## The complete-matrix demo users

`config/configuration.yaml` now covers every cell of the AUTHZ-05 role matrix that
can actually be observed against a running stack, not just team-vs-team:

| user | app_roles (legacy Keycloak) | platform_roles (AUTHZ-05 target) | teams | purpose |
|---|---|---|---|---|
| alice | admin | — | manager of all 3 | original stable actor for setup/teardown |
| bob, phil, zoe, liam | editor/viewer | — | 1-2 teams, plain member | original cross-team matrix |
| sophia, marc, nadia | viewer | — | owner of 1 team each | original owner-role matrix |
| **oscar** | **admin** | — | **none** | escalation stress case: the only prior `admin` (alice) is also manager everywhere, so she can't prove a negative. oscar has zero legitimate team role anywhere. |
| **nina** | **none** | — | **none** | the floor case: authenticated, zero app_role, zero team. Every platform capability must be denied. |
| **derek** | **admin** | — | **northbridge only, manager** | proves the fix doesn't overshoot: northbridge access must keep working; fredlab/swiftpost must stay denied. |
| **priya** | none | **admin** | none | AUTHZ-05 target model in pure form: the new `platform_admin` relation, isolated from every legacy escalation path. |
| **quinn** | none | **observer** | none | AUTHZ-05 target model in pure form: `platform_observer`. |

`platform_roles` is a new, separate `configuration.yaml` field (`["admin"]` /
`["observer"]`), seeded by `openfga-post-install.sh` directly as stored
`platform_admin`/`platform_observer` OpenFGA tuples on `organization:fred` -
independent of `app_roles`, exactly matching the AUTHZ-05 target model (these
relations are never derived from a Keycloak role).

Because `scenarios/test_runtime_team_isolation.py`'s existing checks already
parametrize over every user in `USERS`, adding these 5 users to
`configuration.yaml` alone extends ~25 existing test cases for free (e.g. each
new user's `/teams` visibility and personal-space enrollment get checked
automatically) - see `test_platform_role_isolation.py` and
`test_content_scope_bypass.py` for the scenarios that specifically needed them.

**Not yet addable:** a `team_editor`/`team_analyst`-style user for the AUTHZ-05
target *team* roles. Those relations exist in fred-core's `schema.fga` but no
control-plane endpoint assigns or checks them yet (the `owner`/`manager`/`member`
vocabulary rename is deliberately deferred - see `fred`'s
`AUTHZ-MIGRATION-BACKLOG.md`). Adding fixture users for them now would be
untestable noise.

## Keeping the OpenFGA model in sync

`docker-compose/openfga/openfga-model.json` is a **hand-maintained copy**, not
generated from `fred`. On 2026-07-09 it was found to have drifted significantly
from `fred-core`'s actual `schema.fga` - missing most organization capabilities,
missing `can_read_conversations`, and (fortunately, by omission) missing a live
escalation bug that existed in `fred` at the time. It has now been synced.

```bash
make sync-openfga-model                    # uses SWIFT_SRC (default ../Work/swift)
make sync-openfga-model SWIFT_SRC=/path/to/fred
```

Run this (manually - not wired into CI) after any change to
`fred-core/fred_core/security/rebac/schema.fga`, then re-run
`make openfga-post-install` (or `make docker-up`) to push the updated model.

## Run

From the **repo root** (creates `validation/.venv` with `python3 -m venv`, installs
deps incl. local-editable `fred-core`, `fred-sdk`, and `fred-runtime`, runs the
scenarios, fails if the stack is absent or incomplete, stops at first failure):

```bash
make validate-auth-isolation-localhost
```

Override the `fred` checkout location if needed (default: `../fred`, a sibling of
this repo):
`make validate-auth-isolation-localhost SWIFT_SRC=/path/to/fred`.

Stops at the first failure by default (`-x`) - the right signal for a release
gate. To see the full pass/fail picture in one run instead (e.g. comparing an
unfixed checkout against a fixed one), clear it:
`make validate-auth-isolation-localhost PYTEST_ARGS=""`.

The target defaults to:

```text
FRED_CONTROL_PLANE_URL=http://localhost:8222/control-plane/v1
FRED_RUNTIME_PUBLIC_BASE=http://localhost:8000
```

Override `FRED_RUNTIME_PUBLIC_BASE` with the frontend/proxy origin when the goal is
to validate the exact browser-facing route.

### A short, readable report instead of raw pytest output

```bash
make validation-report
```

Runs the whole suite (no `-x` - one failure must not hide the rest), then writes
`validation/report.md`: results grouped by the real-world **claim** each test
proves (not by test function name), with a one-line verdict and a details
section for anything that failed. Meant to be readable by someone who has no
interest in opening a pytest traceback. Example shape:

```markdown
# Fred Authorization Validation Report

**Result:** NOT READY - 9 finding(s) need attention
**Totals:** 53 passed, 9 failed, 0 error, 2 known gap (xfail), 1 possible infra issue, 0 skipped

## Platform-role isolation (AUTHZ-05)

| Result | Claim |
|---|---|
| FAIL | oscar (legacy Keycloak admin, member of no team) cannot read fredlab's agent catalog. |
| FAIL | oscar (legacy Keycloak admin, member of no team) sees zero collaborative teams. |
| PASS | derek (admin app role, real manager of northbridge only) can still read northbridge's catalog. |
| PASS | priya (AUTHZ-05 platform_admin/platform_observer, zero teams) cannot read fredlab's catalog. |
...

## Content-scope bypass (known gap, not yet fixed)

| Result | Claim |
|---|---|
| GAP | oscar (global admin, member of no team) must not read platform content capabilities. |
| GAP | liam (viewer, swiftpost only) must not read content capabilities scoped to other teams. |
```

This is the minimal version of the tag-bound evidence report already specced in
`RFC-C3-validation-extensions.md` (Extension F) - grouping and a verdict, nothing
more. Attaching it to a git tag/commit with signed, retained artifacts
(`pytest.xml`, `environment.json`, checksums) is future work, not done here.

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
- **Platform-role isolation (AUTHZ-05)**: a legacy Keycloak `admin` with no team
  membership cannot read a team's catalog (`oscar`); the same admin who *is* a
  legitimate manager of exactly one team keeps that access without it leaking to
  others (`derek`); the new target `platform_admin`/`platform_observer` relations
  grant zero team data on their own (`priya`, `quinn`). See
  `scenarios/test_platform_role_isolation.py`.
- **Organization-scoped content bypass (known gap, not yet fixed)**:
  `scenarios/test_content_scope_bypass.py` demonstrates that
  `can_read_content`/`can_process_content` are gated at organization scope, not
  team scope, in knowledge-flow-backend today. Marked `xfail(strict=True,
  raises=AssertionError)` on purpose - it is expected to fail (reproduce the gap)
  until the upstream fix ships; an unexpected pass turns the run red instead of
  silently going green on a fixed vulnerability nobody re-checked. Requires
  knowledge-flow-backend running (see `FRED_KNOWLEDGE_FLOW_URL` above).
