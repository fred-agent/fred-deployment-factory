# Fred Deployment Factory

A standard cloud-native deployment of Fred on one local k3d cluster: a k3d config file,
one infrastructure chart, Fred's own chart, plain values files and Helmfile. The **Fred
release lines, Swift and Weaver, run side by side**, each isolated from the other.

```bash
make k3d-up                                                          # 1. The infrastructure
make k3d-app FRED=swift  APP=fred                                    # 2. Swift's published release
make k3d-app FRED=swift  APP=fred DIR=/absolute/path/to/swift/fred   #    or your Swift checkout
make k3d-app FRED=weaver APP=fred DIR=/absolute/path/to/weaver/fred  # 2. Your Weaver checkout
```

The `make` targets are thin. What they run is what you would type:

```bash
k3d cluster create --config k3d/cluster.yaml
helmfile sync                                                # the infrastructure
helmfile -f k3d-apps/fred/helmfile.yaml.gotmpl -e swift sync # Fred on the line swift
```

**`FRED` says where an application goes**: it is the Helmfile environment. You type it on
every application command; it has no default, and a value left in your shell is refused.

| | Infrastructure | `FRED=swift` | `FRED=weaver` |
| --- | --- | --- | --- |
| Kubernetes namespace | `fred-infra` | `fred-swift` | `fred-weaver` |
| Browser | | <http://swift.localhost:8088> | <http://weaver.localhost:8088> |
| PostgreSQL database | | `fred_swift` | `fred_weaver` |
| Temporal namespace | | `fred-swift` | `fred-weaver` |
| Values | [k3d/values.yaml](k3d/values.yaml) | [values-swift.yaml](k3d-apps/fred/values-swift.yaml) | [values-weaver.yaml](k3d-apps/fred/values-weaver.yaml) |

No branch name, checkout path or file chooses the namespace. A checkout is only verified
against `FRED`: Swift's on `FRED=weaver`, or Weaver's on `FRED=swift`, is refused.

`make k3d-up` prepares the services and everything each line relies on: its namespace,
database, Temporal namespace, `fred-secrets` and identities. It never builds or deploys an
application, requires no source checkout, and does not check model API keys. Rerunning it
preserves existing data. Applications deploy with no administrator credential and no
preparation step of their own.

Each application is deployed separately. Deploying or redeploying on one line does not
touch the other, and you can deploy on only one of them.

## Prepare once

Install Docker, k3d, kubectl, Helm and Helmfile, plus the selected checkout's build tools.
Keep Docker Compose stopped on these ports.

Ensure `/etc/hosts` contains:

```text
127.0.0.1 keycloak swift.localhost weaver.localhost
```

## Deploy an application

Supply the model credential for the line you intend to deploy on, once per line. Use a
private file containing only your Mistral API key:

```bash
kubectl --context k3d-fred -n fred-swift create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/model-api-key
make k3d-app FRED=swift APP=fred
```

The inputs of `k3d-app`:

| Input | Selects |
| --- | --- |
| `FRED` | **Required.** The Fred release line, so the namespace and everything in the table above |
| `APP` | A definition of this factory (`k3d-apps/<APP>`): `fred`, and on Swift `fred-evaluator`, `webdav-kb` |
| `DIR` | A source checkout, including uncommitted changes: its `deploy/k3d/build` builds the images |
| `RELEASE` | A published version instead of the version pinned in the definition; excludes `DIR` |
| `VALUES` | Extra values files, applied last |

Without `DIR` or `RELEASE`, `APP=fred` deploys the version pinned in
[its helmfile](k3d-apps/fred/helmfile.yaml.gotmpl), bumped by Renovate after each
release, which can lag behind the latest one. Weaver has no published release yet:
`FRED=weaver APP=fred` requires `DIR`.

`make k3d-app-validate` renders the same selection without building or deploying. See the
[application contract](docs/LOCAL-DEVELOPMENT.md#the-k3d-application-contract) for an
application defined in its own repository.

Model keys remain operator-owned Kubernetes Secrets; the factory never takes them
from a checkout or shell environment. Without one, the deployment stops before syncing.

The platform starts empty: sign in and follow the bootstrap-token command printed
at the end of deployment. No demo people or organizations are created by the factory.

## What the lines share

Both use context `k3d-fred`. Each line's namespace has its own `fred-secrets`, and short
aliases (`postgres`, `keycloak`, ...) to the services in `fred-infra`.

| | Swift | Weaver |
| --- | --- | --- |
| Document index | `vector-index-mistral` | `document-vectors` |
| Application logs index | `app-logs-index` | `weaver-app-logs` |
| KPI index | `kpi-index` | `weaver-kpi` |

**Shared on purpose:** Keycloak, the one IdP common to every organization and
application, and S3. The OpenSearch instance is shared too, but never its indexes.
Details and limits are in [Swift and Weaver side by side](docs/SWIFT-WEAVER.md).

## Update, pause, inspect, reset

| Intent | Command |
| --- | --- |
| Update the infrastructure | `make k3d-up` |
| Render the infrastructure without changing the cluster | `make k3d-validate` |
| Build/deploy one application | `make k3d-app FRED=<line> APP=fred DIR=/path/to/checkout` |
| Render one application | `make k3d-app-validate FRED=<line> APP=fred DIR=/path/to/checkout` |
| Uninstall one application | `make k3d-app-uninstall FRED=<line> APP=fred` |
| Pause / resume existing containers, preserving data | `make k3d-stop` / `make k3d-start` |
| Inspect each namespace / collected diagnostics | `make k3d-status` / `make k3d-health` |
| **Delete the cluster and all its data** | **`make k3d-wipe`** |

To start a disposable lab over, run `make k3d-wipe`, then `make k3d-up`. Wipe deletes
accounts, conversations, documents, S3 objects, indexes and Secrets in cluster `fred`;
it does not delete your Git checkouts, Docker Compose volumes or another cluster.
Recreate model Secrets afterward.

**A cluster from before this layout** is not upgraded: `make k3d-up` refuses one with a
namespace `fred`, and Helm refuses to adopt namespaces it did not create. Save what you
need, then wipe and start over.

If a deployment was interrupted and Helm reports another operation in progress, roll the
release back with `helm --kube-context k3d-fred -n <namespace> rollback <release>`.

## Command rules

`FRED` is the only selector, always on the command line, and only on application commands:
`make k3d-up` prepares every line. There is **no `ENV`, `INSTANCE`, `MODE` or `PROFILE`**.
`APP`, `DIR` and `RELEASE` belong to the `k3d-app` commands; `VALUES` applies to both.

## References

- [Swift and Weaver side by side: boundaries](docs/SWIFT-WEAVER.md)
- [Technical reference and retained Docker tools](docs/LOCAL-DEVELOPMENT.md)

This repository contains no GKE/GCP deployment. Docker Compose tools are separate
legacy infrastructure tools, not a selector for these k3d commands; the current
Compose files do not supply OpenFGA and cannot alone recreate a Swift installation.
