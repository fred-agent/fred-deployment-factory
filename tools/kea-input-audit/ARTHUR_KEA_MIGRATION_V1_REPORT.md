# Kea → Swift — Arthur migration V1 record

**Date:** 2026-07-28  
**Status:** V1 inputs frozen for a controlled Swift migration test  
**Audience:** internal migration operators  
**Data handling:** internal operational metadata; do not publish externally

## 1. Decision

The ZIP snapshot and SQL-extracted reconciliation JSON listed below are frozen
as **Arthur V1**. Their identity is defined by SHA-256, not by filename.

The V1 audit is intentionally **not green**. The known source inconsistencies
documented below are accepted for the controlled Swift migration test planned
for the afternoon of 2026-07-28. This acceptance does not hide or reclassify
them, and it is not by itself a final production go-live approval.

The objectives of the test are:

1. prove that the main Kea population migrates with the expected counts;
2. prove that every accepted exclusion is explicitly reported by Swift;
3. validate one real user's teams, agents and usable corpus end to end;
4. capture enough evidence for a factual post-test report.

Do not regenerate a file under the V1 name. A different hash is a new version
and requires a new audit.

## 2. Frozen V1 artifacts

| Artifact | Frozen filename | SHA-256 |
|---|---|---|
| Kea snapshot | `kea-snapshot-arthur.zip` | `4797fb14289b08226608262019403aece6714e99ee020eab515783b3e6c09b91` |
| Reconciliation JSON | `kea-realm-reconciliation.json` | `cba2cca23bd91759fd7987376335d1be25c76b87c2800116147ee3e013435e99` |
| Auditor Linux amd64 | `kea-input-audit-linux-amd64` (`0.3.0`) | `eec13b60d57793c9c5e83ee499cccb18fd6cd420f0ce3439c923d11f8c56fe5b` |
| SQL extraction script | `extract-kea-reconciliation.sh` | `c27084607d2b75c0e7d4823d30faa784a07be66a40e15a1e12ec51981d6639d6` |

Before any dry-run:

```bash
sha256sum --check ARTHUR_KEA_MIGRATION_V1_CHECKSUMS.sha256
./kea-input-audit-linux-amd64 --version
./kea-input-audit-linux-amd64 \
  kea-snapshot-arthur.zip \
  kea-realm-reconciliation.json
```

Expected auditor version: `kea-input-audit 0.3.0`.

## 3. Source inventory observed

| Area | V1 count |
|---|---:|
| Keycloak groups | 99 |
| Human users | 2,008 |
| Group memberships | 3,095 |
| Source platform admins | 8 |
| Source platform viewers | 1 |
| OpenFGA tuples | 16,344 |
| Team identifiers referenced | 104 |
| Tag rows | 1,363 |
| Document metadata rows | 10,475 |
| Resource rows | 53 |
| Agents mapped to Swift templates | 1,647 |
| Unsupported agent instances | 22 |

The reconciliation JSON contains local Kea Keycloak user ids and usernames.
OneAccess/federated identity ids do not replace those local ids in this file.

## 4. Documents and corpus

Out of 10,475 document metadata rows:

| Classification | Count | Decision for V1 |
|---|---:|---|
| Every declared tag exists and a usable `tag --parent--> document` relation can be restored through an imported tag | **10,410** | Expected usable population |
| At least one present and one missing tag | 0 | None |
| No declared tag exists in the tag table | **65** | Known source orphan; accepted for the controlled test |
| Invalid `tag_ids` shape | 0 | None |

Therefore 99.38% of document metadata is structurally connected to an imported
corpus, while 0.62% is associated only with missing tags.

The 65 orphan documents reference nine missing tag ids:

| Missing tag id | Documents |
|---|---:|
| `ffd0972d-8840-4cd7-87f5-26618978b8bc` | 33 |
| `6c9bc53d-226b-4971-ad0e-1551d2d3e11b` | 20 |
| `b71b8559-a6f8-4996-95d2-db965d69320c` | 6 |
| `36153c9c-6773-47ab-95df-f612b3e0d080` | 1 |
| `a376e0fa-454f-4828-a23b-c208bf3f8b71` | 1 |
| `a3b8ad10-5a16-4f20-857a-811ad117a84f` | 1 |
| `c2470535-1322-42e2-a8c4-cfc03f081a89` | 1 |
| `d279ba67-4ccd-4ae8-9b83-dacb63852794` | 1 |
| `e2768981-757f-488b-abe5-916e445622c0` | 1 |

The V1 decision is to preserve the evidence and continue the controlled test,
not to claim that these 65 documents are usable. They may still exist in GCS,
OpenSearch and imported document metadata, but without a corresponding imported
tag row they are not expected to appear as a usable corpus in Swift.

