package main

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

const (
	testUserID = "11111111-1111-4111-8111-111111111111"
	testTeamID = "22222222-2222-4222-8222-222222222222"
)

func TestAuditAcceptsConsistentInputs(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	if result.Status != statusPass {
		t.Fatalf("expected PASS, got %s with findings: %#v", result.Status, result.Findings)
	}
	if result.ErrorCount != 0 {
		t.Fatalf("expected no errors, got %d", result.ErrorCount)
	}
	if result.Summary.AgentsMapped != 1 || result.Summary.TeamsReferenced != 1 {
		t.Fatalf("unexpected summary: %#v", result.Summary)
	}
	if result.Summary.DocumentsFullyTagLinked != 1 ||
		result.Summary.DocumentsPartiallyTagLinked != 0 ||
		result.Summary.DocumentsWithoutKnownTag != 0 ||
		result.Summary.DocumentsWithReplayableParent != 1 ||
		result.Summary.DocumentsWithoutReplayableParent != 0 {
		t.Fatalf("unexpected document-link summary: %#v", result.Summary)
	}
}

func TestAuditRejectsUnknownMembershipGroup(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{membership: "/unknown-team"})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	assertFinding(t, result, "UNKNOWN_MEMBERSHIP_GROUP")
}

func TestAuditRejectsTupleCountMismatch(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{manifestTupleCount: intPointer(99)})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	assertFinding(t, result, "TUPLE_COUNT_MISMATCH")
}

func TestAuditRejectsEmptyOpenFGAForCollaborativeGroups(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{emptyTuples: true})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	assertFinding(t, result, "EMPTY_OPENFGA")
}

func TestAuditRejectsAgentMappingGap(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{agentTemplate: "unknown.template"})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	assertFinding(t, result, "AGENT_MAPPING_GAP")
}

func TestAuditAcceptsLegacyBasicReActAgentMapping(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{
		agentTemplate: "agentic_backend.core.agents.basic_react_agent.BasicReActAgent",
	})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	if result.Status != statusPass {
		t.Fatalf("expected PASS, got %s with findings: %#v", result.Status, result.Findings)
	}
	if result.Summary.AgentsMapped != 1 || result.Summary.AgentGaps != 0 {
		t.Fatalf("legacy BasicReActAgent should be mapped: %#v", result.Summary)
	}
}

func TestAuditAcceptsUndeclaredEmptyJSONLFile(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{undeclaredEmptyTable: true})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	if result.Status != statusPass {
		t.Fatalf("expected PASS, got %s with findings: %#v", result.Status, result.Findings)
	}
}

func TestAuditReportsPartialDocumentLinksAndUniqueMissingTags(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{
		documentTags: []string{"tag-one", "missing-tag", "missing-tag"},
	})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	finding := requireFinding(t, result, "UNKNOWN_DOCUMENT_TAG")
	if finding.Count != 2 || finding.Distinct != 1 {
		t.Fatalf("expected 2 references to 1 missing tag, got %#v", finding)
	}
	if result.Summary.DocumentsPartiallyTagLinked != 1 ||
		result.Summary.DocumentsFullyTagLinked != 0 ||
		result.Summary.DocumentsWithoutKnownTag != 0 ||
		result.Summary.MissingDocumentTagReferences != 2 ||
		result.Summary.MissingDocumentTagIDs != 1 {
		t.Fatalf("unexpected document-link summary: %#v", result.Summary)
	}
}

func TestAuditRejectsDocumentWithoutReplayableParentRelation(t *testing.T) {
	t.Parallel()
	zipPath, realmPath := writeFixture(t, fixtureOptions{omitDocumentParent: true})

	result, err := Audit(zipPath, realmPath)
	if err != nil {
		t.Fatalf("Audit returned an operational error: %v", err)
	}
	finding := requireFinding(t, result, "DOCUMENT_WITHOUT_REPLAYABLE_PARENT")
	if finding.Count != 1 || finding.Distinct != 1 {
		t.Fatalf("expected one document without a parent relation, got %#v", finding)
	}
	if result.Summary.DocumentsFullyTagLinked != 1 ||
		result.Summary.DocumentsWithReplayableParent != 0 ||
		result.Summary.DocumentsWithoutReplayableParent != 1 {
		t.Fatalf("unexpected document authorization summary: %#v", result.Summary)
	}
}

func TestFindingsAggregateRepeatedErrorsWithoutHidingLaterCodes(t *testing.T) {
	t.Parallel()
	result := AuditResult{}
	for index := range 145 {
		result.error("REPEATED_ERROR", "problem on item %d", index)
	}
	result.error("LATE_ERROR", "this category must remain visible")
	result.warn("LATE_WARNING", "warnings must remain visible too")
	result.finalizeFindings()

	repeated := requireFinding(t, result, "REPEATED_ERROR")
	if repeated.Count != 145 {
		t.Fatalf("expected 145 repeated errors, got %#v", repeated)
	}
	if len(repeated.Examples) != maxFindingExamples {
		t.Fatalf("expected %d bounded examples, got %#v", maxFindingExamples, repeated)
	}
	requireFinding(t, result, "LATE_ERROR")
	requireFinding(t, result, "LATE_WARNING")
	if result.ErrorCount != 146 || result.WarningCount != 1 {
		t.Fatalf(
			"unexpected occurrence totals: errors=%d warnings=%d",
			result.ErrorCount,
			result.WarningCount,
		)
	}
}

