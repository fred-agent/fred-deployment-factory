# Swift and Weaver migration lab

The [README](../README.md) is the single source for installation commands and
operator credentials. The factory prepares installations; it does not migrate data.

## Build a source installation

Prepare Swift infrastructure:

```bash
make k3d-up-swift
```

Then supply Swift's model Secret and deploy it explicitly:

```bash
make k3d-app APP=fred DIR=/absolute/path/to/swift/fred
```

Create your Swift users, teams, documents and conversations through its supported
application flows. Swift is at <http://localhost:8088>.

## Add Weaver without resetting Swift

```bash
make k3d-up-migration
```

The command retains Swift's database, identity realm, S3 data and OpenSearch index.
It prepares Weaver's separate namespace, database and Temporal namespace. It does
not build or redeploy either application and does not require a model key.
Supply Weaver's model Secret, then deploy only Weaver:

```bash
make k3d-app APP=fred DIR=/absolute/path/to/weaver/fred
```
Weaver is at <http://weaver.localhost:8088>.

Starting from Weaver alone works the same way: `make k3d-up-migration` adds the COTS needed by Swift.
A fresh `make k3d-up-migration` prepares the shared infrastructure for both applications. The requested installation
is recorded in the cluster before application deployment, protecting interrupted
installations from a subsequent accidental request for a solo mode.

## Boundaries

- Keycloak accounts are shared. This does not import application memberships or grants.
- The S3 service and document bucket are shared. This does not populate Weaver metadata.
- PostgreSQL databases and Temporal namespaces are separate.
- OpenSearch is shared, but the document corpus indexes are separate.
- Migration strategy, inventories, adapters and cutover remain separate work.
- No user, conversation, prompt, resource, KPI or marketplace content is transferred
  by these deployment commands.

## Start over deliberately

For a disposable lab only:

```bash
make k3d-wipe
make k3d-up-migration
```

**Wipe deletes all data in cluster `fred`, including both applications and model
Secrets.** It never runs implicitly during an update. Keep recoverable backups
before resetting anything you need. The retained Docker `checkpoint-*` commands
back up Compose volumes, not k3d volumes.

A solo request on a cluster containing the other application is rejected. Use
migration mode to preserve both; use an explicit wipe only when all data can go.
