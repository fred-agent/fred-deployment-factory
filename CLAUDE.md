# CLAUDE.md — fred-deployment-factory

Audience: AI coding assistants (and the engineer driving them). Read this first, then the
README's separate infrastructure and application commands and `docs/LOCAL-DEVELOPMENT.md`.

## What this repo is

The **local deployment** of Fred and its applications, in two forms:

- **Docker Compose (Weaver only)** — the backing services on the host (`make docker-up`); the
  Fred Weaver apps run from a checkout (`make docker-app FRED=weaver APP=fred DIR=...`, the
  same vocabulary as `k3d-app`), each with its `configuration_prod.yaml` pointing to these
  services. k3d and Docker share one first start (Fred's `deploy/k3d/README.md`), one issuer
  (`http://keycloak:8080/realms/app`) and the same values; only step 1 differs. Keep it so. It is the fast loop to debug
  an app, not a second deployment: k3d is the one that deploys as production does. Docker
  prepares what the k3d line `weaver` gets (database `fred_weaver`, Temporal namespace
  `fred-weaver`, documents bucket, Keycloak clients) with administrator accounts for
  OpenSearch and S3. Swift on Docker Compose stays on branch `swift`.
- **k3d** — a standard Helm deployment: `k3d/cluster.yaml`, the infrastructure chart `k3d/`
  and Helmfile. `make k3d-up` prepares COTS and every Fred release line (Swift, Weaver);
  `make k3d-app FRED=swift|weaver APP=fred DIR=/path/to/checkout` deploys one application,
  separately. Never couple the two steps. Diagnostics use `make k3d-health`.

The GKE/GCP (fredlab) deployment left this repository on 2026-09-30; an archive clone is kept
outside it. Do not reintroduce cloud-specific material here.

## The model

- **Standard tools, no custom procedure.** This repository illustrates a standard
  cloud-native deployment of Fred: a k3d config file, charts, plain values files, Helmfile,
  and Jobs for what a chart must do at install. Do not add a coordinator, an application
  lifecycle hook engine, or Python to the deployment path. Provisioning a backing service
  is data in `k3d/values.yaml`, applied by the infrastructure chart.
- **This instance owns its values; products own their charts and images.** Fred's
  applications are defined here, in `k3d-apps/<APP>/`: a helmfile (the published OCI chart, its
  version pinned and bumped by Renovate, `renovate.json`, or `DIR`'s chart) and plain values.
  Checkouts keep only `deploy/k3d/build`. Other applications (proprietary ones included)
  keep their helmfile in their own `deploy/k3d/`. This repository never copies a chart.
- **`FRED` names the Fred release line, a Helmfile environment, and decides placement.**
  The lines are under `lines` in `k3d/values.yaml`. A line's namespace is `fred-<line>`, its
  database `fred_<line>`, its Temporal namespace `fred-<line>`, its host `<line>.localhost`; the
  infrastructure is `fred-infra`. Values files are per line and plain. A checkout, branch or
  path never selects a line; a checkout is only verified against `FRED`.
- **The platform contract is what applications may rely on:** the namespace of their line, the
  service names and the keys of `fred-secrets`. Changing one breaks applications in other repositories.
- **An application's k3d values say only what the instance decides.** Every block is labelled
  `address`, `secret`, `posture`, `choice`, `models` or `sizing`; everything else is the
  chart's default. A `choice` is a candidate to become a chart default, in the chart's repo.
- **Credentials as in production: applications read them by `secretKeyRef`.** The infrastructure
  chart creates one `fred-secrets` per line (`k3d/templates/lines.yaml`) from local defaults in
  `k3d/values.yaml`, and generates each line's bootstrap token once. What the operator supplies
  (the model key, the web research key) lives in Secrets the operator creates before deploying
  (`fred-model-credentials`, `fred-web-research-credentials`). Never a literal credential in an
  application's values file, never one taken from the environment or a checkout.
- **Registrations are Fred's values:** the chart's `registrations`, in
  `k3d-apps/fred/values-<line>.yaml` or a `VALUES` file.
- **Identities: k3d declares them, Docker keeps its own.** On k3d, the platform's identities
  are in `k3d/files/scripts/keycloak-post-install-k8s.sh`; the service clients of applications
  are `keycloak.serviceClients` in `k3d/values.yaml`. Docker Compose is the fast debug loop:
  `docker/keycloak/keycloak-post-install.sh` creates fixed identities with local default
  secrets, and need not follow k3d.

## Working rules

- **Validate from scratch before calling it done:** `make k3d-wipe`, then `make k3d-up`, then
  `make k3d-health`. A rerun on an existing cluster proves convergence, not installation.
- **`make k3d-wipe` deletes every volume** (accounts, documents, runs). Never run it, or
  anything that uninstalls the `fred-stack` release, without the developer's explicit go.
- **Find problems with the collected evidence**, not by grepping pod consoles: `make k3d-health`,
  `bin/k3d-observe` and the `k3d-observability` skill.
- **Render before deploying:** `helm lint` and `helm template` with the instance values; the
  fred chart validates its values against a strict schema.
- **Secrets never enter git.** Local defaults (`Azerty123_`...) are for this local stack only.
- **Keep docs lean:** the README is recipes only: you want this, run that, with no
  explanation. `docs/HOW-IT-WORKS.md` explains them, `docs/SWIFT-WEAVER.md` explains
  coexistence and data boundaries, and `docs/LOCAL-DEVELOPMENT.md` is the technical/legacy
  reference. Link to the README instead of duplicating its installation instructions.
- **Commits:** `type(scope): what changed` (e.g. `fix(k3d): ...`), one logical change each, no
  Claude co-author line.

## Single local command surface

`k3d-up` prepares COTS and every line only. It must succeed without application source paths
or model keys and must never build or deploy applications. Use
`make k3d-app FRED=swift|weaver APP=fred DIR=...` (or RELEASE for a published version) for the
separate application step. `FRED` is required there, typed on the command line, and the only
selector: do not reintroduce ENV/INSTANCE/MODE/PROFILE, a default line, or placement inferred
from a checkout. Preserve APP/DIR/RELEASE/VALUES on application commands. Validation is
separate too: k3d-validate for COTS, k3d-app-validate for an application.
Wipe is always separate and explicitly destructive.

If the user asks for preparation only, do not run installation, wipe, build or test
commands; report that execution remains with the user. That instruction takes
precedence over the from-scratch validation rule above.
