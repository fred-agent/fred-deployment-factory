# fred-deployment-factory — GitOps hardening backlog

Follow-ups to take the deployment pattern from "works on the playground" to
"corporate standard." Design rationale: `docs/rfc/RFC-0001-gitops-deployment-pattern.md`.
External narrative: `fred-website/slides/fred_deployment_pattern.md`.

> **This repo is a C1 reference sample** (public GKE). The architecture is the same at every
> classification; what hardens at C2/C3 (sovereign, S3NS) are three knobs — secrets source,
> network segmentation, admin exposure. See RFC §6 and the `CLASS` theme below.

Status: `[ ]` todo · `[~]` in progress · `[x]` done. IDs are referenced from the RFC.

---

## Proven / done (baseline — do not regress)

- [x] All four apps (cp, kf+worker, fa, fr) under ArgoCD `fred-apps`, pinned to the running tag.
- [x] AUTHZ-WIKI-08 scheduled automation infra foundation: Docker and k3d realm templates define
      the dedicated confidential `fred-ai-wiki-worker` service client with service accounts enabled,
      app audience, runtime-only secret plumbing, and no seeded team delegation tuples.
- [x] A/B boundary enforced in `gcp-c1/argocd/fred-apps/Chart.yaml`; apps reference infra by name.
- [x] Config-faithful cutover method (render + byte-diff vs live ConfigMap) — keep using it.
- [x] Frontend edge decoupled via `fredFrontend.ingressEnabled` (Ingress/cert/BackendConfig
      stay in infra; no cert churn on workload moves).
- [x] `/ready` status probe hardened against Autopilot cold-start (`bin/fredlab-status.sh`).
- [x] Rollout strategy `maxSurge: 0 / maxUnavailable: 1` on all fred-apps Deployments (mirrored
      in `gcp-c1/helm`) — replaces pods in place so a small cluster doesn't need a surge
      node. Without it, four simultaneous surges + a node-autoprovision GCE-quota hit wedge pods
      in `Pending`. See `gcp-c1/argocd/README.md` "Small-cluster rollout note".

---

## GITOPS — trust the loop

- [x] **GITOPS-1** `bin/fredlab-release.sh` handles `all` + each component (`control-plane`,
      `frontend`, `fred-agents`, `knowledge-flow`) via a component→build-name→marker map; reuses
      the `# release-tag:` markers in `values-fredlab.yaml`. `bin/fredlab-build all` builds the
      four app images in one call.
- [ ] **GITOPS-2** Enable `automated: { selfHeal, prune }` on the `fred-apps` Application once
      the loop is trusted. Decide prune safety per resource. (RFC Q3)
