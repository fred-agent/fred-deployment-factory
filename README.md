# Fred Deployment Factory

One local k3d cluster. Prepare the required COTS first, then deploy applications separately:

```bash
make k3d-up-swift       # COTS for Swift, including OpenFGA
make k3d-up-weaver      # COTS for Weaver, without OpenFGA
make k3d-up-migration   # Shared COTS for Swift + Weaver
```

Choose one infrastructure command. It prepares the services and the required
namespace/database boundaries. It never builds or deploys a Fred application,
requires no source checkout, and does not check model API keys. Rerunning it
preserves existing data. The factory never switches Git branches.

## Prepare once

Install Docker, k3d, kubectl, Helm and jq. Application deployment also needs
Helmfile, Python 3 with PyYAML and the selected checkout's build tools. Keep
Docker Compose stopped on these ports.

Ensure `/etc/hosts` contains:

```text
127.0.0.1 keycloak weaver.localhost
```

## Deploy applications separately

After infrastructure startup, supply the model credential only for the application
you intend to deploy. Use a private file containing only your Mistral API key:

```bash
# Swift
kubectl --context k3d-fred -n fred create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/model-api-key
make k3d-app APP=fred DIR=/absolute/path/to/swift/fred

# Weaver
kubectl --context k3d-fred -n fred-weaver create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/model-api-key
make k3d-app APP=fred DIR=/absolute/path/to/weaver/fred
```

Run either application command when needed; migration infrastructure does not
implicitly deploy both. `DIR` chooses the source checkout, including uncommitted
changes. A Weaver checkout is identified by `apps/control-plane/Cargo.toml` and
placed in `fred-weaver`; the published Swift definition and other applications use
`fred`. No branch name or persistent shell selector chooses placement.

The existing application contract remains available: `APP` selects a factory
definition, `DIR` selects source, and `RELEASE` selects a published version instead
of source. `make k3d-app-validate` renders the same selection without building or
deploying. See the [application contract](docs/LOCAL-DEVELOPMENT.md#the-k3d-application-contract)
for other application inputs. `local-checkouts.json` is no longer used.

Model keys remain operator-owned Kubernetes Secrets; the factory never takes them
from a checkout or shell environment. A missing model key is an application
prerequisite, not an infrastructure startup failure.

| | Swift | Weaver |
| --- | --- | --- |
| Browser | <http://localhost:8088> | <http://weaver.localhost:8088> |
| Namespace | `fred` | `fred-weaver` |
| PostgreSQL database | `fred` | `fred_weaver` |
| Temporal namespace | `default` | `fred-weaver` |
| Document index | `vector-index-mistral` | `document-vectors` |

Both use context `k3d-fred`. Infrastructure lives in `fred`. Keycloak and S3 are
shared; application permissions, databases and corpus indexes remain separate.
Weaver alone does not deploy the OpenFGA service. Its empty backing database is
reserved so Swift can be added later without resetting PostgreSQL. Swift and
migration include the service automatically.
The platform starts empty: sign in and follow the bootstrap-token command printed
at the end of deployment. No demo people or organizations are created by the factory.

## Update, pause, inspect, reset

| Intent | Command |
| --- | --- |
| Update COTS | Repeat the selected `make k3d-up-*` command |
| Build/deploy one application | `make k3d-app APP=fred DIR=/path/to/checkout` |
| Render one application | `make k3d-app-validate APP=fred DIR=/path/to/checkout` |
| Render without building or changing the cluster | `make k3d-validate-swift`, `make k3d-validate-weaver`, or `make k3d-validate-migration` |
| Pause / resume existing containers, preserving data | `make k3d-stop` / `make k3d-start` |
| Inspect deployments / collected diagnostics | `make k3d-status` / `make k3d-health` |
| **Delete the cluster and all its data** | **`make k3d-wipe`** |

Going from either solo installation to `make k3d-up-migration` preserves existing data
and prepares the other application's infrastructure boundary. Deploy each application
separately when wanted.
Going from migration to a solo installation is refused. To start a disposable lab
over, run `make k3d-wipe`, then the desired command. Wipe deletes accounts, conversations,
documents, S3 objects, indexes and Secrets in cluster `fred`; it does not delete your
Git checkouts, Docker Compose volumes or another cluster. Recreate model Secrets afterward.

There is **no `ENV`, `INSTANCE`, `MODE` or `PROFILE` selector**. Infrastructure commands reject
command-line variable assignments and old deployment environment overrides. `APP`,
`DIR`, `RELEASE` and `VALUES` belong to the separate `k3d-app` commands.
`STACK` and `K3D_*` overrides do not select a local installation. The old generic
`make k3d-up` points to the explicit infrastructure commands.

## References

- [Migration lab boundaries](docs/SWIFT-WEAVER-MIGRATION.md)
- [Technical reference and retained Docker tools](docs/LOCAL-DEVELOPMENT.md)
- [Weaver database bootstrap](k3d-apps/fred/README-postgres.md)

This repository contains no GKE/GCP deployment. Docker Compose tools are separate
legacy infrastructure tools, not a selector for these k3d commands; the current
Compose files do not supply OpenFGA and cannot alone recreate a Swift installation.
