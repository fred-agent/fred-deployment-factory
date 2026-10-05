# CLAUDE.md — fred-deployment-factory

Audience: AI coding assistants (and the engineer driving them). Read this first, then the
README's "Quick start" and `docs/LOCAL-DEVELOPMENT.md`.

## What this repo is

The **local deployment** of Fred and its applications, in two forms:

- **Docker Compose** — the backing services on the host (`make docker-up`); the Fred apps run
  from a `fred` checkout (`make run` there).
- **k3d** — everything in a local Kubernetes cluster: the infrastructure (`make k3d-up`, chart
  `k3d/`), Fred (`make k3d-app`) and the evaluation application (`make k3d-evaluator`), with
  logs, events and metrics collected (`make k3d-health`).

The GKE/GCP (fredlab) deployment left this repository on 2026-09-30; an archive clone is kept
outside it. Do not reintroduce cloud-specific material here.

## The model

- **Charts stay with their product.** Fred's chart is `fred/deploy/charts/fred`, the evaluation
  application's is `fred-agent-evaluator/deploy/charts/fred-evaluator`. This repository never
  copies a chart: it holds each k3d instance's **values** (`k3d-apps/<app>/values.yaml`) and
  the infrastructure chart (`k3d/`).
- **An instance's values say only what the instance decides.** Every block is labelled
  `address`, `secret`, `posture`, `choice`, `models` or `sizing`; everything else is the
  chart's default. A `choice` is a candidate to become a chart default, in the chart's repo.
- **One Foundation Secret.** Every credential lives in `fred-secrets` (created by `make k3d-up`,
  `k3d/templates/secret.yaml`); the apps read each one by `secretKeyRef`. Never a literal value
  in a values file.
- **Applications register with Fred like any application**: `application_sources` in the
  control-plane values and the frontend gateway's `FRONTEND_APPLICATIONS_JSON`, both in
  `k3d-apps/fred/values.yaml`. No ad hoc wiring.
- **Docker and k3d provision the same identities.** A Keycloak client or role added to
  `docker/keycloak/keycloak-post-install.sh` goes into
  `k3d/files/scripts/keycloak-post-install-k8s.sh` too, and the reverse.

## Working rules

- **Validate from scratch before calling it done:** `make k3d-wipe && make k3d-up`, then the
  apps, then `make k3d-health`. A rerun on an existing cluster proves convergence, not
  installation.
- **`make k3d-wipe` deletes every volume** (accounts, documents, runs). Never run it, or
  anything that uninstalls the `fred-stack` release, without the developer's explicit go.
- **Release recovery goes through `bin/k3d-helm-recover.sh`**, the one implementation. It reads
  Helm's JSON (never its table: the date spans several columns) and refuses to uninstall a
  release that owns a PersistentVolumeClaim.
- **Find problems with the collected evidence**, not by grepping pod consoles: `make k3d-health`,
  `bin/k3d-observe` and the `k3d-observability` skill.
- **Render before deploying:** `helm lint` and `helm template` with the instance values; the
  fred chart validates its values against a strict schema.
- **Secrets never enter git.** Local defaults (`Azerty123_`...) are for this local stack only.
- **Keep docs lean** and in two places: the README's quick start, and
  `docs/LOCAL-DEVELOPMENT.md` for the details.
- **Commits:** `type(scope): what changed` (e.g. `fix(k3d): ...`), one logical change each, no
  Claude co-author line.
