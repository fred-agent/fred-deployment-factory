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

---

## GITOPS — trust the loop

- [ ] **GITOPS-1** Extend `bin/fredlab-release.sh` to all four apps (currently `control-plane`
      only). Component map + reuse the `# release-tag:` markers already in `values-fredlab.yaml`.
      *Unblocks push-to-deploy for fa/kf/fr; needed for the next image bump.*
- [ ] **GITOPS-2** Enable `automated: { selfHeal, prune }` on the `fred-apps` Application once
      the loop is trusted. Decide prune safety per resource. (RFC Q3)
- [ ] **GITOPS-3** Document/script the sync trigger (no `argocd` CLI installed today; we sync
      via `kubectl patch app ... operation`). Add a `bin/fredlab-argocd-sync.sh` helper.

## SEC — secrets & identity

- [ ] **SEC-1** Replace the local git-ignored `fredlab-secrets.values.yaml` with a real backend:
      evaluate External-Secrets-Operator / Vault / SOPS-in-git. Pick one. (RFC Q2)
- [ ] **SEC-2** Move Keycloak identity (`config/fredlab-keycloak-identity.json`) provisioning to
      the same governed source; define rotation.

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
- [ ] **CHART-2** De-duplicate templates: `argocd/fred-apps/templates/*` are byte-identical
      copies of `helm/fredlab-infra/templates/*`. Extract a shared library/sub-chart so they
      cannot drift apart.
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
