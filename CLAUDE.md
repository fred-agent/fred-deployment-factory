# CLAUDE.md — fred-deployment-factory

Audience: AI coding assistants (and the engineer driving them). **Read this first, then
`docs/rfc/RFC-0001`.** This file tells you what the repo is, the deployment model, and — most
importantly — **the order the work must happen in.**

## What this repo is

The **deployment operator** for Fred. The product (the four apps + their container images)
lives in the `fred` monorepo (https://github.com/ThalesGroup/fred). This repo says **where and
how** a concrete instance runs. It has two facets:

- **Local** — a docker-compose / k3d developer stack (see `README.md`, `make docker-up`).
- **Cloud (the reference)** — a live **C1 instance on GKE/GCP**, GitOps-managed by ArgoCD.
  This is the part the deployment *pattern* is about (`helm/`, `argocd/`, `bin/fredlab-*.sh`).

The same repo + pattern is meant to be reused **per instance, per classification, per
platform** — e.g. a future **C2 instance on TDP (Thales Digital Platform / managed AKS),
driven by GitLab**.

## Start here (canonical docs)

| Doc | What |
| --- | --- |
| `docs/rfc/RFC-0001-gitops-deployment-pattern.md` | the deployment pattern + every decision (Foundation/Apps split, the boundary, the classification model §6, the pipeline gap) |
| `docs/BACKLOG.md` | the work, by theme — **the current direction lives here** |
| `gcp-c1/argocd/README.md` | the GitOps app-layer ops (cutover procedure, sync) |

The polished *vision* of the pattern is a slide deck in the `fred-website` repo
(`slides/fred_deployment_pattern.md`). These docs stay **decisions + gaps** only — don't
re-narrate the vision here.

## The model in one paragraph

Two layers. A **Foundation** — the stateful backbone (Postgres, OpenSearch, Keycloak, OpenFGA,
Temporal, plus the shared ingress / TLS certs / the one Secret) — changed rarely and
**imperatively** (reviewed `helm upgrade` via `bin/fredlab-deploy.sh`). And an **Apps** layer —
the four stateless apps (control-plane, fred-agents, frontend, knowledge-flow backend+worker) —
managed by a **GitOps controller** (ArgoCD here) that reconciles the cluster to git. Apps
reference the Foundation **by name** and never create it. The architecture is identical at every
classification and on every platform; only **three knobs harden by level** — secrets source,
network segmentation, admin exposure (RFC §6).

## The roadmap — DO THIS IN ORDER (do not skip ahead)

1. **Make the GKE / C1 model rock-solid and simple FIRST.** Consolidate into one clean, tested
   Apps-layer chart, de-duplicating `gcp-c1/argocd/fred-apps` ↔ `gcp-c1/helm` (backlog
   `CHART-2`). This is the shared reference everything else inherits.
2. **THEN promote it to the monorepo.** Make `fred`'s `deploy/charts/fred` the single
   Apps-layer source; this repo consumes it pinned (tracking issue **ThalesGroup/fred#1839**,
   backlog `CHART-1`).
3. **THEN replicate per platform.** A new instance (e.g. **C2 on TDP/AKS via GitLab**, backlog
   `INST-1`) reuses the *same* Foundation/Apps split and boundary. What changes per instance:
   the **cluster** (AKS vs GKE), the **git host + GitOps mechanism** (GitLab vs GitHub+ArgoCD),
   and the **three knobs** for the target classification.

> **For a new platform (e.g. Simon's C2/TDP): do NOT fork a parallel model to stand up C2
> first.** Contribute to hardening the GKE reference (step 1), so the C2 instance inherits a
> proven, simple model instead of re-inventing one. Same pattern, different platform — that is
> the whole point.

## Working rules

- **Platform mutations go through `bin/fredlab-*.sh` scripts**, one safe step at a time — never
  ad-hoc `kubectl` / `helm` / `argocd`.
- **Never break the boundary:** the Apps chart must not create the Secret, the Ingress, the
  ManagedCertificates, or any Foundation service. It references them **by name**.
- **Prove before you cut over:** `helm template` + diff the rendered config **byte-for-byte**
  against the live ConfigMap. An ownership move must change *nothing* in behaviour.
- **Secrets never enter git** — only `*.example.yaml` templates are tracked. Real values are
  injected at deploy; at higher classifications they come from a vault/CI (RFC §6).
- **Keep docs lean.** Record decisions in the RFC and work in the BACKLOG; the deck carries the
  vision. Don't add prose that duplicates either.
