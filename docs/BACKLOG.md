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
- [x] A/B boundary enforced in `argocd/fred-apps/Chart.yaml`; apps reference infra by name.
- [x] Config-faithful cutover method (render + byte-diff vs live ConfigMap) — keep using it.
- [x] Frontend edge decoupled via `fredFrontend.ingressEnabled` (Ingress/cert/BackendConfig
      stay in infra; no cert churn on workload moves).
- [x] `/ready` status probe hardened against Autopilot cold-start (`bin/fredlab-status.sh`).
- [x] Rollout strategy `maxSurge: 0 / maxUnavailable: 1` on all fred-apps Deployments (mirrored
      in `helm/fredlab-infra`) — replaces pods in place so a small cluster doesn't need a surge
      node. Without it, four simultaneous surges + a node-autoprovision GCE-quota hit wedge pods
      in `Pending`. See `argocd/README.md` "Small-cluster rollout note".

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

## VALID — auth/isolation validation (release gate)

- [x] **VALID-1** Extend `validation/` with the AUTHZ-05 complete role matrix (2026-07-09):
      5 new demo users (`oscar`, `nina`, `derek`, `priya`, `quinn`) in `configuration.yaml`
      covering platform-admin-without-team, the floor case, legitimate-admin-plus-one-team,
      and the new target `platform_admin`/`platform_observer` relations in isolation.
      New `platform_roles` config field + `openfga-post-install.sh` seeding. New
      `scenarios/test_platform_role_isolation.py`. All 5 users live-verified against the
      running local OpenFGA store via direct `/check` calls before any HTTP-level test was
      written. See `validation/README.md` "The complete-matrix demo users".
- [x] **VALID-2** Fixed real drift: `docker-compose/openfga/openfga-model.json` was a
      hand-maintained copy that had diverged from `fred-core`'s actual `schema.fga` (missing
      most organization capabilities, missing `can_read_conversations`). Synced it and added
      `make sync-openfga-model` (manual, not CI) to prevent recurrence.
- [x] **VALID-3** Added `scenarios/test_content_scope_bypass.py`: a deliberate
      `xfail(strict=True, raises=AssertionError)` tripwire for the known, NOT YET FIXED
      org-scoped `can_read_content`/`can_process_content` gap in knowledge-flow-backend
      (fred's `FRED-AUTHORIZATION-TARGET-MODEL-RFC.md` §25a). Needs knowledge-flow-backend
      reachable (`FRED_KNOWLEDGE_FLOW_URL`, new). Note: without `raises=AssertionError`,
      xfail silently swallows "stack unreachable" as if it were the expected vulnerability —
      found and fixed this during implementation; see the file's docstring.
- [x] **VALID-3b** Fully corrected `bin/fred-preflight.sh` for the new role matrix — not a
      one-off hack for the new users. It previously hardcoded "every demo user must hold a
      legacy Keycloak app role in {admin, editor, viewer}", which is flatly wrong under
      AUTHZ-05 (nina/priya/quinn are deliberately role-less or platform-only) and would have
      hard-failed `make docker-up` for any release using this matrix. Now:
      (1) a user's expected app_roles/platform_roles come from `configuration.yaml`, empty is
      valid when declared, extra/unexpected roles are still flagged;
      (2) the "does the claim mechanism work at all" check moved from per-user to a single
      aggregate assertion (at least one demo user has an effective legacy role);
      (3) new: validates `platform_roles` against real OpenFGA `platform_admin`/
      `platform_observer` tuples, same UUID-critical/username-warning pattern as team roles;
      (4) new: validates the shape of the LIVE authorization model pushed to OpenFGA itself —
      asserts `organization` defines `platform_admin`/`platform_observer` and `team.owner` is
      direct-only (no `admin`-from-`organization` escalation) — a standing regression guard
      against exactly the drift found in VALID-2, not just a one-time fix. All new logic
      verified against both the fixed and the pre-fix model shape (synthetic + live OpenFGA
      `/check` calls) before being considered done.
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
- [ ] **VALID-6** Team-role vocabulary rename (`owner`→`team_manager`, `manager`→`team_editor`,
      +`team_analyst`) has no fixture users yet — no control-plane endpoint assigns/checks
      those relations today, so a demo user for them would be untestable. Add once `fred`'s
      `teams/service.py` rename lands (tracked in `fred`'s `AUTHZ-MIGRATION-BACKLOG.md`).

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
- [ ] **CHART-2** De-duplicate templates: the 11 `argocd/fred-apps/templates/*` app files are
      hand-kept copies of `helm/fredlab-infra/templates/*` and **have already drifted once** (the
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
