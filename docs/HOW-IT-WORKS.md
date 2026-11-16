# How it works

The [README](../README.md) tells you what to run. This page explains why.

This repository is a standard cloud-native deployment of Fred on one local k3d cluster: a
k3d config file, one infrastructure chart, Fred's own chart, plain values files and
Helmfile. The `make` targets are thin. What they run is what you would type:

```bash
k3d cluster create --config k3d/cluster.yaml
helmfile sync                                                # the infrastructure
helmfile -f k3d-apps/fred/helmfile.yaml.gotmpl -e swift sync # Fred on the line swift
```

## `FRED` decides where an application goes

For Fred, Swift and Weaver are the release lines. `FRED` selects the Helmfile
environment. You type it on every application command: it has no default, and a value left
in your shell is refused.

| | Infrastructure | `FRED=swift` | `FRED=weaver` |
| --- | --- | --- | --- |
| Kubernetes namespace | `fred-infra` | `fred-swift` | `fred-weaver` |
| Browser | | <http://swift.localhost:8088> | <http://weaver.localhost:8088> |
| PostgreSQL database | | `fred_swift` | `fred_weaver` |
| Temporal namespace | | `fred-swift` | `fred-weaver` |
| Values | [k3d/values.yaml](../k3d/values.yaml) | [values-swift.yaml](../k3d-apps/fred/values-swift.yaml) | [values-weaver.yaml](../k3d-apps/fred/values-weaver.yaml) |

No branch name, checkout path or file chooses the namespace. A checkout is only verified
against `FRED`: Swift's on `FRED=weaver`, or Weaver's on `FRED=swift`, is refused.

There is no `ENV`, `INSTANCE`, `MODE` or `PROFILE`.

A standalone application can supply another environment in its own Helmfile.
The benchmark mock uses `FRED=bench` and namespace `fred-bench`; it creates no
Fred installation or infrastructure release line. See the [benchmark guide](BENCHMARKS.md).

## Why `localhost:8088` answers 404

Port 8088 is one entrance for both lines, and the hostname says which one you want. No line
is served on the plain name `localhost`.

## What `make k3d-up` prepares

The services, and everything each line relies on: its namespace, database, Temporal
namespace, `fred-secrets` and identities.

It never builds or deploys an application, requires no source checkout, and does not check
model API keys. Rerunning it preserves existing data. Applications deploy with no
administrator credential and no preparation step of their own.

It takes no variable except `VALUES`.

## What `make k3d-app` does

Each application is deployed separately. Deploying or redeploying on one line does not touch
the other, and you can deploy on only one of them.

| Input | Selects |
| --- | --- |
| `FRED` | **Required.** An environment supported by the application's Helmfile: `weaver`, `swift`, or `bench` for the standalone mock |
| `APP` | A definition of this factory (`k3d-apps/<APP>`): `fred`, and on Swift `fred-evaluator`, `webdav-kb` |
| `DIR` | A source checkout, including uncommitted changes: its `deploy/k3d/build` builds the images, with the checkout's own build tools |
| `RELEASE` | A published version instead of the version pinned in the definition; excludes `DIR` |
| `VALUES` | Extra values files, applied last |

Without `DIR` or `RELEASE`, `APP=fred` deploys the version pinned in
[its helmfile](../k3d-apps/fred/helmfile.yaml.gotmpl), bumped by Renovate after each release,
so it can lag behind the latest one. Weaver has no published release yet, so
`FRED=weaver APP=fred` requires `DIR`.

`make k3d-app-validate` renders the same selection without building or deploying. An
application defined in its own repository follows the
[application contract](LOCAL-DEVELOPMENT.md#the-k3d-application-contract).

## Credentials and the first login

Model keys are Kubernetes Secrets, one per line. On Weaver, `make k3d-app` creates
`fred-model-credentials` from your exported `MISTRAL_API_KEY` and `OPENAI_API_KEY`; on
Swift you create it. The factory never takes keys from a checkout. Without the Secret,
the deployment stops before syncing. A key selects no model: the demo organizations'
initial provider is the `VALUES` overlay you choose (see below).

The platform starts empty: the factory creates no demo people or organizations. Keycloak is
common to both lines, so one account signs in to both, but each line has its own bootstrap
token and its own administrators. `make k3d-app APP=fred` prints the token command when it finishes.

## Choose another model provider on Weaver

The default demo policy uses Mistral. Export `MISTRAL_API_KEY` for Mistral and
`OPENAI_API_KEY` for OpenAI; never place a Mistral key in Weaver's `OPENAI_API_KEY`.
Choose the initial policy before the first deployment:

```bash
# OpenAI only (requires OPENAI_API_KEY):
make k3d-app FRED=weaver APP=fred DIR=/path/to/weaver/fred VALUES=k3d-apps/fred/models-openai.yaml
# Acme on Mistral, Globex on OpenAI (requires both keys):
make k3d-app FRED=weaver APP=fred DIR=/path/to/weaver/fred VALUES=k3d-apps/fred/models-mistral-openai.yaml
```

Organization policy is initialized once after provisioning. Change it in **Models**
afterwards; redeploying an overlay does not reset an existing policy. To update model
credentials, export the intended keys and repeat the deployment command.

## What a wipe deletes

`make k3d-wipe` deletes accounts, conversations, documents, S3 objects, indexes and Secrets
in cluster `fred`, so create your model keys again afterward. It does not delete your Git
checkouts, Docker Compose volumes or another cluster.

The local OpenSearch certificates and TLS configuration survive the wipe. On the
next `make k3d-up`, the factory restores the missing certificate Secret before Helm
starts OpenSearch. An existing Secret is left untouched; restoration does not renew
certificates or recover application data.

On Docker Compose, Keycloak serves Swift and Weaver alike, so the wipes are split.
`make docker-wipe` (Swift: `docker-swift-wipe`) stops everything, then deletes one stack's
data: conversations, documents, S3 objects, indexes. Accounts live in Keycloak and survive it.
`make docker-wipe-auth` deletes Keycloak and every account, for both stacks.

A cluster from before this layout is not upgraded: `make k3d-up` refuses one with a namespace
`fred`, and Helm refuses to adopt namespaces it did not create.

## What is not here

This repository contains no GKE/GCP deployment. Docker Compose is a separate debug loop for
Weaver by default, Swift in support, run on the host from separate checkouts
([quickstart](LOCAL-DEVELOPMENT.md#docker-compose-quickstart)); it does not select a k3d configuration.
Switch data with `make docker-swift-up` or `make docker-up`; Keycloak stays shared and
application data stays separate.
