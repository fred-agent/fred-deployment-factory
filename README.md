# Fred Deployment Factory

Deploy Fred locally. **Start with Weaver alone on one k3d cluster** using the
walkthrough below. The factory owns the infrastructure and deployment commands;
the Fred checkout owns Weaver's chart, configuration and image build.

| Your task | Start here |
| --- | --- |
| Develop or try Weaver | [Weaver quick start](#quick-start-weaver-on-k3d) |
| Install Swift alone, or Swift + Weaver to rehearse migration | [Swift → Weaver migration lab](docs/SWIFT-WEAVER-MIGRATION.md) |
| Understand configuration, hooks, diagnostics or the optional second cluster | [Local development reference](docs/LOCAL-DEVELOPMENT.md) |
| Run the legacy Swift Docker development loop | [Docker Compose reference](docs/LOCAL-DEVELOPMENT.md#quick-start-docker-compose) |

## Quick start: Weaver on k3d

For a fresh installation, this installs **Weaver only**. No Swift application or
migration fixture is needed. If this cluster already hosts Swift, follow
[path B of the migration lab](docs/SWIFT-WEAVER-MIGRATION.md#b--add-empty-weaver-beside-swift)
after its ingestion has finished.
Use a factory checkout containing Weaver support and a sibling Fred checkout
containing Weaver's `deploy/k3d/helmfile.yaml.gotmpl`. Once Weaver becomes the default
Git branch, ordinary sibling clones will provide these. Until then, select the
appropriate branches yourself; the factory never switches branches.

**Current command defaults still have historical names.** `ENV=swift` selects the
main cluster `fred`, not the Swift application. `INSTANCE=weaver` selects Weaver's
namespace/database. `DIR` selects the code to build. These arguments are explicit
below so a previously exported `ENV=secondary` does not select another cluster.
Changing the default Git branch does not change these Make defaults. Without `DIR`,
`make k3d-app APP=fred` still selects the pinned published release, **not Weaver**.

### 1. Prerequisites and checkout

Install Docker, [k3d](https://k3d.io), `kubectl`, `helm`,
[Helmfile](https://github.com/helmfile/helmfile/releases), `jq` and the build
prerequisites described by your Fred checkout. Run all commands from this factory:

```bash
cd /path/to/fred-deployment-factory
FRED_WEAVER_DIR="$(cd ../fred && pwd)"
git -C "$FRED_WEAVER_DIR" status --short --branch
```

Check that this is the intended Weaver checkout: builds include its local changes.
Use a fresh shell without custom `K3D_*` overrides or `K3D_REUSE_IMAGES` from another
session. Do not start Docker Compose on the same host ports.

For browser access, ensure these names resolve to `127.0.0.1`; add to `/etc/hosts`
if necessary:

```text
127.0.0.1 keycloak weaver.localhost
```

### 2. Infrastructure, then Weaver's namespace and database

```bash
make k3d-up ENV=swift INSTANCE=default
make k3d-instance ENV=swift INSTANCE=weaver
```

The first command creates/reconciles cluster `fred` and infrastructure in namespace
`fred`. The second prepares namespace `fred-weaver`, database `fred_weaver`, its
credentials, service aliases and Temporal namespace `fred-weaver`.
**Neither command installs the Weaver application.** OpenFGA is currently included
by the main infrastructure profile for Swift compatibility; Weaver does not use it.

### 3. Supply the model credential

Once per application namespace, create the operator-owned Secret. Replace the file
path below with a local file containing only your model API key (the supplied profile
uses Mistral), without a `KEY=` prefix. Never commit that file.

```bash
kubectl --context k3d-fred -n fred-weaver create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/model-api-key
```

### 4. Validate, then build and install

```bash
make k3d-app-validate ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"
make k3d-app ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"
```

Run each step only after the previous one succeeds. Validation lints and renders;
it does not build images or deploy pods. A message about images from the last build
only describes the references used for rendering. `k3d-app` builds the selected
checkout, imports its images, prepares its dependencies and installs/upgrades it.

### 5. Check readiness and sign in

```bash
kubectl --context k3d-fred -n fred-weaver get deployments
helm list --kube-context k3d-fred -n fred-weaver
make k3d-health ENV=swift INSTANCE=default
```

Expect all six deployments ready: `control-plane-backend`, `fred-agents`,
`knowledge-flow-backend`, `knowledge-flow-worker`, `frontend`, `monitor`.
Open **<http://weaver.localhost:8088>**, register/sign in and complete platform
administration bootstrap using the token retrieval command printed by deployment.
The platform starts empty. Follow the Fred checkout's `deploy/k3d/README.md` for
Weaver's organizations, models, agent templates and first document/conversation.
The technical monitor is at <http://weaver.localhost:8088/admin/monitor>.

## Day to day

Keep `FRED_WEAVER_DIR` set to your intended checkout in the current shell.

| Task | Command |
| --- | --- |
| Rebuild and update Weaver, preserving data | `make k3d-app ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"` |
| Validate configuration without deployment | `make k3d-app-validate ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"` |
| Inspect Weaver pods | `kubectl --context k3d-fred -n fred-weaver get pods` |
| Inspect collected health | `make k3d-health ENV=swift INSTANCE=default` |
| Stop the cluster, preserve data | `make k3d-down ENV=swift INSTANCE=default` |
| Start/reconcile infrastructure again | `make k3d-up ENV=swift INSTANCE=default` |

Infrastructure commands use `INSTANCE=default`; application commands use
`INSTANCE=weaver`. A redeploy is not a database reset. A cluster wipe deletes
**every namespace and volume**, including Swift if present: it is not a routine
update step. See the migration note for an explicit disposable-lab reset.

| Shared infrastructure URL | Service |
| --- | --- |
| <http://keycloak:8080> | Keycloak |
| <http://localhost:8233> | Temporal |
| <http://localhost:3002> | Grafana |
| <http://localhost:5601> | OpenSearch Dashboards |

## Published applications and library development

The published-release commands (`APP=fred` without `DIR`, `RELEASE=...`, evaluator
and Knowledge Base satellites) remain available for compatible releases. They are
not the Weaver quick start. See the [Swift/published-release reference](docs/LOCAL-DEVELOPMENT.md#swift-and-published-release-reference).
Weaver's integration with those satellites is not established by this walkthrough.

For applications that consume unreleased Fred libraries, see
[Work on unreleased Fred](docs/LOCAL-DEVELOPMENT.md#work-on-unreleased-fred).
`FRED_LIBS` controls library sourcing; it does not select Swift versus Weaver or a
Kubernetes namespace.

### Check Renovate activity

The Mend-hosted Renovate GitHub App checks the published chart versions and proposes
updates to the pins in `k3d-apps/*/helmfile.yaml.gotmpl`, according to
[`renovate.json`](renovate.json). Its jobs run on Mend; GitHub Actions runs this
repository's validation CI when a PR is opened. Merging a version bump does not deploy
anything: pull the change and run `make k3d-app APP=fred` (or `APP=fred-evaluator`).

1. Sign in to the [Mend Developer Portal](https://developer.mend.io/) with GitHub.
2. Select **fred-agent > fred-deployment-factory > Recent jobs**. Open a job and
   select **DEBUG** to inspect detected versions, warnings and errors.
3. Check **Repo Engine Settings > Dependency Updates (Renovate)**. In **Silent**
   mode, Renovate looks up updates but creates **no PRs or issues**. A completed job
   therefore does not mean a PR was created, and rerunning it does not leave Silent
   mode. A repository administrator can select **Interactive** in the repository
   settings to allow PRs; check the next job for the outcome.

**Team access:** colleagues with **Write** access to this GitHub repository should
be able to read its Renovate job logs using their own GitHub login; a separate Mend
invitation is normally unnecessary for log access. See the official
[log access documentation](https://docs.renovatebot.com/troubleshooting/#the-mend-renovate-app-this-means-the-mend-hosted-github-app)
and [Silent mode documentation](https://docs.renovatebot.com/mend-hosted/hosted-apps-config/#get-onboarding-prs-from-renovate-by-getting-out-of-silent-mode).


## More

| For | Read |
| --- | --- |
| Install Swift alone or add Weaver to it; rehearse a migration | [Migration lab](docs/SWIFT-WEAVER-MIGRATION.md) |
| Infrastructure and application contract, configuration and troubleshooting | [Local development reference](docs/LOCAL-DEVELOPMENT.md) |
| Swift demo teams and users | [Demo reference](local-testing/demo/README.md) |
| Repository working rules | [CLAUDE.md](CLAUDE.md) |
