# Local development stack

Run Fred's backing services on your laptop — for day-to-day development against a local Fred,
or to host the auth/isolation validation release gate, which now lives in the sibling `fred`
monorepo's own `validation/README.md` (run `cd ../fred && make validation-report`). Fred itself
can run on just ChromaDB + SQLite + the local filesystem; this repo gives the fuller
experience (real Postgres, Keycloak, OpenFGA, OpenSearch, Temporal, plus optional
Prometheus / Grafana / ClickHouse / Langfuse).

Two backends, same Make interface: **Docker Compose** (default, simplest) and **k3d** (local
Kubernetes). For the raw Compose internals (shared network, `.env`, per-service files) see
[`../docker/README.md`](../docker/README.md).

**Prerequisites:** Docker, Docker Compose (`docker compose`), `bash`. (k3d path also needs
`k3d`, `kubectl`, `helm`.)

## Quick start (Docker Compose)

```bash
make docker-up                  # base stack: core Fred services
make docker-up STACK=extended   # + Prometheus, Grafana, ClickHouse, Langfuse
```

Optional — browser SSO callbacks to Keycloak on localhost:

```bash
grep -q '127.0.0.1.*app-keycloak' /etc/hosts || echo "127.0.0.1 app-keycloak" | sudo tee -a /etc/hosts
```

Cleanup:

```bash
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
> && make bootstrap-local BOOTSTRAP_USER=<you>` gets you steps 1-3 in one line, pausing
> only for the one step that has to stay manual (registering yourself in Keycloak, see
> step 3 below). Before importing the demo bundle (step 4), populate its 15 named
> users in Keycloak — one command from **this** repo, `local-testing/demo/
> seed-keycloak-users.sh` (see step 4). Import and capability activation (step 5b)
> then have a perfectly good UI once the frontend is up — **Admin > Migration**,
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

```bash
make bootstrap-token    # writes target/bootstrap-token; never overwrites, never printed by the app
```

Fred never creates accounts in Keycloak, on purpose: **Keycloak authenticates, Fred/
OpenFGA authorizes** (`docs/swift/platform/REBAC.md` in the `fred` repo) — the same
boundary a real SSO deployment has, so a compromised or buggy Fred can never mint
identities in your corporate IdP. That means the one unavoidable manual step: self-
register a user through **Keycloak's own** registration screen — no Fred frontend
needed yet: open `http://localhost:8080/realms/app/account` → "Register". Then:

```bash
TOKEN=$(curl -s http://localhost:8080/realms/app/protocol/openid-connect/token \
  -d grant_type=password -d client_id=app \
  -d username=<your-username> -d password=<your-password> \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl -s -X POST http://localhost:8222/control-plane/v1/bootstrap/platform-admin \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"token\": \"$(cat target/bootstrap-token)\"}"
```

One-shot and permanent — a second call, ever, returns `409`. You are now the platform's
root `platform_admin`.

**4. Import the demo dataset**

The import assigns teams/roles to the 15 named demo users (`alice`, `bob`, `marc`, …) — it
does **not** create their Keycloak identities (same "Fred never creates accounts in
Keycloak" rule as step 3); an unresolved username is skipped and reported, not silently
dropped. Populate them first, one command, from **this** repo:

```bash
cd ../fred-deployment-factory/local-testing/demo
./seed-keycloak-users.sh    # reads the 15 usernames from fred's users.json, idempotent
```

Then, back in `fred/apps/control-plane-backend`:

```bash
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
gotcha to worry about. `$TOKEN` from step 3 is still valid here (an AUTHZ-07 root
`platform_admin` grant never expires or gets revoked by later steps). If `CAP_IDS`
below still comes back empty, check `fred-agents`' terminal from step 2 for a
startup error before assuming this step itself is broken.

```bash
CAP_IDS=$(curl -s http://localhost:8222/control-plane/v1/admin/capabilities \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import sys,json; print("\n".join(i["id"] for i in json.load(sys.stdin)["items"]))')

for id in $CAP_IDS; do
  echo "default-on: $id"
  curl -s -X PUT "http://localhost:8222/control-plane/v1/admin/capabilities/$id/default-on" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"default_on": true}'
  echo
done
```

If `CAP_IDS` comes back empty, `fred-agents` isn't reachable yet — check its
terminal from step 5 before assuming this step itself is broken.

A capability with *required* team settings refuses default-on (`409`) — it needs a
value only a team can supply, so it can't have a platform-wide default. For those,
grant it to one demo team explicitly instead, with whatever settings it needs:

```bash
curl -s -X PUT "http://localhost:8222/control-plane/v1/admin/capabilities/<id>/teams/<team_id>" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"settings": {}}'
```

None of the current demo/stock capabilities require this — the loop above is normally
enough. Same effect as **Admin → Capabilities** in the UI once the frontend is up —
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

## Stack profiles: `base` vs `extended`

`STACK` selects which services launch, for both `make docker-up` and `make k3d-up`:

| `STACK` | Services |
|---------|----------|
| `base` (default) | Minimal stack — drops ClickHouse, Langfuse, Redis, Prometheus, Grafana |
| `extended` | Full stack, including ClickHouse, Langfuse (+ Redis), Prometheus, Grafana |

For Helm this maps to the chart value `stack` (`--set stack=<profile>`); extended-only
components deploy only when `stack=extended` **and** their own `enabled` flag is set.

## k3d + Helm stack

A local Kubernetes path: a vanilla `k3d` cluster + the `k3d` chart (covers the
structural stack + Prometheus + Grafana + ClickHouse; Langfuse stays Compose-only). Optional
Cilium (`K3D_USE_CILIUM=true`) only for `CiliumNetworkPolicy` / air-gap flows.

```bash
make k3d-up            # create cluster 'fred', install the 'fred-stack' release into namespace 'fred'
make k3d-wipe          # full reset (down + delete)
```

Host ports (override with `K3D_HOST_PORT_*` if they clash with the Compose stack): Postgres
`:5432`, Keycloak `:8080`, SeaweedFS S3 `:8333`, OpenSearch `:9200`, OpenFGA HTTP `:9080` /
gRPC `:9081`, Temporal gRPC `:7233` / UI `:8233`, Prometheus `:9090`, Grafana `:3002`,
ClickHouse `:8123`. `make k3d-up` prefetches images, retries transient pull failures, and uses
`helm upgrade --install --rollback-on-failure`, so rerunning it converges cleanly.

Tear down: `make k3d-down` (uninstall release) · `make k3d-delete` (delete cluster) ·
`make k3d-wipe` (both).

## What `docker-up` / `k3d-up` provisions

One mode, no flags. Both backends provision the same thing: Keycloak with an **empty realm**
(self-registration enabled), OpenFGA with an **empty store** and the Swift authorization model
only, Postgres, and Temporal - infrastructure only, zero business data. There are no demo
users, no Keycloak groups, no app roles, and no OpenFGA tuples baked in by either backend. The
imported Keycloak realm template never carries team groups, and no script in this repo ever
creates a Keycloak group.

Databases created: `fred` (Fred), `keycloak`, `data` (tabular/vector), `openfga`, `temporal`,
`temporal_visibility`.

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
- **k3d:** `auth.keycloak*ClientSecret` in `k3d/values.yaml`.
