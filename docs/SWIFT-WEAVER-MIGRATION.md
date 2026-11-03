# Swift → Weaver migration lab

This is the optional workflow for the developers working on migration. For ordinary
Weaver development, use the [Weaver quick start](../README.md#quick-start-weaver-on-k3d).

Choose one path:

- **A — Swift alone:** build a representative source installation and stop there.
- **A then B — Swift + Weaver:** keep that populated Swift and add empty Weaver on
  the same infrastructure, ready for migration investigation.
- **B only:** Swift is already installed on `k3d-fred`; preserve it and add Weaver.

This guide prepares the installations. It does **not** implement transfer of users,
permissions, documents or conversations. The intended migration is a one-way cutover,
not ongoing synchronization or continued writes from both applications after adoption.

## Names and boundaries

All commands run from the **same factory checkout**, with Weaver deployment support.
The directory you run Make in does not choose a cluster.

| Selector | Meaning here |
| --- | --- |
| `ENV=swift` | Main infrastructure: cluster `fred`, context `k3d-fred`, ordinary host ports |
| `INSTANCE=default` | Infrastructure commands, or Swift application in namespace `fred` |
| `INSTANCE=weaver` | Weaver application in namespace `fred-weaver` |
| `DIR="$FRED_SWIFT_DIR"` / `DIR="$FRED_WEAVER_DIR"` | Source checkout to build, including uncommitted changes |
| `ENV=secondary` | Another independent cluster; not used in this lab |

| Resource | Swift | Weaver |
| --- | --- | --- |
| Browser URL | `http://localhost:8088` | `http://weaver.localhost:8088` |
| Kubernetes namespace | `fred` | `fred-weaver` |
| Helm application release | `fred-app` in `fred` | `fred-app` in `fred-weaver` |
| PostgreSQL server | Shared | Shared |
| PostgreSQL database | `fred` | `fred_weaver` |
| S3 service / documents bucket | `seaweedfs:8333` / `app-content-documents` | Same service and exact same bucket |
| OpenSearch server | Shared | Shared |
| Document vector index | `vector-index-mistral` | `document-vectors` |
| Temporal server / namespace | Shared / `default` | Shared / `fred-weaver` |
| Keycloak | Shared realm `app` | Same accounts; separate application permissions |
| Authorization | OpenFGA | Weaver's PostgreSQL authorization model |

The **same OpenSearch index is not yet used**: mappings, embedding compatibility,
document identities and access filtering still need review. Sharing S3 does not
make Swift documents visible in Weaver's empty database. Shared login accounts do
not import Swift memberships or grants.

## Before either path

Use the [quick start prerequisites](../README.md#1-prerequisites-and-checkout), including
Docker, k3d, kubectl, Helm, Helmfile and jq. Use two existing Fred checkouts/worktrees:
one Swift and one Weaver. Do not switch one checkout back and forth during builds.
These example paths match the migration development setup; replace them as needed:

```bash
cd ~/Rebac/fred-deployment-factory
FRED_SWIFT_DIR="$HOME/Prism/fred"
FRED_WEAVER_DIR="$HOME/Rebac/fred"
git status --short --branch
git -C "$FRED_SWIFT_DIR" status --short --branch
git -C "$FRED_WEAVER_DIR" status --short --branch
make k3d-env ENV=swift INSTANCE=default
```

Verify the actual branches/content; a directory named `Rebac` does not guarantee
branch `weaver`. The factory never switches branches. Commands below explicitly
select environment and instance; use a fresh shell without custom `K3D_*` overrides
or `K3D_REUSE_IMAGES` left from another session. Run each step only after the previous
one succeeds. Ensure these browser names resolve locally:

```text
127.0.0.1 keycloak weaver.localhost
```

If Swift already contains data, start at **B**, without wiping or recreating its
foundation. Before actual data migration, keep recoverable PostgreSQL and S3 backups;
`checkpoint-save` only backs up Docker Compose volumes, not k3d PVCs.

## A — Install Swift alone

### A1. Create a Swift-compatible foundation

For a new lab, the main profile provides OpenFGA and Swift's database setup:

```bash
make k3d-up ENV=swift INSTANCE=default \
  K3D_OPENFGA_ENABLED=true K3D_POSTGRES_APPLICATION_BOOTSTRAP=false
```

This installs infrastructure only. Do not run the standalone secondary Weaver
infrastructure profile over a populated Swift foundation. Initialization flags do
not migrate an existing PostgreSQL volume.

### A2. Supply Swift's model credential

Once, create the operator-owned Secret in **`fred`**. Replace the path with a file
containing only the model API key (Mistral for the supplied profile), without a
`KEY=` prefix. Do not commit the file. If the Secret already exists, keep it.

```bash
kubectl --context k3d-fred -n fred create secret generic fred-model-credentials \
  --from-file=OPENAI_API_KEY=/absolute/path/to/model-api-key
```

### A3. Validate, build and deploy Swift

```bash
make k3d-app-validate ENV=swift INSTANCE=default APP=fred DIR="$FRED_SWIFT_DIR"
make k3d-app ENV=swift INSTANCE=default APP=fred DIR="$FRED_SWIFT_DIR"
kubectl --context k3d-fred -n fred get deployments
helm list --kube-context k3d-fred -n fred
```

Open <http://localhost:8088>, register/sign in and use the bootstrap-token retrieval
command printed by deployment. Create/import representative teams, users and
permissions, ingest documents, then start a few conversations. The
[Swift demo guide](../local-testing/demo/README.md) describes its fixture tools;
those fixtures are not a Weaver import format.

Wait until ingestion finishes. Record enough source evidence to compare later:
user/team memberships, a document that can be opened/searched, and a conversation
with several turns. **You may stop here: this is the Swift-only installation.**

## B — Add empty Weaver beside Swift

No `k3d-up`, wipe, cluster creation or Swift redeployment is needed for this path.
**Wait for Swift ingestion to finish:** Weaver's first preparation adds S3
identities and rolls the shared SeaweedFS deployment.

### B1. Validate Weaver's configuration

```bash
make k3d-app-validate ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"
```

This lints/renders only. It creates no application pods and builds no images.
“Images of the last build” refers to cached image references used by validation;
the normal deployment in B4 builds the current checkout.

### B2. Prepare Weaver's namespace and database

```bash
make k3d-instance ENV=swift INSTANCE=weaver
```

Expected output includes `namespace fred-weaver`, `database fred_weaver`,
`infrastructure fred`. This creates/reuses the managed namespace, service aliases,
application foundation Secret, database and Temporal namespace. It does not install
Weaver pods. It preserves credentials on replay and refuses the source database or
an unmanaged namespace. Weaver component SQL roles are server-wide: this setup
supports **one Weaver installation per PostgreSQL server** and refuses roles already
bound to another database.

### B3. Copy the operator model credential

Explicitly reuse Swift's model key in Weaver's namespace. This copies only the
`fred-model-credentials` Secret, not users, database passwords or bootstrap tokens:

```bash
kubectl --context k3d-fred -n fred get secret fred-model-credentials -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:"fred-model-credentials",namespace:"fred-weaver"}}' \
  | kubectl --context k3d-fred apply -f -
```

Alternatively, create that Secret in `fred-weaver` from your own model-key file as
in the Weaver quick start. Hooks never obtain model keys from a checkout.

### B4. Build and deploy Weaver

```bash
make k3d-app ENV=swift INSTANCE=weaver APP=fred DIR="$FRED_WEAVER_DIR"
```

This builds/imports Weaver images, initializes its database schemas, prepares its
S3/search access and installs its Helm release. Application deployment also repeats
instance preparation; that repeat is expected and preserves the same boundary.
Existing realm clients are reused; the processing worker has its own client.
S3 preparation preserves existing identities and adds scoped Weaver identities.
An incompatible existing shared search pipeline stops preparation instead of being
overwritten. Kubernetes cluster role names include the application namespace to
avoid collisions with Swift.

### B5. Check both installations

```bash
helm list --kube-context k3d-fred -A
kubectl --context k3d-fred -n fred get deployments
kubectl --context k3d-fred -n fred-weaver get deployments
make k3d-health ENV=swift INSTANCE=default
```

Expect two `fred-app` releases in different namespaces and six ready Weaver
deployments: `control-plane-backend`, `fred-agents`, `knowledge-flow-backend`,
`knowledge-flow-worker`, `frontend`, `monitor`.

- Swift at <http://localhost:8088> must still show the source teams, documents and
  conversations recorded in A3. Verify login, document access and a conversation.
- Weaver at <http://weaver.localhost:8088> accepts the same Keycloak account but has
  its own platform bootstrap and no imported application data. Use the token
  retrieval command printed by **Weaver's** deployment, targeting `fred-weaver`.
- Its technical monitor is at <http://weaver.localhost:8088/admin/monitor>.

Weaver's cleanup uses its persisted installation ownership marker. The successful
empty-target coexistence check does not establish safe deletion after adopting
Swift document keys. Do not test deletion of adopted/shared documents until the
migration lifecycle is defined. Conversation continuation also needs a later
migration of the relevant records; installing Weaver alone does not provide it.

## Update, stop or replay the lab

To update just one application, rerun its exact A3 or B4 deploy command with the
same checkout and instance. Data remains. Do not omit `DIR`: that selects the
factory's pinned published release, not the intended checkout. Do not reuse the
Swift release/namespace for Weaver.

```bash
# Stop/resume both applications and their shared infrastructure; preserve data.
make k3d-down ENV=swift INSTANCE=default
make k3d-up ENV=swift INSTANCE=default
```

**Replay from zero only on a disposable lab.** The following destroys **both
applications and all their cluster volumes**, including shared S3, PostgreSQL,
Keycloak and OpenSearch data. It leaves a separate `fred-secondary` cluster alone.
Keep any required backups outside the cluster before running it:

```bash
make k3d-wipe ENV=swift INSTANCE=default
```

Then repeat **A1–A3**, recreate the Swift fixture, and repeat **B1–B5**. The model
Secret must also be recreated. Deleting Weaver's namespace or uninstalling its
chart is not a clean migration reset: its database and shared S3/index data can
remain. A target-only reset procedure and migration tool are not provided yet.

## Where the configuration lives

| Location | Responsibility |
| --- | --- |
| Factory `Makefile`, `bin/k3d-environment.sh` | Cluster/instance selection, URLs and namespace/database defaults |
| Factory `bin/k3d-instance` | Separate application namespace/database, aliases and Temporal namespace |
| Factory `k3d/` | Shared foundation, including optional OpenFGA |
| Factory `k3d-apps/fred/` | Swift-compatible base values and shared PostgreSQL preparation hook |
| Weaver checkout `deploy/k3d/helmfile.yaml.gotmpl` | Weaver deployment composition; takes precedence over the factory Helmfile |
| Weaver checkout `deploy/k3d/instance-values.yaml.gotmpl` | Target database, Temporal namespace and host-specific ingress |
| Weaver checkout `deploy/k3d/values.yaml.gotmpl`, `prepare_ingestion.py` | Weaver components and shared S3/search configuration |
| Each Fred checkout `deploy/charts/fred/`, `deploy/k3d/build` | Its application chart and image build |

Defaults used here can be overridden through `K3D_INFRA_NAMESPACE`, `K3D_NAMESPACE`,
`K3D_DATABASE`, `K3D_TEMPORAL_NAMESPACE` and `K3D_APP_HOST`. Keep the documented
values for the first rehearsal; custom names require consistent commands throughout.
