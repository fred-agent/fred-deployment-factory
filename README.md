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

## Quick start: Fred and its applications on k3d

The whole platform in a local Kubernetes cluster: the infrastructure, Fred (its official
Helm chart, with the same posture as production), the evaluation application, and the
logs, events and metrics to find what goes wrong.

**Once:** Docker, [`k3d`](https://k3d.io), `kubectl`, `helm` (3 or 4); a `fred` checkout
where you ran `make setup-env` (it asks for your model API key); and, for the browser:

```bash
grep -qw keycloak /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

**Then, from this repository:**

```bash
make k3d-up                                                # the infrastructure and the observability
make k3d-fred FRED_DIR=../fred                             # build and deploy Fred; rerun after any change
make k3d-evaluator EVALUATOR_DIR=../fred-agent-evaluator   # optional: the evaluation application
make k3d-health                                            # what needs attention, on one screen
```

`make k3d-fred` ends by printing a **bootstrap token**. Open <http://localhost:8088>, create
your account with **Register** on the login page, and paste the token where Fred asks for
it: you are the platform's `platform_admin` (once per platform). Then, in **Admin >
Features**, turn on the capabilities, the models and the `evaluation` application.

| URL | What | Login |
| --- | --- | --- |
| <http://localhost:8088> | Fred, and its applications (`/apps/evaluation/`) | your account |
| <http://localhost:8233> | Temporal UI: ingestions, evaluation runs | — |
| <http://localhost:3002> | Grafana: folder **Fred** | `admin` / `Azerty123_` |
| <http://localhost:9090> | Prometheus: the apps' KPIs | — |
| <http://localhost:5601> | OpenSearch Dashboards: Discover on `k3d-logs*` (every pod's output), `k3d-events*` (Kubernetes events) | `admin` / `FredOpensearch123!!` |
| <http://keycloak:8080> | Keycloak | `admin` / `Azerty123_` (realm `master`) |

**Something wrong?** `make k3d-health` first: restarted containers and why (OOMKilled...),
Kubernetes warnings, errors and HTTP 5xx per service, features a service switched off at
startup, Prometheus targets down, workflows running. Then `bin/k3d-observe trace <id>`
(a run, a workflow, a document), `bin/k3d-observe logs '<query>'`, `bin/k3d-observe kpi`.
The `k3d-observability` skill (`.claude/skills/`) describes the method.

**Every command is safe to rerun: they converge.** To stop: `make k3d-down` (the cluster
sleeps, data kept). To start over: `make k3d-wipe` — **it deletes every volume: all
accounts, documents and runs.** All the details: [`docs/LOCAL-DEVELOPMENT.md` → "k3d: the
full stack in Kubernetes"](docs/LOCAL-DEVELOPMENT.md#k3d-the-full-stack-in-kubernetes).

---

> **New here? Which local setup do you want?**
>
> | You want to… | Go to |
> | --- | --- |
> | Just chat with Fred solo, no auth, no teams | the `fred` monorepo's own `README.md` → "Getting started" (`make run`) — **not this repo** |
> | Real Keycloak/OpenFGA auth, and/or the 3-team demo (`fredlab`/`swiftpost`/`northbridge`) | **you're in the right repo.** `make docker-up` below, then in `fred`: `make setup-env` (once) → `make run` → `cd apps/control-plane-backend && make bootstrap-local BOOTSTRAP_USER=<you>`. Manual step-by-step: `docs/LOCAL-DEVELOPMENT.md` → "Full bootstrap walkthrough". |
> | A representative Kubernetes setup (Fred's production Helm chart, room to deploy plugins next to Fred) | **you're in the right repo:** "Quick start: Fred and its applications on k3d" above. |
>
> `bootstrap-local` gets you `platform_admin` — the one step with no UI
> shortcut. Before importing the demo bundle, populate its 15 named users in
> Keycloak — one command, **from this repo**:
> `local-testing/demo/seed-keycloak-users.sh` (the import assigns their
> teams/roles; it doesn't create the identities — same "Fred never creates
> accounts in Keycloak" rule as `bootstrap-local` itself). Then log into the
> frontend and use **Admin > Migration** to import the bundle, **Admin >
> Capabilities** to turn every tool/agent template on (they ship admin-gated
> by default — CAPAB-01/CTRLP-14). Doing the walkthrough by hand instead of
> the UI? Don't stop after the import — that's step 5b.

---

## Documentation

Start with the guide that matches what you're trying to do:

| I want to… | Guide |
| --- | --- |
| 🖥️ Run Fred's services locally, **and bootstrap a working platform** (Docker Compose) | [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) — fast path: `make setup-env` + `make run` + `make bootstrap-local` (see the callout above); manual steps: "Full bootstrap walkthrough" |
| ☸️ Run the whole stack in a local Kubernetes cluster (k3d) | [`docs/LOCAL-DEVELOPMENT.md` → "k3d: the full stack in Kubernetes"](docs/LOCAL-DEVELOPMENT.md#k3d-the-full-stack-in-kubernetes) |
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

**Related links:** Fred website <https://site.fredlab.dev> · Fred repository
<https://github.com/ThalesGroup/fred>
