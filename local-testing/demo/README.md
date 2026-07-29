# Demo scenario — one persona per role

15 curated users across 3 teams (`northbridge`, `fredlab`, `swiftpost`), each one exercising a
specific role so you can log in as exactly the persona you need to demo or manually check.

**Owned by the `fred` monorepo, not this repo.** The fixture
(`apps/control-plane-backend/tests/fixtures/import_export/demo_provisioning/manifest.json` +
`users.json`) and its full rationale live there — this page is a local quick-reference, not the
source of truth. If a persona's role changes, update it in `fred`, not here.

## Load it

From the `fred` monorepo (`apps/control-plane-backend`), with the local stack up and a
`platform_admin` bootstrapped (see [`../../docs/LOCAL-DEVELOPMENT.md`](../../docs/LOCAL-DEVELOPMENT.md)
steps 1-3):

```bash
make build-demo-bundle    # zips the fixture -> target/demo-provisioning-bundle.zip

curl -s -X POST http://localhost:8222/control-plane/v1/import-export/import \
  -H "Authorization: Bearer $TOKEN" -F file=@target/demo-provisioning-bundle.zip
```

Same effect as **Admin → Migration** in the UI. Every password is `Azerty123_`, every email
`<username>@app.com`. Import is async — give it a few seconds.

> Every capability is admin-gated by default — right after import, every demo team has an
> empty toolbox. Don't stop here: [`../../docs/LOCAL-DEVELOPMENT.md`](../../docs/LOCAL-DEVELOPMENT.md)
> → "Full bootstrap walkthrough" → **step 5b** turns tools/agents on.

## Who to log in as

Canonical version, kept current: `fred`'s own
[`validation/README.md`](https://github.com/ThalesGroup/fred/blob/swift/validation/README.md)
§"The complete-matrix demo users". Snapshot for quick reference:

| User | Platform role | Team role | Purpose |
| --- | --- | --- | --- |
| `alice` | **platform_admin** | none | clean platform admin, isolated from team data |
| `gabriel` | **platform_observer** | none | same isolation proof, read-only |
| `bob` | — | `team_editor` of northbridge + fredlab | editor fixture |
| `derek` | — | `team_editor` of northbridge only | proves access stays team-scoped |
| `sophia`, `marc`, `nadia` | — | `team_admin` of 1 team each | team-admin matrix |
| `phil`, `zoe`, `liam` | — | `team_member` of 1-2 teams | plain member cross-team matrix |
| `elena` | — | `team_analyst` of fredlab only | isolated analyst persona |
| `priya` | — | `team_admin` + `team_editor` + `team_analyst` of fredlab | cumulative-roles matrix (AUTHZ-06) |
| `oscar`, `nina`, `quinn` | — | none | identity-only floor/control users |

**Want a bigger, statistically-varied dataset instead** (many users per role, OpenFGA call
volume at scale)? See [`../bench/README.md`](../bench/README.md).

## Verify it end-to-end

`make validation-report` (from the `fred` repo root) logs in as every user above and asserts
the full authorization matrix — see `fred`'s `validation/README.md` for what it checks and how
to read `validation/report.md`.
