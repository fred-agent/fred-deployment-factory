# Fred Deployment Factory

The **deployment operator** for [Fred](https://github.com/ThalesGroup/fred). Fred itself —
the apps and their container images — lives in the `fred` monorepo. **This** repo answers a
different question: *where and how does a concrete Fred instance actually run?*

It does that in two ways:

- **Locally** — bring up Fred's backing services (Keycloak, Postgres, OpenFGA, OpenSearch,
  Temporal, …) on your laptop with one `make` command, for development and testing.
- **In the cloud** — a live **GKE/GCP** instance, GitOps-managed by **ArgoCD**, that you ship
  the latest Fred to with a short, scripted, reviewable loop.

The design is deliberately simple: a **Foundation** layer (the stateful backbone — Postgres,
Keycloak, OpenFGA, OpenSearch, Temporal) that changes rarely, and an **Apps** layer (the four
stateless Fred apps) that you redeploy often. The same shape is meant to be reused per
instance, per classification, and per platform.

> **Default branch: `swift`.** It matches `ThalesGroup/fred` and is the branch ArgoCD deploys
> from (`targetRevision: swift`), so "the default branch" and "what's running in the cluster"
> stay the same thing by construction. (`kea` was the previous release line.)

---

## Documentation

Start with the guide that matches what you're trying to do:

| I want to… | Guide |
| --- | --- |
| 🖥️ Run Fred's services locally (Docker Compose / k3d) | [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) |
| ☁️ Ship the latest Fred to the live cloud instance | [`docs/DEPLOY-CLOUD.md`](docs/DEPLOY-CLOUD.md) |
| 🔁 Operate ArgoCD (bootstrap, boundary, cutover, rollback) | [`argocd/README.md`](argocd/README.md) |
| 🧱 Deploy / understand the GKE Foundation (infra) | [`helm/fredlab-infra/README.md`](helm/fredlab-infra/README.md) · [`DEPLOYMENT-STEPS.md`](helm/fredlab-infra/DEPLOYMENT-STEPS.md) |
| 🔐 Run the auth / team-isolation validation (release gate) | [`validation/README.md`](validation/README.md) |
| 🐳 Docker Compose internals (network, `.env`, per-service) | [`docker-compose/README.md`](docker-compose/README.md) |

---

## Deeper references

The *why* and the *open work* — not the day-to-day how-to:

| Doc | What |
| --- | --- |
| [`docs/rfc/RFC-0001-gitops-deployment-pattern.md`](docs/rfc/RFC-0001-gitops-deployment-pattern.md) | the deployment pattern + every decision (Foundation/Apps split, the boundary, the classification model) |
| [`docs/BACKLOG.md`](docs/BACKLOG.md) | open work — a new instance (e.g. C2 on TDP/AKS) is tracked here |
| [`CLAUDE.md`](CLAUDE.md) | what the repo is + the order work must happen in (for contributors / AI assistants) |

**Related links:** Fred website <https://fredk8.dev> · Fred repository
<https://github.com/ThalesGroup/fred>