A later cleanup must choose explicitly between:

- recovering/reconstructing the nine missing tag rows and their ownership; or
- accepting the 65 documents as already-orphaned legacy data and excluding
  them from the final cutover population.

## 5. Agent migration

The legacy generic agent mapping is confirmed:

```text
agentic_backend.core.agents.basic_react_agent.BasicReActAgent
    → fred-agents:fred.github.assistant
```

This moved 129 instances from GAP to MAPPED:

| Result | Count |
|---|---:|
| Mapped agent rows | 1,647 |
| Unsupported agent rows | 22 |
| Mapped rows without an owner tuple | 50 |
| OpenFGA agent ids with no corresponding agent row | 292 |

The 22 unsupported instances are accepted exclusions for V1. They must be
skipped deliberately and remain visible in the Swift dry-run and final import
report; they must not be presented as migrated.

| Unsupported Kea template | Instances |
|---|---:|
| `agentic_backend.agents.v1.production.contrib.ppt_filler.ppt_filler_agent.PptFillerAgent` | 5 |
| `agentic_backend.agents.v1.production.aegis.aegis_rag_expert.Aegis` | 2 |
| `agentic_backend.agents.v1.production.contrib.bid_and_capture.tempo.Tempo` | 2 |
| `agentic_backend.agents.v1.production.rags.archie.Archie` | 2 |
| Missing `definition_ref`/`class_path` (`__static_seeded__`) | 1 |
| `agentic_backend.agents.coach_dg.coach_dg.CoachDG` | 1 |
| `agentic_backend.agents.generalist.generalist_expert.Georges` | 1 |
| `agentic_backend.agents.knowledge_extractor.slide_maker.SlideMaker` | 1 |
| `agentic_backend.agents.rags.advanced_rag_expert.AdvancedRico` | 1 |
| `agentic_backend.agents.rags.rag_expert.Rico` | 1 |
| `agentic_backend.agents.reference_editor.reference_editor.ReferenceEditor` | 1 |
| `agentic_backend.agents.tabular.tabular_expert.Tessa` | 1 |
| `agentic_backend.agents.v1.production.contrib.bid_and_capture.bid_mgr.bid_mgr.BidMgr` | 1 |
| `agentic_backend.agents.v1.production.contrib.jira.jira_agent.JiraAgent` | 1 |
| `v2.production.expense_analyst` | 1 |

The 50 mapped agents without ownership require observation during the test.
Swift currently reports and skips them. Some have UUID display names and must
not all be assumed to be harmless catalog definitions without further evidence.

The 292 missing agent ids are tuple-only legacy residue: each has one OpenFGA
reference but no agent row to import.

## 6. Teams and governance

Four real source teams have no resolvable owner and would have no Swift
`team_admin`:

| Team | Source id |
|---|---|
| `RH CIS` | `fa8f5dfd-166c-4e00-965a-d4c079010ca1` |
| `Private Wissem` | `3bdcaffa-42c8-4af9-880c-a7eb0668c5f5` |
| `Admin Prism` | `54884839-db0f-4ef3-be19-b2ef4fc60f8b` |
| `RAGS` | `c091bfb1-6e39-4f66-b852-f8c1221cf1be` |

Their presence is accepted for the controlled V1 test, but the import must
continue to report them. Before relying on these teams operationally, an
administrator must be assigned or the team must be explicitly retired.

Five team identifiers referenced by OpenFGA are absent from Keycloak groups:

| Missing team id | Tuple references | Initial classification |
|---|---:|---|
| `a9d0e552-e522-4675-8ea8-54304fc94747` | 2 | deleted/stale candidate; verify |
| `undefined` | 2 | malformed legacy residue |
| `0bbeeb13-a6f6-4992-9398-81e17983c575` | 1 | deleted/stale candidate; verify |
| `personnal` | 1 | malformed legacy residue |
| `toto` | 1 | test/legacy residue |

The Swift Kea reconciliation path is expected to drop teams absent from the
reconciliation group set and report them as orphan teams.

## 7. Other accepted source inconsistencies

| Finding | Count | V1 handling |
|---|---:|---|
| Missing tag ids referenced by OpenFGA | 692 ids / 1,216 references | Preserve report; do not mistake tuple-only ids for imported tag rows |
| Tag with `owner_id = "undefined"` | 1 (`be142cca-abb4-4f6a-9dd5-73c32766cb9a`) | Inspect impact; do not treat as a valid owner |
| Shared personal-team tuple | 1 | Intentionally dropped by Swift |
| Resource-parent tuples | 41 | Intentionally dropped when chat contexts become prompts |
| OpenFGA user absent from reconciliation | 1 (`86cd2298-4199-479f-bc18-65269a7bc998`) | Confirm that it is a service account |

