# Bench scenario — OpenFGA at scale

3000 synthetic users across 100 teams, for load-testing and watching OpenFGA call
volume/latency under realistic team-membership fan-out (teams-list bootstrap, bundle import,
capability checks, …) — rather than demoing a specific role.

Two steps: populate Keycloak identities here (this repo), then build and import the matching
role/team bundle from the `fred` monorepo.

## 1. Populate Keycloak

From this repo, with the local stack up (`make docker-up`):

```bash
./scripts/keycloak-add-user.sh --count 3000 --prefix user
```

Creates `user0001` .. `user3000`, password `Azerty123_`, email `<username>@app.com`. Goes
through Keycloak's `partialImport` endpoint in chunks of 500 rather than one `kcadm` call per
user — expect roughly 1-2 minutes for 3000, not 30+. Idempotent: re-running skips usernames
that already exist, so it's safe to top up after a partial run. `--prefix`/`--count` must match
what you pass to the bundle generator in step 2, or usernames won't line up.

## 2. Build and import the team/role bundle

From the `fred` monorepo (`apps/control-plane-backend`):

```bash
make build-load-test-bundle LOAD_TEST_USERS=3000 LOAD_TEST_TEAMS=100 LOAD_TEST_PREFIX=user
# -> target/load-test-provisioning-bundle.zip

curl -s -X POST http://localhost:8222/control-plane/v1/import-export/import \
  -H "Authorization: Bearer $TOKEN" -F file=@target/load-test-provisioning-bundle.zip
```

Same effect as **Admin → Migration** in the UI. This is a generated, git-ignored bundle
(`tools/generate_load_test_bundle.py`) — not the curated demo fixture in `demo/`. Every team
gets a guaranteed `team_admin`; the rest of the ~3900 team memberships (avg. 1.3 teams/user)
scatter randomly across `team_member` / `team_editor` / `team_analyst`, reproducibly (fixed
seed — same command, same usernames/teams every time).

The import itself writes one OpenFGA tuple per role grant, sequentially — expect this phase to
take a while at this scale; that's a separate, known characteristic of the bundle importer, not
something wrong with this bench setup.

## Who to test with

No `platform_admin`/`platform_observer` in this bundle by design — use your own bootstrapped
root admin for platform-level checks (see
[`../../docs/LOCAL-DEVELOPMENT.md`](../../docs/LOCAL-DEVELOPMENT.md) step 3).

For a side-by-side comparison of every team role **on the same team** (`team001`, with the
default `--prefix user --teams 100` above):

| Role | User | Notes |
| --- | --- | --- |
| `team_admin` | `user2620` | the one guaranteed admin of `team001` |
| `team_editor` | `user0074` | one of 12 editors on `team001` |
| `team_analyst` | `user0065` | one of 13 analysts on `team001` |
| `team_member` | `user0027` | one of 7 plain members on `team001` |

All passwords `Azerty123_`, emails `<username>@app.com`.

Across the whole bundle: 100 `team_admin` (exactly 1 per team), ~1041 `team_editor`, ~1045
`team_analyst`. 12 users hold all three roles at once — but each on a *different* team (e.g.
`user0131`: admin on `team014`, analyst on `team074`, editor on `team009`) — useful if you want
one identity that switches roles depending which team it's acting in.

These exact usernames come from the generator's default seed (`42`) — they stay stable across
re-runs as long as `--users`/`--teams`/`--prefix`/`--seed` don't change. If you regenerate with
different parameters, re-derive them with a short Python snippet against the unzipped
`users.json` rather than trusting this table.

**Want a small, curated dataset with one clear persona per role instead?** See
[`../demo/README.md`](../demo/README.md).
