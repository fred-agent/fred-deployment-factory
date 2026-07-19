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

Two services share the `fred` database. Each owns distinct tables and its OWN
Alembic version table, so they never collide:

| App | Alembic version table | Tables owned |
| --- | --- | --- |
| Control Plane | `alembic_version_control_plane` | `users`, `session`, `session_attachments`, `session_context_prompts`, `session_metadata`, `session_purge_queue`, `prompt`, `default_prompt_usage`, `agent_instance`, `teammetadata`, `task_run`, `task_event_log` |
| Knowledge Flow | `alembic_version_knowledge_flow` | `metadata`, `tag`, `resource`, `sched_workflow_tasks` |

**Both apps create their tables with `alembic upgrade head`** (their migration
jobs). KF also auto-creates a few shared tables on app startup, so the order
**must be migrate → start**: migrate creates everything, then the app startup
auto-create is a no-op. Starting before migrating leaves a partial schema and a
"relation already exists" error on the next migrate (recover by dropping KF's
four tables + `alembic_version_knowledge_flow`, then re-migrating).

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

**Required, no safe default:** `content_storage.signing_service_account_email` — the SA that
signs V4 URLs (IAM `signBlob` on itself, granted by the prereq script) for tabular Parquet
reads. Empty (and its fallback `serviceAccount.gcpServiceAccount` also empty) crashes
`knowledge-flow-backend` at startup — this took the platform down for 2+ hours on 2026-07-18,
because it was unset in `gcp-c1/helm`'s copy of the secrets values while
`gcp-c1/argocd/fred-apps`' copy had it set correctly, and a routine Foundation deploy
overwrote the correct live ConfigMap with the broken one. Same story for
`knowledgeFlow.config.models.project` (Vertex AI) — no safe default, same incident, same
fix. See `docs/DEPLOYMENT-GUIDE.md` §4 for the full story and how to check for it.

---

## 4. Quick "what is where" summary

- Identity/authz/workflow relational data → PostgreSQL (`keycloak`, `openfga`, `temporal*`).
- Control Plane + KF catalog (metadata/tags/resources) → PostgreSQL `fred`.
- Vector / hybrid search → OpenSearch `knowledge-flow-vectors`.
- Documents, objects, tabular, file store → GCS content buckets.
- Agent/team virtual filesystem → GCS VFS bucket.
- KF logs → in-memory (not persisted). KF KPIs → in-cluster GMP query frontend
  (`gmpFrontend`, stateless — no PVC, proxies Cloud Monitoring).
- Grafana dashboard/user state (not business data) → its own 5Gi PVC
  (`grafana-data`, `standard-rwo`), the only other PVC besides `opensearch`/`postgres`.
- Grafana's "Resources & FinOps" dashboard (`gcp-c1/helm/files/grafana-dashboards/
  resource-finops.json`, file-provisioned — `allowUiUpdates: true`, so a UI edit
  persists until the next file sync re-applies this source of truth, not a hard
  read-only lock) reads storage size directly from each store, no separate
  size-tracking system: PostgreSQL via `pg_database_size()` (read-only role
  `grafana_readonly` — CONNECT + `pg_read_all_stats` only, no table access), GCS via
  Cloud Monitoring's own `storage.googleapis.com/storage/total_bytes` metric,
  OpenSearch via its own `_cat/indices` / `_cluster/stats` HTTP API (through
  Grafana's Infinity datasource plugin — no exporter, no extra Deployment).
  **Gotcha:** every Cloud Monitoring panel target must set `projectName` explicitly
  inside `timeSeriesList` — Grafana 11.1.4's `stackdriver` plugin frontend doesn't
  reliably fall back to the datasource's `jsonData.defaultProject`, and a panel
  missing it silently never fires a query at all (no error, no request). See
  `docs/DEPLOYMENT-GUIDE.md` §4 for the diagnostic trail if this resurfaces.