OpenFGA does not require an application object row to exist. Consequently,
known-shape tuples referencing missing agents or tags may remain technically
writable but are stale authorization data. Their presence must not be counted
as successful migration of the missing application objects.

## 8. Expected Swift dry-run baseline

The dry-run must be retained as JSON evidence. With a Swift image containing
the confirmed legacy `BasicReActAgent` mapping, the expected baseline is:

| Dry-run observation | Expected V1 value |
|---|---:|
| `agents_mapped` | 1,647 |
| `agents_gap` | 22 |
| Distinct gap templates/reasons | 15 |
| Teams retained after orphan filtering | 99 |
| Orphan team ids dropped | 5 |
| Admin-less retained teams | 4 |

Identity outcomes (`matched`, `relinked`, `pending`) depend on the users already
present in the target Swift Keycloak and cannot be predicted from the source
files alone.

Stop before the real import if:

- either V1 input hash differs;
- `BasicReActAgent` still appears as a GAP;
- more than 22 agent gaps appear, or a new gap template appears;
- the five expected orphan teams or four admin-less teams differ;
- the dry-run contains a new warning category not documented here;
- the dry-run fails or returns an incomplete response.

## 9. Controlled migration test checklist

### Before import

- [ ] Record date, operator and target environment.
- [ ] Record deployed Swift image tags or commit SHA.
- [ ] Verify the two frozen V1 hashes.
- [ ] Run auditor `0.3.0` and archive its complete output.
- [ ] Run the Swift dry-run and archive its JSON response.
- [ ] Compare the dry-run with the V1 baseline above.
- [ ] Confirm that the target Swift state is the intended clean starting state.

### Real import

- [ ] Record start and end timestamps.
- [ ] Record the import task id and final task state.
- [ ] Archive the complete import report and warnings.
- [ ] Confirm that a failed request does not leave an unreported partial result.
- [ ] Do not rerun with modified inputs under the V1 label.

### Functional validation

- [ ] Record imported counts for teams, tags, documents, agents and relations.
- [ ] Confirm that the 22 unsupported agents are explicitly reported as skipped.
- [ ] Confirm how many of the 50 ownerless mapped agents are skipped.
- [ ] Confirm that the five orphan team ids are not created.
- [ ] Confirm that the four admin-less teams remain reported.
- [ ] Confirm that 10,410 document rows remain connected to an imported tag.
- [ ] Confirm that the 65 known orphan documents are not presented as a usable corpus.
- [ ] Create or connect one representative user.
- [ ] Validate that user's teams and roles after reconciliation.
- [ ] Validate that user's expected agents are visible.
- [ ] Validate that user's expected corpus and documents are visible.
- [ ] Run a real agent question that retrieves expected content from that corpus.
- [ ] Run the required corpus synchronization/index-state recovery step and
      confirm that usable documents reach the expected ready state.
- [ ] Check application and worker logs for unexpected migration errors.

## 10. Afternoon result — fill in after the test

| Field | Recorded result |
|---|---|
| Target environment | |
| Swift version/images | |
| Operators | |
| Test start/end | |
| V1 hashes verified | |
| Dry-run result | |
| Real import task id | |
| Real import terminal state | |
| Teams imported/dropped | |
| Users matched/relinked/pending | |
| Agents imported/skipped/gaps | |
| Tags imported/skipped | |
| Documents imported/usable/orphan | |
| OpenFGA relations restored/dropped | |
| Representative user | |
| Team visibility | |
| Agent visibility and execution | |
| Corpus visibility and retrieval | |
| Corpus synchronization result | |
| Unexpected warnings/errors | |
| Final verdict | `SUCCESS` / `PARTIAL` / `FAILED` |

## 11. Post-test conclusion template

> On 2026-07-28 we tested the frozen Arthur V1 Kea→Swift migration inputs,
> identified by ZIP SHA-256 `4797fb…` and reconciliation SHA-256 `cba2cc…`.
> The source baseline contained 2,008 users, 99 Keycloak groups, 10,475
> document metadata rows and 1,669 non-leader agent rows. Of the documents,
> 10,410 were connected to an imported tag and 65 were known legacy orphans
> associated with nine missing tags. Of the agents, 1,647 had a Swift mapping
> and 22 specialized legacy instances were accepted exclusions. The test
> result was **[SUCCESS/PARTIAL/FAILED]**. The observed target counts were
> **[fill in]**, and end-to-end validation with user **[fill in]**
> **[did/did not]** confirm teams, agents, corpus visibility and retrieval.
> Remaining actions: **[fill in]**.

Attach the full auditor output, Swift dry-run JSON, import report and functional
test evidence to the final account. Do not include the reconciliation JSON
itself in a broadly distributed report because it contains usernames and
stable identity identifiers.