func TestAgentGapBreakdownCountsInstancesPerTemplate(t *testing.T) {
	t.Parallel()
	result := AuditResult{}
	result.addFindingBreakdown(
		severityError,
		"AGENT_MAPPING_GAP",
		`unmapped template "agentic_backend.core.agents.basic_react_agent.BasicReActAgent"`,
		145,
		[]string{"agent-a", "agent-b", "agent-c"},
	)
	result.addFindingBreakdown(
		severityError,
		"AGENT_MAPPING_GAP",
		`unmapped template "legacy.SpecialAgent"`,
		2,
		[]string{"special-a", "special-b"},
	)
	result.finalizeFindings()

	finding := requireFinding(t, result, "AGENT_MAPPING_GAP")
	if finding.Count != 147 || result.ErrorCount != 147 {
		t.Fatalf("expected 147 agent gaps, got %#v", finding)
	}
	if len(finding.Breakdown) != 2 {
		t.Fatalf("expected one breakdown per template, got %#v", finding.Breakdown)
	}
	if finding.Breakdown[0].Count != 145 ||
		finding.Breakdown[0].Label !=
			`unmapped template "agentic_backend.core.agents.basic_react_agent.BasicReActAgent"` {
		t.Fatalf("largest template should be reported first, got %#v", finding.Breakdown)
	}
}

type fixtureOptions struct {
	agentTemplate        string
	membership           string
	manifestTupleCount   *int
	emptyTuples          bool
	undeclaredEmptyTable bool
	documentTags         []string
	omitDocumentParent   bool
}

func writeFixture(t *testing.T, options fixtureOptions) (string, string) {
	t.Helper()
	tempDir := t.TempDir()
	zipPath := filepath.Join(tempDir, "kea.zip")
	realmPath := filepath.Join(tempDir, "reconciliation.json")

	membership := options.membership
	if membership == "" {
		membership = "/team-one"
	}
	template := options.agentTemplate
	if template == "" {
		template = "v2.react.basic"
	}

	realm := map[string]any{
		"groups": []map[string]any{{
			"id":        testTeamID,
			"name":      "team-one",
			"subGroups": []any{},
		}},
		"users": []map[string]any{{
			"id":         testUserID,
			"username":   "alice",
			"groups":     []string{membership},
			"realmRoles": []string{"admin", "viewer"},
		}},
	}
	realmBytes, err := json.Marshal(realm)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(realmPath, realmBytes, 0o600); err != nil {
		t.Fatal(err)
	}

	tuples := []tuple{
		{User: "organization:fred", Relation: "organization", Object: "team:" + testTeamID},
		{User: "user:" + testUserID, Relation: "owner", Object: "team:" + testTeamID},
		{User: "user:" + testUserID, Relation: "owner", Object: "agent:agent-one"},
		{User: "team:" + testTeamID, Relation: "owner", Object: "tag:tag-one"},
		{User: "tag:tag-one", Relation: "parent", Object: "document:doc-one"},
	}
	if options.omitDocumentParent {
		tuples = tuples[:len(tuples)-1]
	}
	if options.emptyTuples {
		tuples = []tuple{}
	}
	tupleCount := len(tuples)
	if options.manifestTupleCount != nil {
		tupleCount = *options.manifestTupleCount
	}
	manifest := map[string]any{
		"format_version":  1,
		"source_platform": "kea",
		"created_at":      "2026-07-28T00:00:00Z",
		"tables": map[string]int{
			"agent":    1,
			"tag":      1,
			"metadata": 1,
		},
		"tuple_count":    tupleCount,
		"realm_exported": false,
		"content_keys":   []string{},
	}
	agent := map[string]any{
		"id":   "agent-one",
		"name": "Agent One",
		"payload_json": map[string]any{
			"id":             "agent-one",
			"name":           "Agent One",
			"type":           "agent",
			"definition_ref": template,
		},
		"created_by": testUserID,
	}
	tag := map[string]any{
		"tag_id":   "tag-one",
		"owner_id": testTeamID,
		"name":     "Team corpus",
		"type":     "document",
	}
	documentTags := options.documentTags
	if documentTags == nil {
		documentTags = []string{"tag-one"}
	}
	document := map[string]any{
		"document_uid": "doc-one",
		"tag_ids":      documentTags,
	}

	entries := map[string][]byte{
		"manifest.json":           mustJSON(t, manifest),
		"postgres/agent.jsonl":    append(mustJSON(t, agent), '\n'),
		"postgres/tag.jsonl":      append(mustJSON(t, tag), '\n'),
		"postgres/metadata.jsonl": append(mustJSON(t, document), '\n'),
		"openfga/tuples.json":     mustJSON(t, tuples),
	}
	if options.undeclaredEmptyTable {
		entries["postgres/teammetadata.jsonl"] = []byte{}
	}
	writeZip(t, zipPath, entries)
	return zipPath, realmPath
}

func writeZip(t *testing.T, zipPath string, entries map[string][]byte) {
	t.Helper()
	file, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, data := range entries {
		entry, createErr := writer.Create(name)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if _, writeErr := entry.Write(data); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func assertFinding(t *testing.T, result AuditResult, code string) {
	t.Helper()
	requireFinding(t, result, code)
	if result.Status != statusFail {
		t.Fatalf("finding %s should make the result fail", code)
	}
}

func requireFinding(t *testing.T, result AuditResult, code string) Finding {
	t.Helper()
	for _, finding := range result.Findings {
		if finding.Code == code {
			return finding
		}
	}
	t.Fatalf("finding %s not found in %#v", code, result.Findings)
	return Finding{}
}

func intPointer(value int) *int {
	return &value
}
