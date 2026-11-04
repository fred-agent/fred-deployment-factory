# Fred Deployment Factory

One local k3d cluster that runs **Swift and Weaver side by side**, each isolated from
the other, so you can test or work on either one at any time.

```bash
make k3d-up                                               # 1. Infrastructure for both
make k3d-app APP=fred DIR=/absolute/path/to/swift/fred    # 2. Deploy Swift, when needed
make k3d-app APP=fred DIR=/absolute/path/to/weaver/fred   # 2. Deploy Weaver, when needed
```

`make k3d-up` prepares the services and each application's namespace and database. It
never builds or deploys an application, requires no source checkout, and does not check
model API keys. Rerunning it preserves existing data. The factory never switches Git
branches.

Each application is deployed separately. Deploying or redeploying one does not touch
the other, and you can deploy only one of them.

## Prepare once

Install Docker, k3d, kubectl, Helm and jq. Application deployment also needs
Helmfile, Python 3 with PyYAML and the selected checkout's build tools. Keep
Docker Compose stopped on these ports.

Ensure `/etc/hosts` contains:

```text
127.0.0.1 keycloak weaver.localhost
```

## Deploy an application

Supply the model credential for the application you intend to deploy, once per
application. Use a private file containing only your Mistral API key:

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

**`APP=fred` is the same for both: `DIR` selects the application.** It chooses the
source checkout, including uncommitted changes. A Weaver checkout is identified by
`apps/control-plane/Cargo.toml` and placed in `fred-weaver`; the published Swift
definition and other applications use `fred`. No branch name or persistent shell
selector chooses placement.

The existing application contract remains available: `APP` selects a factory
definition, `DIR` selects source, and `RELEASE` selects a published version instead
of source. `make k3d-app-validate` renders the same selection without building or
deploying. See the [application contract](docs/LOCAL-DEVELOPMENT.md#the-k3d-application-contract)
for other application inputs. `local-checkouts.json` is no longer used.

Model keys remain operator-owned Kubernetes Secrets; the factory never takes them
from a checkout or shell environment. A missing model key is an application
prerequisite, not an infrastructure startup failure.

The platform starts empty: sign in and follow the bootstrap-token command printed
at the end of deployment. No demo people or organizations are created by the factory.

## What each application uses

Both use context `k3d-fred`, and infrastructure lives in namespace `fred`.

| | Swift | Weaver |
| --- | --- | --- |
| Browser | <http://localhost:8088> | <http://weaver.localhost:8088> |
| Namespace | `fred` | `fred-weaver` |
| PostgreSQL database | `fred` | `fred_weaver` |
| Temporal namespace | `default` | `fred-weaver` |
| Document index | `vector-index-mistral` | `document-vectors` |
| Application logs index | `app-logs-index` | `weaver-app-logs` |
| KPI index | `kpi-index` | `weaver-kpi` |

**Shared on purpose:** Keycloak, the one IdP common to every organization and
application, and S3. The OpenSearch instance is shared too, but never its indexes.
Details and limits are in [Swift and Weaver side by side](docs/SWIFT-WEAVER.md).

## Update, pause, inspect, reset

| Intent | Command |
| --- | --- |
| Update COTS | `make k3d-up` |
| Render COTS without changing the cluster | `make k3d-validate` |
| Build/deploy one application | `make k3d-app APP=fred DIR=/path/to/checkout` |
| Render one application | `make k3d-app-validate APP=fred DIR=/path/to/checkout` |
| Pause / resume existing containers, preserving data | `make k3d-stop` / `make k3d-start` |
| Inspect deployments / collected diagnostics | `make k3d-status` / `make k3d-health` |
| **Delete the cluster and all its data** | **`make k3d-wipe`** |

To start a disposable lab over, run `make k3d-wipe`, then `make k3d-up`. Wipe deletes
accounts, conversations, documents, S3 objects, indexes and Secrets in cluster `fred`;
it does not delete your Git checkouts, Docker Compose volumes or another cluster.
Recreate model Secrets afterward.

## One application only

Most of the time `make k3d-up` is what you want: it costs one extra OpenFGA service
when you only deploy Weaver. To check that one application runs without the other's
infrastructure:

| Command | Prepares |
| --- | --- |
| `make k3d-up-swift` / `make k3d-validate-swift` | Swift's COTS, including OpenFGA |
| `make k3d-up-weaver` / `make k3d-validate-weaver` | Weaver's COTS, without OpenFGA. Its empty backing database stays reserved, so `make k3d-up` can add Swift later without resetting PostgreSQL |

Going from either of these to `make k3d-up` preserves existing data. Going back from
both applications to one is refused: it requires an explicit `make k3d-wipe`.

## Command rules

There is **no `ENV`, `INSTANCE`, `MODE` or `PROFILE` selector**. Infrastructure commands
reject command-line variable assignments and old deployment environment overrides.
`APP`, `DIR`, `RELEASE` and `VALUES` belong to the separate `k3d-app` commands.
`STACK` and `K3D_*` overrides do not select a local installation. `make k3d-up` replaces
the former `make k3d-up-migration`, which now fails with a pointer to it.

## References

- [Swift and Weaver side by side: boundaries](docs/SWIFT-WEAVER.md)
- [Technical reference and retained Docker tools](docs/LOCAL-DEVELOPMENT.md)
- [Weaver database bootstrap](k3d-apps/fred/README-postgres.md)

This repository contains no GKE/GCP deployment. Docker Compose tools are separate
legacy infrastructure tools, not a selector for these k3d commands; the current
Compose files do not supply OpenFGA and cannot alone recreate a Swift installation.
