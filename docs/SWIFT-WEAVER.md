# Swift and Weaver side by side

For Fred developers comparing the two versions. First install Weaver using the
[README](../README.md#k3d), then add Swift to the same cluster.

`make k3d-up` prepares the infrastructure for both versions; it does not deploy
either application. The commands below deploy Swift separately. **They do not migrate data.** The migration strategy is deferred
until Weaver covers Swift's features; no user, conversation, prompt, resource, KPI or
marketplace content is transferred by these commands.

## Add Swift

1. Add `swift.localhost` to the same `127.0.0.1` entry in `/etc/hosts`.
2. Create Swift's model Secret once. Unlike Weaver, Swift expects its **Mistral**
   key under `OPENAI_API_KEY`. Supply a private file containing only that key:

   ```bash
   kubectl --context k3d-fred -n fred-swift create secret generic fred-model-credentials \
     --from-file=OPENAI_API_KEY=/path/to/mistral-key-file
   ```

3. From the factory, deploy the pinned published Swift release:

   ```bash
   make k3d-app FRED=swift APP=fred
   ```

   To build a Swift checkout instead:

   ```bash
   make k3d-app FRED=swift APP=fred DIR=/path/to/swift/fred
   ```

4. Open [Swift](http://swift.localhost:8088) alongside
   [Weaver](http://weaver.localhost:8088). Use your existing login account; Swift
   has its own administrator bootstrap token, printed by its deployment command.
   Provision its application data separately.

Repeat the appropriate deployment command to update only that version.
`make k3d-stop` and `make k3d-start` pause/resume the whole cluster.

## Swift capability preparation

A Swift checkout that includes capability preparation starts the separate
`fred-agents-preparation-worker` Deployment, with PPT Builder still on its legacy
path. Only after following Fred's
[backfill procedure](https://github.com/ThalesGroup/fred/blob/swift/docs/swift/ops/migrations/reusable-capability-preparation.md),
enable the cutover with:

```bash
K3D_PPT_PREPARATION=true make k3d-app FRED=swift APP=fred DIR=/path/to/swift/fred
```

## Boundaries

| Resource | Boundary |
| --- | --- |
| Kubernetes | Separate namespaces: `fred-infra` for the infrastructure, `fred-swift` for Swift, `fred-weaver` for Weaver |
| PostgreSQL | One server, separate databases and logins |
| Temporal | One server, separate namespaces |
| Model key | One Secret per application namespace |
| OpenSearch | One instance, separate corpus, application log and KPI indexes |
| Keycloak | **Common by design:** one IdP for every organization and application. This does not share memberships or grants, which belong to each application |
| S3 | **Shared:** one SeaweedFS service, and common buckets including `app-content-documents` |

| Index | Swift | Weaver |
| --- | --- | --- |
| Document | `vector-index-mistral` | `document-vectors-<organization_id>`, one per organization |
| Application logs | `app-logs-index` | none: stdout, collected into `k3d-logs-*` |
| KPI | `kpi-index` | `weaver-kpi` |

Weaver's OpenSearch accounts can only reach its own indexes. Swift still connects as
the OpenSearch administrator.

Both lines use the context `k3d-fred`. Each line's namespace has its own `fred-secrets`, and
short aliases (`postgres`, `keycloak`, ...) to the services in `fred-infra`.

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
- **Cluster logs and metrics:** Fluent Bit's `k3d-logs-*` covers the three namespaces and
  `k3d-events-*` the whole cluster; filter on the Kubernetes namespace. Prometheus scrapes
  the three namespaces; filter on its `namespace` label.

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

`make k3d-up` restores the OpenSearch TLS Secret from the retained local
certificates when HTTPS was configured. Recreate model Secrets and deploy each
application separately, as on the first installation.