- [x] **GITOPS-3** `bin/fredlab-argocd-sync.sh` triggers the sync via `kubectl` (refresh + patch
      `operation.sync` to HEAD; warns if HEAD isn't pushed). No `argocd` CLI required.

## SEC — secrets & identity

- [ ] **SEC-1** Replace the local git-ignored `fredlab-secrets.values.yaml` with a real backend:
      evaluate External-Secrets-Operator / Vault / SOPS-in-git. Pick one. (RFC Q2)
- [ ] **SEC-2** Move Keycloak identity (`config/fredlab-keycloak-identity.json`) provisioning to
      the same governed source; define rotation.
- [x] **SEC-3** (2026-07-13) `bin/fredlab-keycloak-identity.sh` is Kea-legacy only (explicitly
      marked as such in the script and `config/fredlab-keycloak-identity.example.json` -
      see **VALID-7**): it provisions Keycloak groups/app-roles, never a Swift team. There is
      still no Swift-native cloud onboarding path for real GKE users - build one that (a)
      creates Keycloak users only (identity, no groups, no app roles) and (b) calls the real
      control-plane team APIs (`POST /teams`, `POST/DELETE
      /teams/{team_id}/members/{user_id}/roles/{relation}`) using a platform-admin session,
      the same contract `validation/conftest.py::_bootstrap_collaborative_teams` already
      exercises locally. Needs a decision on first-platform-admin bootstrap (who creates the
      first team when the registry is empty) before implementation - do not shortcut this by
      writing OpenFGA tuples directly from a script (bypasses `team_metadata`, exactly the
      anti-pattern **VALID-7** removed from `openfga-post-install.sh`).

      **(2026-07-14) Closed by removal, not replacement.** As part of this session's broader
      "`fred-deployment-factory` = pure infrastructure" cleanup (kea-legacy mode removed
      entirely - see **VALID-11**), `bin/fredlab-keycloak-identity.sh` and
      `config/fredlab-keycloak-identity.example.json` were deleted outright rather than
      rewritten Swift-native. This item's original premise - "replace the kea-legacy-only
      script" - no longer applies once the script itself is gone, so it is marked done. The
      underlying need described above - a Swift-native cloud onboarding path for real GKE
      users - is still real and still unbuilt. It remains a separate, still-open concern the
      developer may want to pick up later; this closure does not solve it, it only records
      that the script this item tracked no longer exists.

## VALID — auth/isolation validation (release gate)

- [x] **VALID-1** Swift clean demo identity matrix (2026-07-10, superseded by **VALID-7**
      on 2026-07-13): `config/configuration.yaml` is the clean Swift seed. `alice` is the
      platform admin, `gabriel` the platform observer, both with zero team membership. The
      old Kea vocabulary is preserved separately in `config/configuration.kea.yaml` for
      `WITH_KEA=true` migration rehearsal. As of VALID-7, Keycloak carries identities only
      (no groups) in `swift-clean`, and OpenFGA carries `platform_admin`/`platform_observer`
      directly from `docker-up`; `team_admin`/`team_editor`/`team_member`/`team_analyst`
      tuples are bootstrapped later via the control-plane APIs, not seeded here.
- [x] **VALID-2** Fixed real drift: `docker/openfga/openfga-model.json` was a
      hand-maintained copy that had diverged from `fred-core`'s actual `schema.fga` (missing
      most organization capabilities, missing `can_read_conversations`). Synced it and added
      `make sync-openfga-model` (manual, not CI) to prevent recurrence.
- [x] **VALID-3** Updated `scenarios/test_content_scope_bypass.py` into a Swift
      content-scope gate: `corpus/capabilities` must require `team_id`, allow members of that
      team, and deny platform-only users or members of other teams. This used to be an xfail
      tripwire for the org-scoped `can_read_content` gap; it is now a blocking validation of
      the fixed team-scoped contract. Needs knowledge-flow-backend reachable
      (`FRED_KNOWLEDGE_FLOW_URL`).
- [x] **VALID-3b** `bin/fred-preflight.sh` is mode-aware: clean Swift validates the
      Swift OpenFGA model (`team_admin`/`team_editor`/`team_analyst`/`team_member`) and accepts
      zero Keycloak app roles for users; `WITH_KEA=true` validates the legacy rehearsal model
      (`member`/`manager`/`owner`) and old app-role seed. Both modes still validate platform
      tuples and the live model shape pushed to OpenFGA. Keycloak groups are validated only
      in `WITH_KEA=true` (superseded by **VALID-7**, 2026-07-13): `swift-clean` requires zero
      Keycloak team groups, no `groups-scope`/groups claim, and does not expect team-role
      OpenFGA tuples to exist before the control-plane bootstrap runs.
- [ ] **VALID-4** Wire `make validate-auth-isolation-localhost` into CI (currently zero
      `.github/workflows` in this repo — this release gate is 100% manual today).
- [x] **VALID-5a** Minimal version shipped: `make validation-report` runs the full suite
      (no `-x`) and `validation/generate_report.py` turns the JUnit XML into a short,
      claims-grouped Markdown report (`validation/report.md`) — results grouped by
      real-world claim (e.g. "Platform-role isolation") rather than by test function
      name, one-line verdict, failure details collapsed. Zero new dependencies (stdlib
      `xml.etree.ElementTree`); grouping comes from a small `.claim_groups.json` sidecar
      written by `conftest.py`'s existing docstring-rewrite hook, not from new test-file
      markup. Deliberately small — no git-tag binding, no signing, no retained-artifact
      policy.
- [ ] **VALID-5b** The fuller tag-bound evidence report still specced in
      `validation/RFC-C3-validation-extensions.md` Extension F (`pytest.xml`,
      `environment.json`, checksums, retention policy, tied to a git tag) — not built;
      VALID-5a is deliberately the smaller first step.
