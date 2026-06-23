# Fredlab Storage Inventory

Single source of truth for **every** datastore in the fredlab deployment: PostgreSQL
databases, OpenSearch indices, and GCS buckets. Keep this updated whenever a store,
index, bucket, or backend choice changes.

Backend decisions:
- **Vector / semantic / hybrid search → OpenSearch** (more search modes than pgvector).
- **Relational catalog data → PostgreSQL.**
- **Object / file content → Google Cloud Storage** (Workload Identity, no keys).

---

## 1. PostgreSQL — one `postgres` StatefulSet, port 5432

Databases, users, and grants are created by the `postgres-provision` Helm hook
(`templates/postgres-provision-job.yaml`).

| Database | Owner user | Used by | Contents |
| --- | --- | --- | --- |
| `keycloak` | `keycloak_db_user` | Keycloak | realms, clients, users, sessions (Keycloak-managed schema) |
| `openfga` | `openfga` | OpenFGA | ReBAC authorization tuples + model (OpenFGA-managed schema) |
| `temporal` | `temporal` | Temporal | workflow execution history/state |
| `temporal_visibility` | `temporal` | Temporal | workflow visibility/search |
| `fred` | `fred` | **Control Plane + Knowledge Flow** | see breakdown below |

### `fred` database — table owners

Two services share the `fred` database (different tables, same DB):

| Producer | How tables are created | Tables |
| --- | --- | --- |
| Control Plane | Alembic (`alembic upgrade head` migration job) | control-plane schema + `alembic_version_control_plane` |
| Knowledge Flow | SQLModel auto-create at startup | metadata store, tag store, resource store tables |

Knowledge Flow store → backend:

| KF store | Backend | Location |
| --- | --- | --- |
| `metadata_store` | PostgreSQL (`fred`) | SQLModel table |
| `tag_store` | PostgreSQL (`fred`) | SQLModel table |
| `resource_store` | PostgreSQL (`fred`) | SQLModel table |
| `log_store` | in-memory | not persisted |
| `vector_store` | **OpenSearch** | see §2 |
| `tabular_store` | GCS objects (parquet) | see §3, `-objects` bucket |

> Note: the `vector` (pgvector) extension is created in `fred` by the provision hook
> but is currently **unused** — the vector store runs on OpenSearch. It is kept as a
> harmless no-op so a future pgvector switch needs no DB change.

List the live tables anytime:
```bash
kubectl run pg-tables --rm -i --restart=Never \
  --image=mirror.gcr.io/postgres:15.12-alpine3.20 \
  --env=PGPASSWORD="$(kubectl get secret fredlab-infra-secrets -o jsonpath='{.data.POSTGRES_FRED_PASSWORD}' | base64 -d)" \
  -- psql -h postgres -U fred -d fred -c "\dt"
```

---

## 2. OpenSearch — one `opensearch` StatefulSet, cluster `fredlab-opensearch`, port 9200

Security plugin **disabled** (in-cluster only, plain HTTP, no real auth). Not exposed
via Ingress.

| Index | Created by | Contents |
| --- | --- | --- |
| `knowledge-flow-vectors` | Knowledge Flow vector store | document chunks + embeddings; powers semantic/hybrid search |
| `kpi-index` | fred-core KPI writer | platform KPI events (fred-core default index) |
| `.opensearch-observability`, `.plugins-ml-config`, `top_queries-*` | OpenSearch itself | internal/system indices — not application data |

- `knowledge-flow-vectors` is configured by `knowledgeFlow.config.opensearch.vectorIndex`
  (values.yaml). **Embedding-model-bound:** its dimensions match the embedding model
  (`text-embedding-005`). If you change the embedding model, create a **new** index
  name — do not reuse this one.
- **Single-node note:** application indices show `yellow` because they default to
  `number_of_replicas: 1` and there is only one OpenSearch node, so the replica
  cannot be allocated. This is expected and harmless on the playground. To make them
  `green`, set replicas to 0 (e.g. an index template) — optional.

List the live indices anytime:
```bash
kubectl run os-indices --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
  -- curl -sS "http://opensearch:9200/_cat/indices?v"
```

---

## 3. Google Cloud Storage — region `europe-west9`, Workload Identity (no keys)

Created by `bin/fredlab-gcp-gcs-prereqs.sh`. GSA
`fredlab-knowledge-flow-gcs@fredlab-playground.iam.gserviceaccount.com` has
`roles/storage.objectAdmin` on all four.

| Bucket | Role | Contents |
| --- | --- | --- |
| `fredlab-playground-content-documents` | KF content store | ingested document trees (`<document_uid>/...`) |
| `fredlab-playground-content-objects` | KF content store | generic assets + tabular parquet (`tabular/datasets/...`) |
| `fredlab-playground-content-files` | KF content store | namespaced file store: templates, prompts, model artifacts |
| `fredlab-playground-knowledge-flow` | KF virtual filesystem (VFS) | unified `/teams/...` file tree agents read/write |

- Content store prefix: `fredlab-playground-content` → suffixed `-documents/-objects/-files`.
- VFS bucket: `fredlab-playground-knowledge-flow` (`filesystem.bucket_name`).

> Control Plane content storage is **not** GCS — it is `type: local`
> (`/tmp/control-plane-content`, ephemeral) and only holds team-banner images.

---

## 4. Quick "what is where" summary

- Identity/authz/workflow relational data → PostgreSQL (`keycloak`, `openfga`, `temporal*`).
- Control Plane + KF catalog (metadata/tags/resources) → PostgreSQL `fred`.
- Vector / hybrid search → OpenSearch `knowledge-flow-vectors`.
- Documents, objects, tabular, file store → GCS content buckets.
- Agent/team virtual filesystem → GCS VFS bucket.
- KF logs → in-memory (not persisted). KF KPIs → Prometheus.
