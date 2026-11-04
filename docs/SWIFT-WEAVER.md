# Swift and Weaver side by side

The [README](../README.md) is the single source for installation commands and
operator credentials. This page explains what `make k3d-up` isolates and what it shares.

`make k3d-up` runs both applications on one cluster so that each can be developed and
tested independently. **It does not migrate data.** The migration strategy is deferred
until Weaver covers Swift's features; no user, conversation, prompt, resource, KPI or
marketplace content is transferred by these commands.

## Boundaries

| Resource | Boundary |
| --- | --- |
| Kubernetes | Separate namespaces: `fred` for Swift and the infrastructure, `fred-weaver` for Weaver |
| PostgreSQL | One server, separate databases and logins |
| Temporal | One server, separate namespaces |
| Model key | One Secret per application namespace |
| OpenSearch | One instance, separate corpus, application log and KPI indexes |
| Keycloak | **Common by design:** one IdP for every organization and application. This does not share memberships or grants, which belong to each application |
| S3 | **Shared:** one SeaweedFS service, and common buckets including `app-content-documents` |

Weaver's OpenSearch accounts can only reach its own indexes. Swift still connects as
the OpenSearch administrator.

## What remains common

- **Search pipeline:** `hybrid-search-pipeline` is global to the OpenSearch instance. A
  Weaver deployment stops if its definition differs from the existing one.
- **S3 objects:** the two applications do not collide or delete each other's objects,
  because their document identifiers differ and Weaver's cleanup ignores another
  installation's objects. But the separation is not enforced by permissions: Weaver's
  identities cover the whole document bucket, and its agent runtime has S3 administrator
  access.
- **Swift's store audit:** Weaver's documents appear as `orphan_content`. Do not delete
  them on that basis.
- **Cluster logs and metrics:** Fluent Bit's `k3d-logs-*` and `k3d-events-*` cover the
  whole cluster; filter on the Kubernetes namespace. Prometheus scrapes both namespaces;
  filter on its `namespace` label.

## Add an application to an existing installation

From `make k3d-up-swift` or `make k3d-up-weaver`, `make k3d-up` retains existing data
and prepares the other application's boundaries. It does not build or redeploy either
application. Supply the model Secret, then deploy the one you want.

The requested installation is recorded in the cluster before application deployment,
which protects interrupted installations from a later accidental request for a solo
installation. Such a request on a cluster holding both applications is rejected.

## Start over deliberately

For a disposable lab only:

```bash
make k3d-wipe
make k3d-up
```

**Wipe deletes all data in cluster `fred`, including both applications and model
Secrets.** It never runs implicitly during an update. Keep recoverable backups
before resetting anything you need. The retained Docker `checkpoint-*` commands
back up Compose volumes, not k3d volumes.