- [x] **VALID-6** Team-role vocabulary fixtures now exist in the clean Swift seed:
      `bob`/`derek` exercise `team_editor`, `sophia`/`marc`/`nadia` exercise `team_admin`,
      and ordinary members exercise `team_member`. `validation-report` now proves the
      hard split: `team_admin` without `team_editor` cannot enroll agents, and `team_editor`
      without `team_admin` cannot administer members. `team_analyst` remains model-ready but
      has no high-signal black-box workflow in this local suite yet.
- [x] **VALID-7** (2026-07-13, #1912/AUTHZ-05) swift-clean vs kea-legacy convergence pass:
      `make sync-openfga-model` now regenerates **both** Swift OpenFGA model copies
      (`docker/openfga/openfga-model.json` and
      `k3d/files/openfga/openfga-model.json`) from `fred-core`'s canonical
      `schema.fga.json`; a new `make check-openfga-model-sync` static guard fails fast on
      drift. `docker/keycloak/keycloak-post-install.sh` and
      `docker/openfga/openfga-post-install.sh` are now `AUTHZ_MODE`-gated so
      `swift-clean` creates zero Keycloak groups, attaches no `groups-scope`, and seeds zero
      team-role OpenFGA tuple from a Keycloak group id (teams are bootstrapped later via the
      control-plane APIs, never from `openfga-post-install`); `kea-legacy`
      (`WITH_KEA=true`) keeps the prior group-based rehearsal behavior unchanged.
      Service-account Keycloak client roles `query-groups`/`view-groups`/`account:view-groups`
      were removed for `agentic`/`knowledge-flow`/`control-plane` in both
      `docker/keycloak/keycloak-post-install.sh` and the GKE `gcp-c1/helm`
      Foundation values (no app calls a Keycloak group-admin API - confirmed against
      `fred`'s source). `bin/fred-preflight.sh` no longer requires a groups claim, a
      `groups-scope` client scope, or Keycloak team groups for `swift-clean`, and no longer
      expects team-role OpenFGA tuples to exist at `docker-up` time (they only exist once
      the validation harness bootstraps them) - the GREEN verdict for `swift-clean` no
      longer depends on any Keycloak group. Left out of this pass, closed by **VALID-9**:
      the k3d `k3d` chart was not yet `AUTHZ_MODE`-aware, and the shared
      `app-realm.json.template` (both Compose and Helm copies) still carried orphaned demo
      groups from an old, unrelated realm export.
- [x] **VALID-8** (2026-07-13, #1912/AUTHZ-06) `validation/scenarios/test_team_registry_authz.py`
      no longer calls the removed `PATCH /teams/{team_id}/members/{user_id}` endpoint; the
      sole-admin self-demotion guard is now proven through the current granular
      `DELETE /teams/{team_id}/members/{user_id}/roles/team_admin`. Added
      `validation/scenarios/test_cumulative_team_roles.py`: an explicit, dedicated proof that
      marc/bob/elena each hold exactly one team role on `fredlab` with only that role's
      capabilities, priya holds all three (`team_admin`+`team_editor`+`team_analyst`) at
      once with their union, and priya can exercise a genuine admin-gated operation
      (add/remove a member) and editor-gated operation (create/delete a prompt) through her
      cumulative grant. `validation/conftest.py::_bootstrap_collaborative_teams` no longer
      treats every `409` on a role grant as success: it re-reads the member's confirmed
      relations and fails loudly if the expected relation isn't actually held.
      `validation/tests/test_factory_config.py` (offline, `make validation-unit-tests`, no
      running stack) locks in `FactoryUser`'s role-resolution logic: a simple role, a
      cumulative role, the `teams[]` -> `team_member` fallback, the admin/editor/analyst
      distinction, and a neutral identity with no role at all.
- [x] **VALID-9** (2026-07-13, #1912/AUTHZ-05/06) Closes the gap **VALID-7** left open, plus
      four correctness fixes found while closing it:
      - `docker/keycloak/app-realm.json.template` and
        `k3d/files/keycloak/app-realm.json.template` (the shared realm-import
        used by **both** authz modes) had **orphaned demo groups from an old, unrelated realm
        export** (`bidgpt`/`kast`/`poltechng`/`thanos`, not `northbridge`/`fredlab`/`swiftpost`)
        baked in, plus `query-groups`/`view-groups` granted directly to the
        `knowledge-flow`/`control-plane` (and, in the Helm copy only, `agentic`) service
        accounts, plus `groups-scope` in the `app` client's default scopes. All removed - the
        import is now genuinely group-free for both modes; kea-legacy's post-install still
        creates its own groups (and attaches groups-scope) at runtime from
        `config/configuration.kea.yaml`, so nothing regresses for the migration rehearsal.
      - `k3d` (k3d) is now `AUTHZ_MODE`-aware end to end: the chart passes
        `AUTHZ_MODE`/`DEMO_IDENTITY_CONFIG_FILE`/`OPENFGA_MODEL_FILE`/`OPENFGA_SEED_FILE` to
        the post-install Jobs based on `.Values.withKea` (mirrors `WITH_KEA` in Docker
        Compose); `keycloak-post-install-k8s.sh` and `openfga-post-install.sh` (k8s copies)
        gained the same swift-clean/kea-legacy branch already in the Compose scripts.
        Also fixed, found while making the k8s Keycloak script mode-aware: 7 functions called
        an undefined `kc` (kcadm) wrapper - only ever defined in the Compose script, where it
        wraps `docker exec`; there is no equivalent inside a k8s Job pod, so this script could
        not have completed a real run before. Converted to the same `kc_http_*` REST calls the
        rest of the file already used.
      - `k3d/files/openfga/openfga-seed.json` (the k3d Swift demo identity - was
        hand-maintained and had drifted: missing elena, and priya missing her AUTHZ-06
        cumulative roles) and a new `openfga-seed.kea.json` / `openfga-model.kea.json` (k3d
        had no Kea-shaped data source at all before this) are now **generated copies** of
        `config/configuration.yaml` / `config/configuration.kea.yaml` /
        `docker/openfga/openfga-model.kea.json` - `make sync-k3d-demo-config`
        regenerates them, `make check-k3d-demo-config-sync` fails fast on drift (mirrors
        `sync-openfga-model`/`check-openfga-model-sync` for the schema itself).
      - `bin/fredlab-keycloak-identity.sh` (manual cloud onboarding, still pre-AUTHZ-05
        Keycloak-groups-as-teams) is now unambiguously marked Kea-legacy-only: a runtime
        banner, a `_notice` field in `config/fredlab-keycloak-identity.example.json`, and
        `gcp-c1/helm/README.md` / `DEPLOYMENT-STEPS.md` no longer present it as (or
        near) the Swift onboarding path. **SEC-3** tracks building the real one.
      - `validation/scenarios/test_cumulative_team_roles.py` and
        `test_team_registry_authz.py`'s mutating fixtures/tests now use try/finally so a
        disposable team, an added member, or a created prompt is cleaned up even when an
        earlier assertion fails, refuse to mutate a persona found in an unexpected
        pre-existing state instead of clobbering it, and check the cleanup call's own result
        instead of firing it blind.
      - `validation/README.md` no longer lists priya as an identity-only control (she is
        AUTHZ-06's cumulative-role persona) and now documents elena explicitly; the earlier
        "byte-identical" claim about the OpenFGA model sync in `docker/README.md` is
        corrected to "normalized-JSON-identical" (`check-openfga-model-sync` compares
        `json.dumps(..., sort_keys=True)`, not raw bytes); `docs/LOCAL-DEVELOPMENT.md` no
        longer claims k3d is unmigrated.
      - New static regression guards, all offline: `validation/tests/test_swift_clean_no_groups.py`
        (realm templates have zero groups/group-membership/default-groups-scope, no service
        account has a group-admin role, both Kea models keep member/manager/owner, neither
        Swift model leaks them) and `make check-k3d-authz-mode-render` (`helm template`
        actually selects `AUTHZ_MODE=swift-clean` + Swift files for `withKea=false` and
        `AUTHZ_MODE=kea-legacy` + Kea files for `withKea=true`).
- [x] **VALID-10** (2026-07-14) `make docker-up WITH_DEMO_USERS=true` (swift-clean only; default
      stays `false`, so the official `make docker-up` empty-realm guarantee is unchanged) now seeds
      `config/configuration.yaml`'s demo Keycloak identities (alice, bob, phil, ...) via the same
      `apply_demo_identity_config`/kcadm mechanism already used for `WITH_KEA=true`, just pointed at
      the populated config instead of `configuration.empty.yaml`. Identity only - no Keycloak groups,
      no app roles, no OpenFGA tuples. Unblocks `validation-report` and manual demo/testing against
      swift-clean without baking demo users into the realm import itself; team/role provisioning for
      these identities is a separate, in-progress control-plane declarative import feature
      (AUTHZ-07 Part 2, `fred` monorepo - see **SEC-3**).

      **(2026-07-14) Superseded and removed the same day.** `WITH_DEMO_USERS` and the
      `apply_demo_identity_config` mechanism it drove have been removed entirely, as part of
      the same session's "`fred-deployment-factory` = pure infrastructure" cleanup that closed
      **SEC-3** and dropped kea-legacy mode (see **VALID-11**). `make docker-up` no longer has
      any demo-identity flag, in either mode. The need this item served is now met by
      `fred`/control-plane-backend's own declarative platform-import feature: `POST
      /import-export/import` reads
      `apps/control-plane-backend/tests/fixtures/import_export/demo_provisioning/`
      (`manifest.json` + `users.json`, in the `fred` monorepo) and, in one call, creates any
      missing Keycloak identity *and* grants every configured team/platform role - see
      `docs/swift/rfc/PLATFORM-IMPORT-RFC.md` §10 in `fred`. `cd apps/control-plane-backend &&
      make build-demo-bundle` packages that fixture for upload via **Admin → Migration**.
- [x] **VALID-11** (2026-07-14, AUTHZ-07 Step 4, issue #1912, PR #1957) Session summary -
      `fred-deployment-factory` → pure infrastructure. This entry ties together the day's
      changes recorded individually above:
      kea-legacy mode (`WITH_KEA`/`AUTHZ_MODE`, the `bin/kea-*.sh` dump/restore scripts,
      `bin/fredlab-keycloak-identity.sh`, `config/configuration.kea.yaml`, the Kea OpenFGA
      model files) removed entirely (closes **SEC-3** by removal - see its note above); the
      demo-identity seeding mechanism added earlier the same session (`WITH_DEMO_USERS`,
      **VALID-10**) removed too, superseded by `fred`'s own declarative platform-import
      feature. `make docker-up` / `make k3d-up` now have exactly one mode and no flags: an
      empty Keycloak realm (self-registration enabled) and an empty OpenFGA store (Swift
      model only) - zero users, zero groups, zero tuples. Every demo identity and role now
      lives in one place, `fred`'s
      `apps/control-plane-backend/tests/fixtures/import_export/demo_provisioning/` fixture,
      imported via `POST /import-export/import`.

      `validation/` (this repo's former auth/isolation release-gate suite) has moved to
      `fred/validation/` as a same-repo sibling of the demo-provisioning fixture it reads -
      run it with `cd ../fred && make validation-report`. This repo's own `validation/`
      directory, its `SWIFT_SRC`-derived `FRED_SDK_SRC`/`FRED_RUNTIME_SRC` plumbing, and the
      `validation-unit-tests` / `validate-auth-isolation-localhost` / `validate-auth-isolation-k3d`
      / `validation-report` Makefile targets are removed; `check-swift-src` /
      `sync-openfga-model` / `check-openfga-model-sync` keep the minimal `FRED_CORE_SRC` path
      they still need. `README.md`, `docker/README.md`, `docs/LOCAL-DEVELOPMENT.md`, and
      `docs/DEPLOY-CLOUD.md` now point at the new location instead of a local path.

      Closing this pass, three more items landed:
      - **Keycloak realm templates genuinely empty.** Both tracked copies
        (`docker/keycloak/app-realm.json.template`, `k3d/files/keycloak/app-realm.json.template`)
        now ship `.users: []` and `.groups: []` - no more demo users (`alice`/`bob`/`phil`) or
        pre-baked service-account role assignments hiding in the source, and no more
        `make keycloak-up`-time `app-realm.empty.json.template` filtering step (`KC_REALM_TEMPLATE`
        removed; Compose mounts the canonical template directly). The legacy `app`-client roles
        `admin`/`editor`/`viewer` are deleted from both templates' `roles.client.app` - only
        `service_agent` remains, and **it is not legacy**: it is the current M2M marker that
        the post-install scripts now grant explicitly to every confidential service account
        (`agentic`, `knowledge-flow`, `control-plane`,
        `fred-evaluation-worker` in Docker) after Keycloak auto-creates its
        `service-account-<clientId>` user from `serviceAccountsEnabled=true`. The k3d
        post-install (`keycloak-post-install-k8s.sh`) previously relied entirely on the
        now-removed pre-baked `.users[].clientRoles` for this - it now resolves and grants
        roles to the three k3d service accounts explicitly, reusing (not duplicating) the
        `wait_for_service_account_username`/`ensure_user_client_role` helpers that already
        existed in the file but were dead code.
      - **Dead OpenFGA seed removed.** `k3d/files/openfga/openfga-seed.json` (a full demo
        identity/team population the current `openfga-post-install.sh` never reads) and its
        `k3d/templates/configmaps.yaml` ConfigMap entry are deleted.
      - **Direct OpenFGA mutator removed.** `bin/fredlab-authz-migrate-swift.py` (a plan/apply
        script that wrote OpenFGA tuples directly from mapped legacy Keycloak roles) is deleted
        outright, not replaced - it was a second provisioning path parallel to the bootstrap +
        declarative-import model this repo now exclusively relies on.
      - **New offline regression guard.** `make check-pure-infrastructure` fails fast (no
        live stack needed) if either realm template regains a user/group, `service_agent`
        disappears or a legacy `app:admin/editor/viewer` role reappears, the k3d chart ships an
        OpenFGA seed again, or the Makefile regains a target pointing at the removed local
        `validation/`.

      **(2026-07-14) Correction: `bin/fred-preflight.sh` still required the removed legacy
      roles.** The pass above emptied the realm templates but missed that
      `bin/fred-preflight.sh` (run by `make docker-up` via `preflight-check`) still declared
      `REQUIRED_APP_CLIENT_ROLES=(admin editor viewer)` and marked their absence critical - a
      from-scratch `docker-up` therefore failed its own preflight. Fixed: the script now
      enforces the actual invariant - `EXPECTED_SERVICE_APP_ROLE="service_agent"` is required,
      and `LEGACY_APP_CLIENT_ROLES=(admin editor viewer)` must be **absent**, flagged critical
      if any reappear. `check-pure-infrastructure` gained a check for this exact regression
      (fails if `REQUIRED_APP_CLIENT_ROLES` reappears, or if the script stops requiring
      `service_agent` / forbidding admin/editor/viewer). Also: the two realm templates were
      reformatted wholesale by the original pass's `jq` rewrite (~10k lines of pure
      whitespace/style churn); they're now edited as targeted text splices against the
      `05dda9e^` original, restoring the prior Keycloak-export formatting and reducing the
      cumulative template diff to the intended semantic change only (verified by normalized-JSON
      projection, see the correction commit).

      **Not covered by this pass (still open):** Step 5 (Helm/GKE/AKS bootstrap-secret
      handling, a bootstrap-marker upgrade strategy, a Swift-native cloud onboarding
      replacement for the removed `bin/fredlab-keycloak-identity.sh` - **SEC-1**/**SEC-2** and
      the onboarding half of **SEC-3**'s note remain open); no live k3d/Docker/GKE run was
      performed to confirm runtime behavior end-to-end, only offline validation (`jq`, `helm
      lint`/`template`, `bash -n`, `check-pure-infrastructure`).

## ENV — multi-environment

- [ ] **ENV-1** Define the multi-env shape (dev/stage/prod): ApplicationSet vs app-of-apps vs
      per-env values folders. The current single `values-fredlab.yaml` overlay is env #1. (RFC Q4)
- [ ] **ENV-2** Parameterize project/region/registry/hostnames so a new environment is a values
      overlay + secret source, not a code edit.

## CHART — convergence & hygiene

- [~] **CHART-1** Canonical chart — **decided: the monorepo `deploy/charts/fred` is the single
      Apps-layer source**; each factory consumes it (pinned) + supplies its Foundation + env
      values. Sequencing: (1) prove one clean, tested chart here first (CHART-2), then (2) promote
      to the monorepo + cut GKE over. Monorepo tracking issue: ThalesGroup/fred#1839. (RFC §7)
- [ ] **CHART-2** De-duplicate templates: the 11 `gcp-c1/argocd/fred-apps/templates/*` app files are
      hand-kept copies of `gcp-c1/helm/templates/*` and **have already drifted once** (the
      `maxSurge` block landed in the ArgoCD copy first; re-synced by hand — and `_helpers.tpl`
      still differs). Extract a shared library/sub-chart so they **cannot** drift. Until then, any
      app-template edit must be applied to **both** copies (see CHART-3 for the guard).
- [ ] **CHART-3** Add a CI check that fails if a fred-apps rendered ConfigMap diverges from the
      infra-rendered one for the same app (guards the copy in CHART-2 until it's removed).

## MIG — schema migrations under GitOps

- [ ] **MIG-1** Decide migration strategy: ArgoCD PreSync hook vs keep imperative
      (`bin/fredlab-deploy.sh <app> migrate`). Document the chosen flow. Currently cp + kf
      migrations are imperative; DBs are at head. (RFC Q5)

## CI — build & promote

- [ ] **CI-1** Move image builds from local `gcloud builds submit` (from `~/fred`) to CI on
      merge; publish the `YYYYMMDD-<sha>` tag and (optionally) auto-bump `values-fredlab.yaml`.
- [ ] **CI-2** Pipeline ordering: build → push → tag-bump PR → review → ArgoCD sync.

## OPS — operability

- [ ] **OPS-1** ArgoCD itself is bootstrapped imperatively with named-email RBAC; document the
      DR/restore path for the ArgoCD control plane.
- [ ] **OPS-2** Backup/restore runbook for Layer A only (Postgres + OpenSearch) — the one thing
      that must be backed up.

## CLASS — classification-driven hardening (C2 / C3)

The repo is a **C1 reference sample** (RFC §6). These are per-level hardening knobs; the
*architecture* does not change — these are level-gated targets, not C1 regressions.

- [ ] **CLASS-1** Secrets source by level — C2: encrypted-in-git (SOPS / sealed-secrets) or a
      cloud secret manager via CI; C3: external **Vault** (HSM-backed), dynamic / short-lived
      credentials, zero human handling. Supersedes the C1 git-ignored file at higher levels.
      (RFC §6; relates to SEC-1)
- [ ] **CLASS-2** Admin/user network separation (C3) — the user network must not be able to reach
      admin surfaces (admin Keycloak, ArgoCD, Temporal UI). NetworkPolicies dropping user→admin,
      admin behind a separate ingress + bastion / admin VPN, possibly separate clusters / node-pools.
- [ ] **CLASS-3** Move admin endpoints off the user-facing ingress — today Keycloak admin, ArgoCD
      and Temporal UI sit on the public edge behind OIDC (+ optional Cloud Armor). Split onto an
      admin-only entrypoint (precursor to CLASS-2).
- [ ] **CLASS-4** Sovereign hosting (C3) — validate the pattern on **S3NS**; prove "next
      environment = re-install" (relates to ENV-1 / ENV-2); document key custody & sovereign ops.
- [ ] **CLASS-5** Per-level profile — express C1/C2/C3 as selectable overlays so a target's
      classification picks its secret source, network policy and admin exposure (ties to ENV-1).
- [ ] **CLASS-6** Image promotion to a C3 registry — model the airlocked chain
      (public → R1 → R2 → R3): who triggers each hop, integrity/signature checks, and how the
      final tag reaches the C3 deployment-factory. Today: manual. (the artifact half of CI-1/CI-2)

## INST — platform instances

Each instance reuses the same pattern (Foundation/Apps split + boundary); only the **cluster**,
the **git host + GitOps mechanism**, and the **three classification knobs** change.

- [ ] **INST-1** C2 instance on **TDP (managed AKS), driven by GitLab** — owner: Simon. Reuse
      the GKE reference: same Foundation/Apps split + boundary, AKS cluster, GitLab git + GitOps
      mechanism, C2 knobs (RFC §6). **Gated:** build on the hardened GKE chart (`CHART-2`) and,
      ideally, the monorepo chart (`CHART-1` / ThalesGroup/fred#1839) — do **not** fork a
      parallel model to stand C2 up first.
      **(2026-07-15, AUTHZ-07)** The GKE reference now wires the root platform-admin
      bootstrap secret (`FRED_BOOTSTRAP_TOKEN` / `secretKeyRef` on the existing Foundation
      Secret's `CONTROL_PLANE_BOOTSTRAP_TOKEN` key — see `gcp-c1/argocd/fred-apps/templates/
      control-plane-backend.yaml`); `fred`'s `deploy/charts/fred` chart owns the same portable
      contract (`fred`'s `deploy/README.md` "Root bootstrap secret contract"). A future AKS/Flux
      overlay for this item reuses that exact contract unchanged — it supplies its own namespace,
      pre-existing Secret name/key, and Foundation endpoints; no new bootstrap mechanism to design.
