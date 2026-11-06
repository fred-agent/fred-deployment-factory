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

Swift and Weaver are Fred's release lines. `FRED` names the line, and it is the Helmfile
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
| `FRED` | **Required.** The Fred release line, so the namespace and everything in the table above |
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

Model keys are Kubernetes Secrets that you create, one per line. The factory never takes
them from a checkout or your shell. Without one, the deployment stops before syncing.

The platform starts empty: the factory creates no demo people or organizations. Keycloak is
common to both lines, so one account signs in to both, but each line has its own bootstrap
token and its own administrators. `make k3d-app` prints the token command when it finishes.

## What a wipe deletes

`make k3d-wipe` deletes accounts, conversations, documents, S3 objects, indexes and Secrets
in cluster `fred`, so create your model keys again afterward. It does not delete your Git
checkouts, Docker Compose volumes or another cluster.

A cluster from before this layout is not upgraded: `make k3d-up` refuses one with a namespace
`fred`, and Helm refuses to adopt namespaces it did not create.

## What is not here

This repository contains no GKE/GCP deployment. Docker Compose tools are separate legacy
infrastructure tools, not a selector for these k3d commands; the current Compose files do
not supply OpenFGA and cannot alone recreate a Swift installation.
