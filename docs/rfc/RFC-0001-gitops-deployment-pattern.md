# RFC-0001 — GitOps deployment pattern for the Fred app layer

- **Status:** Adopted (core), Open (hardening) — 2026-06-26
- **Owner:** Dimitri Tombroff
- **Scope:** `fred-deployment-factory` (fredlab playground GKE). Not the `fred` monorepo.
- **Companion docs:** official design deck `fred-website/slides/fred_deployment_pattern.md`;
  actionable follow-ups in `docs/BACKLOG.md` (this repo).

> This RFC records the deployment pattern we now run and the decisions behind it, so the
> team can (a) maintain it, (b) harden it, and (c) reuse it as a corporate template. The
> polished, externally-facing version is the slide deck; this is the engineering source.

---

## 1. Context

Fred is four cooperating apps — **control-plane (cp)**, **knowledge-flow (kf, backend+worker)**,
**fred-agents (fa)**, **frontend (fr)** — on top of a stateful backbone (Postgres, OpenSearch,
Keycloak, OpenFGA, Temporal). The `fred` monorepo ships the app code, the per-app
`Dockerfile-prod`, and a generic reference chart at `deploy/charts/fred/`. This repo
(`fred-deployment-factory`) is the environment operator: it actually runs the images on the
fredlab GKE playground with real DNS, secrets and topology. **Treat what is here as a C1
reference sample on public GKE** — correct as a *pattern*, but not the production target for a
classified deployment; see §6 for what must harden at C2/C3 (sovereign).

## 2. Decision — two layers, two mechanisms

We split the deployment into two layers with **different ownership and change-rate**, plus an
out-of-band secrets layer.

| Layer | Contents | Mechanism | Source of truth | Change-rate |
| --- | --- | --- | --- | --- |
| **A — infra** | Postgres, OpenSearch (stateful); Keycloak, OpenFGA, Temporal; the shared Ingress, ManagedCertificates, BackendConfigs, `fredlab-infra-secrets` | imperative Helm (`gcp-c1/helm`, release `fredlab-infra`), driven by `bin/fredlab-deploy.sh` | the chart + reviewed `--set`/values | rare, deliberate |
| **B — apps** | cp, kf-backend, kf-worker, fa, fr (Deployments, Services, ConfigMaps, fa/kf ServiceAccounts) | **GitOps** — ArgoCD `Application: fred-apps` rendering `gcp-c1/argocd/fred-apps` | **git** (`values-fredlab.yaml` tags) | every release |
| **C — secrets/identity** | `fredlab-secrets.values.yaml`, `config/fredlab-keycloak-identity.json` | injected at deploy; **git-ignored** | external (today: local file) | — |

### Rationale
- **Blast-radius isolation.** Stateful, irreplaceable data (Postgres/OpenSearch) sits only in A.
  The app chart is *forbidden in code* from rendering infra/Ingress/certs/Secret
  (`gcp-c1/argocd/fred-apps/Chart.yaml`). A bad app deploy cannot delete a database.
- **Mechanism matches risk.** Infra is rare + dangerous → imperative + reviewed. Apps are
  frequent → GitOps (audit trail, reconcile, easy rollback).
- **One-way dependency: B → A.** Apps reference infra by **stable name** only (DNS + named
  Secret), e.g. `POSTGRES_HOST=postgres`, `TEMPORAL_ADDRESS=temporal:7233`,
  `OPENFGA_URL=http://openfga:8080`, creds via the `fredlab-infra.secretName` helper.

## 3. The boundary contract (invariants)

1. The `fred-apps` chart **never** creates a Secret, the infra Ingress, ManagedCertificates,
   or any StatefulSet/Service owned by infra.
2. Apps find infra **by name**, not by co-deploying it. Names are a frozen contract.
3. A new secret key / Keycloak client / database is an **infra change** (touch
   `gcp-c1/helm`), never an app change.
4. Bootstrap order is fixed: infra up → identity provisioned → apps synced.

## 4. What was done (2026-06-26 cutover)

All four apps moved from the imperative `fredlab-infra` release to the ArgoCD `fred-apps`
chart, **pinned to the already-running tag `20260625-swift-cdee43b6` (no image change)**.

- Per app: ported templates into `gcp-c1/argocd/fred-apps/templates` (they share the
  `fredlab-infra.*` helpers — a verbatim copy), added a value block to `values.yaml`
  (`enabled: false`) + enable/image pin to `values-fredlab.yaml`.
- **Validation gate:** `helm template` + a **byte-for-byte diff of the rendered
  `configuration.yaml` against the live ConfigMap** before each cutover. All matched.
- Handover per app: `bin/fredlab-deploy.sh <app> disable -fast` → ArgoCD sync (brief blip).
- **Frontend special case:** the studio Ingress host-rule, `fredlab-studio-cert`, and the
  frontend BackendConfig were decoupled from `fredFrontend.enabled` onto a new
  `fredFrontend.ingressEnabled` (default true) so the edge stays in infra while the workload
  moves. Proven via dry-run that the edge resources render byte-identical with the workload
  disabled → no cert churn. Cert stayed `Active` throughout.
