# CLAUDE.md — fred-deployment-factory

Audience: AI coding assistants (and the engineer driving them). Read this first, then the
README's "Quick start" and `docs/LOCAL-DEVELOPMENT.md`.

## What this repo is

The **local deployment** of Fred and its applications, in two forms:

- **Docker Compose** — the backing services on the host (`make docker-up`); the Fred apps run
  from a `fred` checkout (`make run` there). It is the fast loop to debug an app, not a
  second deployment: k3d is the one that deploys as production does.
- **k3d** — everything in a local Kubernetes cluster: the infrastructure (`make k3d-up`, chart
  `k3d/`), then each application: Fred's open-source ones defined here, from their published
  releases (`make k3d-app APP=fred`, `APP=fred-evaluator`) or a checkout (`DIR=../fred`), the
  others from their own repository (`make k3d-app DIR=../dt-agents`), with logs, events and
  metrics collected (`make k3d-health`).

The GKE/GCP (fredlab) deployment left this repository on 2026-09-30; an archive clone is kept
outside it. Do not reintroduce cloud-specific material here.

## The model

- **This instance owns its values; products own their charts and images.** Fred's open-source
  applications (Fred, the evaluation application) are defined here, in `k3d-apps/<APP>/`:
  helmfile (the published OCI chart, its version pinned and bumped by Renovate, `renovate.json`), k3d
  values, identities, `prepare` and `finish`. Their repositories keep only `deploy/k3d/build`,
  for `DIR`. Other applications (proprietary ones included) keep their whole definition in
  their own `deploy/k3d/`. Both follow one contract (`docs/LOCAL-DEVELOPMENT.md` → "The k3d
  application contract"). This repository never copies a chart, and the engine
  (`bin/k3d-app.sh`) names no application.
- **The platform contract is what applications may rely on:** the namespace, the service
  names and the keys of `fred-secrets`. Changing one breaks applications in other repositories.
- **An application's k3d values say only what the instance decides.** Every block is labelled
  `address`, `secret`, `posture`, `choice`, `models` or `sizing`; everything else is the
  chart's default. A `choice` is a candidate to become a chart default, in the chart's repo.
- **Credentials as in production.** What the instance generates (database, Keycloak client and
  infrastructure passwords, the bootstrap token) lives in one Foundation Secret, `fred-secrets`
  (created by `make k3d-up`, `k3d/templates/secret.yaml`). What the operator supplies (the model
  key, the web research key) lives in Secrets the operator creates before deploying
  (`fred-model-credentials`, `fred-web-research-credentials`), never written by a hook. The
  apps read each one by `secretKeyRef`. Never a literal value in a values file, never a
  credential taken from the environment or a checkout.
- **Applications register with Fred, each with its own entry only**: its `registration.yaml`,
  a Fred values file holding only `registrations` (an application's catalog entry and
  gateway, a Knowledge Base's publisher, keyed by id), stored by `make k3d-app` in a
  ConfigMap `fred-registration-<name>`. Fred's
  `k3d-apps/fred/registrations.yaml.gotmpl` builds the three lists from all of them; a changed
  registration redeploys Fred, as last deployed, before the application syncs. No values
  file names another application's entry, and none is passed in `VALUES` to register.
- **Identities: k3d takes them from the applications, Docker keeps its own.** On k3d, the
  platform's identities (realm `app`, the `app` client and its roles, Fred's backend
  clients for now) are in `k3d/files/scripts/keycloak-post-install-k8s.sh`; an application's
  service clients are declared in its `identities.yaml` and applied by
  `bin/k3d-identities` (which refuses platform clients and realm-admin roles). Never add an
  application's client to the post-install script. Docker Compose is the fast debug loop:
  `docker/keycloak/keycloak-post-install.sh` creates fixed identities for the apps run from
  their checkouts, with local default secrets, and need not follow k3d.

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
