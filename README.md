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

> **New here? Which local setup do you want?**
>
> | You want to… | Go to |
> | --- | --- |
> | Just chat with Fred solo, no auth, no teams | the `fred` monorepo's own `README.md` → "Getting started" (`make run`) — **not this repo** |
> | Real Keycloak/OpenFGA auth, and/or the 3-team demo (`fredlab`/`swiftpost`/`northbridge`) | **you're in the right repo.** `make docker-up` below, then jump straight to `make bootstrap-local` in `fred/apps/control-plane-backend` — it becomes your `platform_admin` account and (with `DEMO=1`) loads the demo bundle in one command. Manual step-by-step: `docs/LOCAL-DEVELOPMENT.md` → "Full bootstrap walkthrough". |
>
> `make bootstrap-local`'s `DEMO=1` path also turns every tool/agent template on for
> the demo teams (CAPAB-01/CTRLP-14 — they ship admin-gated by default). Doing the
> walkthrough by hand instead? Don't stop after the import — that's step 5b.

---

## Documentation

Start with the guide that matches what you're trying to do:

| I want to… | Guide |
| --- | --- |
| 🖥️ Run Fred's services locally, **and bootstrap a working platform** (Docker Compose / k3d) | [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) — fast path: `make bootstrap-local` (see the callout above); manual steps: "Full bootstrap walkthrough" |
| 🧪 Load local test data — demo persona-per-role, or 3000-user/100-team OpenFGA bench | [`local-testing/README.md`](local-testing/README.md) |
| ☁️ Ship the latest Fred to the live cloud instance | [`docs/DEPLOY-CLOUD.md`](docs/DEPLOY-CLOUD.md) |
| 🔁 Operate ArgoCD (bootstrap, boundary, cutover, rollback) | [`gcp-c1/argocd/README.md`](gcp-c1/argocd/README.md) |
| 🧱 Deploy / understand the GKE Foundation (infra) | [`gcp-c1/helm/README.md`](gcp-c1/helm/README.md) · [`DEPLOYMENT-STEPS.md`](gcp-c1/helm/DEPLOYMENT-STEPS.md) |
| 🔐 Run the auth / team-isolation validation (release gate) | now lives in the [`fred`](https://github.com/ThalesGroup/fred) monorepo's own `validation/README.md` — no longer part of this repo |
| 🐳 Docker Compose internals (network, `.env`, per-service) | [`docker/README.md`](docker/README.md) |

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