- **kf migrations** intentionally excluded from the GitOps slice (live DB at head; alembic job
  stays imperative).

Result: `fred-apps` Application Synced/Healthy; all five workloads `instance=fred-apps`;
platform stable.

## 5. Status

**Adopted / proven:** the A/B split, the boundary contract, the GitOps app layer, the
config-faithful cutover method, the frontend edge decoupling, secrets-out-of-git.

**Open (see `docs/BACKLOG.md`):** multi-environment, secret management (Vault/External
Secrets/SOPS), auto-sync + self-heal, release tooling for all four apps, chart convergence
(reference vs deployment chart), migration (PreSync hook) strategy, template de-duplication.

**Pipeline gap (the honest half-and-half).** Of the two streams that meet at the cluster
(see the deck for the target picture), only the *intent* half — git → controller → cluster —
is GitOps-clean today. The *artifact* half — build, push, and writing the tag into git — is
still operator-run scripts; at C3 the registry is a guarded multi-hop promotion
(public → R1 → R2 → R3). Automation tracked in `CI-1`/`CI-2`, `GITOPS-1`, `CLASS-6`.

## 6. Classification levels — the architecture is fixed, the implementation hardens

> **Read this before treating the repo as production.** What is in this repository is a
> **correct, sane reference pattern sized for a C1 sample platform on public GKE.** The
> *architecture* — Foundation/Apps split, the boundary contract, GitOps — holds unchanged at
> C1, C2 and C3. Only the *implementation of three knobs* tightens with the security
> classification of the target. Do not assume the C1 sample is production-ready for a
> classified deployment.

**The three knobs that scale with classification**

| Knob | C1 — this repo (sample, public GKE) | C2 — restricted | C3 — sovereign (S3NS) |
| --- | --- | --- | --- |
| **Secrets source** | real values in a git-ignored file, fed to Helm → one in-cluster Secret | encrypted-in-git (SOPS / sealed-secrets) or a cloud secret manager, CI-delivered; no raw values on a laptop | external **Vault** (HSM-backed), short-lived / dynamic credentials, no human ever handles a raw secret |
| **Network segmentation** | single namespace; one shared Ingress; admin + user paths co-resident behind OIDC (+ optional Cloud Armor) | NetworkPolicies; admin endpoints on a separate ingress / restricted source ranges | **admin and user planes strongly separated** — the user network cannot route to admin surfaces at all (admin Keycloak, ArgoCD, Temporal UI); separate clusters / node-pools; bastion-only admin access |
| **Hosting / sovereignty** | public GKE (europe-west) | private / restricted cloud | **S3NS sovereign cloud**; sovereign operations & key custody |

**What stays identical across levels:** the two-layer split; "apps reference the Foundation by
name and never create it"; the one-way dependency; GitOps for the app layer; the
config-faithful cutover method. A higher level changes *where secrets come from*, *what can
reach what on the network*, and *where it runs* — never the shape.

**Worked example — C3 admin/user separation.** At C1 the admin Keycloak (realm management) and
the user login endpoint are the same Keycloak behind one ingress. At C3 they must be split so a
user-plane request **cannot even reach** the admin surfaces — a separate admin ingress on an
isolated network, admin Keycloak/ArgoCD/Temporal-UI reachable only from a bastion/admin VPN, and
NetworkPolicies dropping user→admin traffic. The *identity model* (Keycloak = who, OpenFGA =
what) is unchanged; only its *exposure* hardens.

**Guidance for a new DevOps:** read this repo as **the pattern**, not the production target.
Every secret source, every network boundary, and every admin exposure is a knob you tighten for
the target's classification. The `CLASS-*` backlog items track the C2/C3 hardening.

**First concrete C2 target.** A C2 instance on **TDP (Thales Digital Platform / managed AKS)**,
driven by **GitLab** — same Foundation/Apps split and boundary, an AKS cluster, GitLab as the
git host + GitOps mechanism, C2 knobs. Tracked as `INST-1`; it must inherit the hardened GKE
reference (roadmap steps 1–2) rather than fork a parallel model.

## 7. Open questions for the team

1. **Canonical chart — DECIDED.** The monorepo `deploy/charts/fred` is the single Apps-layer
   source; factories consume it (pinned) and supply only Foundation + env values. Sequencing:
   prove one clean, tested chart here first (CHART-2), then promote + cut GKE over. Monorepo
   tracking issue: ThalesGroup/fred#1839. (Backlog: CHART-1)
2. **Secrets backend.** Vault vs External-Secrets-Operator vs SOPS-in-git. (Backlog: SEC-1)
3. **When to enable auto-sync + self-heal + prune** on `fred-apps`. (Backlog: GITOPS-2)
4. **Multi-env shape:** ApplicationSet vs app-of-apps vs per-env folders. (Backlog: ENV-1)
5. **Migrations under GitOps:** ArgoCD PreSync hook vs keep imperative. (Backlog: MIG-1)
