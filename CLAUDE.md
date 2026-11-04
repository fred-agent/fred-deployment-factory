# CLAUDE.md — fred-deployment-factory

Audience: AI coding assistants (and the engineer driving them). Read this first, then the
README's separate infrastructure and application commands and `docs/LOCAL-DEVELOPMENT.md`.

## What this repo is

The **local deployment** of Fred and its applications, in two forms:

- **Docker Compose (legacy Swift loop)** — the backing services on the host (`make docker-up`); the Fred apps run
  from a `fred` checkout (`make run` there). It is the fast loop to debug an app, not a
  second deployment: k3d is the one that deploys as production does.
- **k3d** — COTS preparation through `make k3d-up` (Swift and Weaver side by side), or
  `make k3d-up-swift` / `make k3d-up-weaver` for one; explicit application deployment through
  `make k3d-app APP=fred DIR=/path/to/checkout`. Never couple the two steps.
  The factory reuses its infrastructure chart and generic application engine;
  product repositories own their charts, image builds and application hooks.
  Satellite definitions use the same explicit application engine. Diagnostics use `make k3d-health`.

The GKE/GCP (fredlab) deployment left this repository on 2026-09-30; an archive clone is kept
outside it. Do not reintroduce cloud-specific material here.

## The model

- **This instance owns its values; products own their charts and images.** Fred's open-source
  applications (Fred, the evaluation application) are defined here, in `k3d-apps/<APP>/`:
  helmfile (the published OCI chart, its version pinned and bumped by Renovate, `renovate.json`), k3d
  values, identities, `prepare` and `finish`. Swift checkouts keep `deploy/k3d/build`
  for `DIR`. Weaver owns its full `deploy/k3d/` profile; its Helmfile/hooks take precedence when supplied through `DIR`.
  Other applications (proprietary ones included) keep their whole definition in
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
  (created by the infrastructure reconciler, `k3d/templates/secret.yaml`). What the operator supplies (the model
  key, the web research key) lives in Secrets the operator creates before deploying
  (`fred-model-credentials`, `fred-web-research-credentials`), never written by a hook. The
  apps read each one by `secretKeyRef`. Never a literal value in a values file, never a
  credential taken from the environment or a checkout.
- **Applications register with Fred, each with its own entry only**: its `registration.yaml`,
  a Fred values file holding only `registrations` (an application's catalog entry and
  gateway, a Knowledge Base's publisher, keyed by id), stored by the internal application engine in a
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

- **Validate from scratch before calling it done:** `make k3d-wipe`, then `make k3d-up` (or a solo variant), then `make k3d-health`. A rerun on an existing cluster proves convergence, not
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
- **Keep docs lean:** the README owns infrastructure and application commands;
  `docs/LOCAL-DEVELOPMENT.md` is the technical/legacy reference. The explicitly
  separate `docs/SWIFT-WEAVER.md` explains coexistence and data boundaries.
  Link to the README instead of duplicating its installation instructions.
- **Commits:** `type(scope): what changed` (e.g. `fix(k3d): ...`), one logical change each, no
  Claude co-author line.

## Single local command surface

`k3d-up`, `k3d-up-swift` and `k3d-up-weaver` prepare COTS only,
including the required namespace/database boundaries. They must succeed without
application source paths or model keys and must never build or deploy applications.
Use `make k3d-app APP=fred DIR=...` (or RELEASE for a published version) for the
separate application step. Preserve APP/DIR/RELEASE/VALUES and library inputs on
application commands. Do not reintroduce ENV/INSTANCE/MODE/PROFILE. Placement and
URLs follow the selected checkout; no local-checkouts.json is required. Validation
is separate too: k3d-validate* for COTS, k3d-app-validate for an application.
Wipe is always separate and explicitly destructive.

If the user asks for preparation only, do not run installation, wipe, build or test
commands; report that execution remains with the user. That instruction takes
precedence over the from-scratch validation rule above.
