# Local testing — demo vs. bench

Two ready-made local datasets you can load on top of `make docker-up`, depending on what
you're trying to see:

| Scenario | What it's for | Guide |
| --- | --- | --- |
| 🎭 **demo** | A small, curated team with one persona per role (`platform_admin`, `team_admin`, `team_editor`, `team_analyst`, `team_member`, …) — for manually demoing Fred or checking "does this role see what it should". | [`demo/README.md`](demo/README.md) |
| 📈 **bench** | 3000 synthetic users across 100 teams — for load-testing and observing OpenFGA call volume/latency at scale (teams-list bootstrap, imports, …). | [`bench/README.md`](bench/README.md) |

Both assume you've already done the base bootstrap — `make docker-up`, then bootstrapped the
first `platform_admin` — described in [`../docs/LOCAL-DEVELOPMENT.md`](../docs/LOCAL-DEVELOPMENT.md)
("Full bootstrap walkthrough", steps 1-3). This folder picks up from there.

## `scripts/`

Shared helpers used by both scenarios, for driving the local Keycloak/OpenFGA stack directly
(not through Fred's own APIs):

| Script | Does |
| --- | --- |
| [`scripts/keycloak-add-user.sh`](scripts/keycloak-add-user.sh) | `<username>` — create one Keycloak identity, no OpenFGA tuples (simulates a brand-new SSO login Fred doesn't know yet). `--count N [--prefix P]` — bulk-create N synthetic users via Keycloak's `partialImport` endpoint (seconds/thousands of users, not minutes — see `bench/README.md`). |
| [`scripts/keycloak-delete-user.sh`](scripts/keycloak-delete-user.sh) | `<username>` — remove a Keycloak identity and every OpenFGA tuple that references it. |
| [`scripts/keycloak-openfga-info.sh`](scripts/keycloak-openfga-info.sh) | Dump every Keycloak user and their resolved OpenFGA rights as JSON — quick "who can do what right now" check. |
| [`scripts/keycloak-lib.sh`](scripts/keycloak-lib.sh) | Shared config/helpers the three scripts above source — not meant to be run directly. |

All three take usernames, not full identities — run them from this repo with the local stack
(`make docker-up`) up.
