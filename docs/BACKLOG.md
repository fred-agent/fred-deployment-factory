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

- [x] **VALID-1** Swift clean demo identity matrix (2026-07-10):
      `config/configuration.yaml` is now the clean Swift seed: Keycloak carries identities
      and groups, while OpenFGA carries `platform_admin`/`platform_observer` and
      `team_admin`/`team_editor`/`team_member` tuples. `alice` is the platform admin,
      `gabriel` the platform observer, both with zero team membership. The old Kea
      vocabulary is preserved separately in `config/configuration.kea.yaml` for
      `WITH_KEA=true` migration rehearsal.
- [x] **VALID-2** Fixed real drift: `docker-compose/openfga/openfga-model.json` was a
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
      tuples, Keycloak groups, and the live model shape pushed to OpenFGA.
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
