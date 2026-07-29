package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
)

const (
	statusPass = "PASS"
	statusFail = "FAIL"

	severityError   = "ERROR"
	severityWarning = "WARN"

	maxEntryBytes      = 512 << 20
	maxArchiveBytes    = 2 << 30
	maxJSONLineBytes   = 32 << 20
	maxFindingExamples = 10
	maxBreakdownItems  = 20
)

var uuidPattern = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
)

var mappedAgentTemplates = map[string]struct{}{
	"v2.react.basic":            {},
	"v2.production.sql_analyst": {},
	"agentic_backend.core.agents.basic_react_agent.BasicReActAgent":          {},
	"agentic_backend.agents.v1.production.prometheus.prometheus_expert.Spot": {},
	"agentic_backend.agents.v1.production.rags.rag_expert.Rico":              {},
	"agentic_backend.agents.v1.production.tabular.tabular_expert.Tessa":      {},
}

var ignoredAgentTemplates = map[string]struct{}{
	"v2.sample.bank_transfer":                {},
	"v2.deep.corpus_investigator":            {},
	"v2.production.dva_risk_validator.graph": {},
	"v2.production.dva_risk_validator.qa":    {},
}

var knownKeaTables = map[string]struct{}{
	"agent":        {},
	"metadata":     {},
	"mcp-server":   {},
	"resource":     {},
	"tag":          {},
	"teammetadata": {},
	"users":        {},
}

type Finding struct {
	Severity         string             `json:"severity"`
	Code             string             `json:"code"`
	Count            int                `json:"count"`
	Distinct         int                `json:"distinct,omitempty"`
	Examples         []string           `json:"examples,omitempty"`
	Breakdown        []FindingBreakdown `json:"breakdown,omitempty"`
	BreakdownOmitted int                `json:"breakdown_omitted,omitempty"`
}

type FindingBreakdown struct {
	Label    string   `json:"label"`
	Count    int      `json:"count"`
	Examples []string `json:"examples,omitempty"`
}

type InputFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type AuditSummary struct {
	SourcePlatform                   string         `json:"source_platform"`
	FormatVersion                    int            `json:"format_version"`
	TableRows                        map[string]int `json:"table_rows"`
	Groups                           int            `json:"groups"`
	Users                            int            `json:"users"`
	Memberships                      int            `json:"memberships"`
	PlatformAdmins                   int            `json:"platform_admins"`
	PlatformViewers                  int            `json:"platform_viewers"`
	Tuples                           int            `json:"tuples"`
	TeamsReferenced                  int            `json:"teams_referenced"`
	AgentsMapped                     int            `json:"agents_mapped"`
	AgentsIgnored                    int            `json:"agents_ignored"`
	AgentGaps                        int            `json:"agent_gaps"`
	Tags                             int            `json:"tags"`
	Documents                        int            `json:"documents"`
	DocumentsFullyTagLinked          int            `json:"documents_fully_tag_linked"`
	DocumentsPartiallyTagLinked      int            `json:"documents_partially_tag_linked"`
	DocumentsWithoutKnownTag         int            `json:"documents_without_known_tag"`
	DocumentsInvalidTagShape         int            `json:"documents_invalid_tag_shape"`
	DocumentsWithReplayableParent    int            `json:"documents_with_replayable_parent"`
	DocumentsWithoutReplayableParent int            `json:"documents_without_replayable_parent"`
	MissingDocumentTagIDs            int            `json:"missing_document_tag_ids"`
	MissingDocumentTagReferences     int            `json:"missing_document_tag_references"`
	Resources                        int            `json:"resources"`
	UnknownTupleAgentIDs             int            `json:"unknown_tuple_agent_ids"`
	UnknownTupleAgentReferences      int            `json:"unknown_tuple_agent_references"`
	UnknownTupleTagIDs               int            `json:"unknown_tuple_tag_ids"`
	UnknownTupleTagReferences        int            `json:"unknown_tuple_tag_references"`
	UnknownTupleTeamIDs              int            `json:"unknown_tuple_team_ids"`
	UnknownTupleTeamReferences       int            `json:"unknown_tuple_team_references"`
}

type AuditResult struct {
	Status         string       `json:"status"`
	ErrorCount     int          `json:"error_count"`
	WarningCount   int          `json:"warning_count"`
	Bundle         InputFile    `json:"bundle"`
	Reconciliation InputFile    `json:"reconciliation"`
	Summary        AuditSummary `json:"summary"`
	Findings       []Finding    `json:"findings"`

	findingAggregates map[string]*Finding
}

type manifest struct {
	FormatVersion      int            `json:"format_version"`
	UsersSchemaVersion *int           `json:"users_schema_version"`
	SourcePlatform     string         `json:"source_platform"`
	CreatedAt          string         `json:"created_at"`
	Tables             map[string]int `json:"tables"`
	TupleCount         int            `json:"tuple_count"`
	RealmExported      bool           `json:"realm_exported"`
	ContentKeys        []string       `json:"content_keys"`
}

type realmGroup struct {
	ID   string
	Name string
}

type realmUser struct {
	ID         string
	Username   string
	Groups     []string
	RealmRoles []string
}

type reconciliationData struct {
	Groups []realmGroup
	Users  []realmUser
}

type tuple struct {
	User     string `json:"user"`
	Relation string `json:"relation"`
	Object   string `json:"object"`
}

type bundleData struct {
	manifest manifest
	tables   map[string][]map[string]any
	tuples   []tuple
	entries  map[string]*zip.File
}

type occurrenceSummary struct {
	count    int
	examples []string
}

func (result *AuditResult) finding(severity, code string) *Finding {
	if result.findingAggregates == nil {
		result.findingAggregates = make(map[string]*Finding)
	}
	key := severity + "\x00" + code
	finding := result.findingAggregates[key]
	if finding == nil {
		finding = &Finding{Severity: severity, Code: code}
		result.findingAggregates[key] = finding
	}
	return finding
}

func (result *AuditResult) addFindingCount(
	severity string,
	code string,
	count int,
	message string,
) {
	if count <= 0 {
		return
	}
	if severity == severityError {
		result.ErrorCount += count
	} else {
		result.WarningCount += count
	}
	finding := result.finding(severity, code)
	finding.Count += count
	if message != "" && len(finding.Examples) < maxFindingExamples {
		for _, existing := range finding.Examples {
			if existing == message {
				return
			}
		}
		finding.Examples = append(finding.Examples, message)
	}
}

func (result *AuditResult) addFinding(severity, code, message string) {
	result.addFindingCount(severity, code, 1, message)
}

func (result *AuditResult) addFindingBreakdown(
	severity string,
	code string,
	label string,
	count int,
	examples []string,
) {
	result.addFindingCount(severity, code, count, "")
	finding := result.finding(severity, code)
	finding.Breakdown = append(finding.Breakdown, FindingBreakdown{
		Label:    label,
		Count:    count,
		Examples: examples,
	})
}

func (result *AuditResult) addOccurrenceBreakdowns(
	severity string,
	code string,
	label string,
	occurrences map[string]*occurrenceSummary,
) {
	if len(occurrences) == 0 {
		return
	}
	total := 0
	for _, occurrence := range occurrences {
		total += occurrence.count
	}
	result.addFindingCount(severity, code, total, "")
	finding := result.finding(severity, code)
	finding.Distinct = len(occurrences)

	identifiers := make([]string, 0, len(occurrences))
	for identifier := range occurrences {
		identifiers = append(identifiers, identifier)
	}
	sort.Slice(identifiers, func(i, j int) bool {
		left := occurrences[identifiers[i]].count
		right := occurrences[identifiers[j]].count
		if left != right {
			return left > right
		}
		return identifiers[i] < identifiers[j]
	})
	limit := min(len(identifiers), maxBreakdownItems)
	for _, identifier := range identifiers[:limit] {
		occurrence := occurrences[identifier]
		finding.Breakdown = append(finding.Breakdown, FindingBreakdown{
			Label:    fmt.Sprintf("%s %q", label, identifier),
			Count:    occurrence.count,
			Examples: occurrence.examples,
		})
	}
	finding.BreakdownOmitted = len(identifiers) - limit
}

func (result *AuditResult) error(code, format string, args ...any) {
	result.addFinding(severityError, code, fmt.Sprintf(format, args...))
}

func (result *AuditResult) warn(code, format string, args ...any) {
	result.addFinding(severityWarning, code, fmt.Sprintf(format, args...))
}

func (result *AuditResult) finalizeFindings() {
	result.Findings = make([]Finding, 0, len(result.findingAggregates))
	for _, finding := range result.findingAggregates {
		if finding.Distinct == 0 && len(finding.Breakdown) > 0 {
			finding.Distinct = len(finding.Breakdown)
		}
		sort.Slice(finding.Breakdown, func(i, j int) bool {
			if finding.Breakdown[i].Count != finding.Breakdown[j].Count {
				return finding.Breakdown[i].Count > finding.Breakdown[j].Count
			}
			return finding.Breakdown[i].Label < finding.Breakdown[j].Label
		})
		result.Findings = append(result.Findings, *finding)
	}
	sort.Slice(result.Findings, func(i, j int) bool {
		if result.Findings[i].Severity != result.Findings[j].Severity {
			return result.Findings[i].Severity == severityError
		}
		return result.Findings[i].Code < result.Findings[j].Code
	})
}

// Audit validates the immutable Kea ZIP and reconciliation JSON together.
// It performs source-side structural and referential checks only; the Swift
// dry-run remains authoritative for live target identity/template resolution.
func Audit(zipPath, reconciliationPath string) (AuditResult, error) {
	result := AuditResult{Status: statusPass}
	if err := checkReadableRegularFile(zipPath); err != nil {
		return result, fmt.Errorf("bundle %q: %w", zipPath, err)
	}
	if err := checkReadableRegularFile(reconciliationPath); err != nil {
		return result, fmt.Errorf("reconciliation file %q: %w", reconciliationPath, err)
	}

	bundleInput, err := inspectInputFile(zipPath)
	if err != nil {
		return result, fmt.Errorf("hash bundle: %w", err)
	}
	reconciliationInput, err := inspectInputFile(reconciliationPath)
	if err != nil {
		return result, fmt.Errorf("hash reconciliation file: %w", err)
	}
	result.Bundle = bundleInput
	result.Reconciliation = reconciliationInput

	realm, err := loadReconciliation(reconciliationPath, &result)
	if err != nil {
		result.error("RECONCILIATION_JSON", "%v", err)
	}

	bundle, bundleErr := loadBundle(zipPath, &result)
	if bundleErr != nil {
		result.error("BUNDLE_ZIP", "%v", bundleErr)
	}

	if err == nil && bundleErr == nil {
		crossValidate(bundle, realm, &result)
	}

	if result.ErrorCount > 0 {
		result.Status = statusFail
	}
	result.finalizeFindings()
	return result, nil
}

func inspectInputFile(filePath string) (InputFile, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return InputFile{}, err
	}
	defer file.Close()

	hasher := sha256.New()
	size, err := io.Copy(hasher, file)
	if err != nil {
		return InputFile{}, err
	}
	return InputFile{
		Path:   filePath,
		SHA256: hex.EncodeToString(hasher.Sum(nil)),
		Bytes:  size,
	}, nil
}

func loadReconciliation(
	filePath string,
	result *AuditResult,
) (reconciliationData, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return reconciliationData{}, err
	}
	var root map[string]json.RawMessage
	if err := decodeOneJSON(data, &root); err != nil {
		return reconciliationData{}, fmt.Errorf("invalid JSON: %w", err)
	}

	keys := sortedKeys(root)
	if len(keys) != 2 || keys[0] != "groups" || keys[1] != "users" {
		result.error(
			"RECONCILIATION_ROOT_KEYS",
			"root keys must be exactly [groups users], got %v",
			keys,
		)
	}

	groupRaw, groupsPresent := root["groups"]
	userRaw, usersPresent := root["users"]
	if !groupsPresent || !usersPresent {
		return reconciliationData{}, fmt.Errorf("both non-empty groups and users arrays are required")
	}

	var rawGroups []json.RawMessage
	if err := json.Unmarshal(groupRaw, &rawGroups); err != nil {
		return reconciliationData{}, fmt.Errorf("groups must be an array: %w", err)
	}
	var rawUsers []json.RawMessage
	if err := json.Unmarshal(userRaw, &rawUsers); err != nil {
		return reconciliationData{}, fmt.Errorf("users must be an array: %w", err)
	}
	if len(rawGroups) == 0 {
		result.error("EMPTY_GROUPS", "groups must be a non-empty array")
	}
	if len(rawUsers) == 0 {
		result.error("EMPTY_USERS", "users must be a non-empty array")
	}

	realm := reconciliationData{
		Groups: make([]realmGroup, 0, len(rawGroups)),
		Users:  make([]realmUser, 0, len(rawUsers)),
	}
	groupIDs := make(map[string]int)
	groupNames := make(map[string]int)

	for index, raw := range rawGroups {
		object, objectErr := decodeRawObject(raw)
		if objectErr != nil {
			result.error("GROUP_SHAPE", "groups[%d]: %v", index, objectErr)
			continue
		}
		id, idOK := requiredString(object, "id")
		name, nameOK := requiredString(object, "name")
		if !idOK || strings.TrimSpace(id) == "" {
			result.error("GROUP_ID", "groups[%d].id must be a non-empty string", index)
		}
		if !nameOK || strings.TrimSpace(name) == "" {
			result.error("GROUP_NAME", "groups[%d].name must be a non-empty string", index)
		}
		if id != "" && !uuidPattern.MatchString(id) {
			result.error("GROUP_ID_FORMAT", "groups[%d].id %q is not a UUID", index, id)
		}
		if name != strings.TrimSpace(name) {
			result.error("GROUP_NAME_WHITESPACE", "groups[%d].name has leading/trailing whitespace", index)
		}

		subGroups, present, arrayErr := rawArrayField(object, "subGroups")
		if arrayErr != nil || !present {
			result.error("GROUP_SUBGROUPS", "groups[%d].subGroups must be an array", index)
		} else if len(subGroups) != 0 {
			result.error(
				"NESTED_GROUP",
				"groups[%d] %q has %d subGroups; Kea teams must be root groups",
				index,
				name,
				len(subGroups),
			)
		}
		if id == "personal" || name == "personal" {
			result.error(
				"PERSONAL_GROUP",
				"groups[%d] represents the Kea personal pseudo-team, which must not be exported",
				index,
			)
		}
		if id != "" {
			groupIDs[id]++
		}
		if name != "" {
			groupNames[name]++
		}
		realm.Groups = append(realm.Groups, realmGroup{ID: id, Name: name})
	}

	reportDuplicates(groupIDs, "DUPLICATE_GROUP_ID", "group id", result)
	reportDuplicates(groupNames, "DUPLICATE_GROUP_NAME", "group name", result)

	userIDs := make(map[string]int)
	usernames := make(map[string]int)
	knownGroupNames := make(map[string]struct{}, len(realm.Groups))
	for _, group := range realm.Groups {
		knownGroupNames[group.Name] = struct{}{}
	}

	for index, raw := range rawUsers {
		object, objectErr := decodeRawObject(raw)
		if objectErr != nil {
			result.error("USER_SHAPE", "users[%d]: %v", index, objectErr)
			continue
		}
		id, idOK := requiredString(object, "id")
		username, usernameOK := requiredString(object, "username")
		if !idOK || strings.TrimSpace(id) == "" {
			result.error("USER_ID", "users[%d].id must be a non-empty string", index)
		}
		if !usernameOK || strings.TrimSpace(username) == "" {
			result.error("USERNAME", "users[%d].username must be a non-empty string", index)
		}
		if id != "" && !uuidPattern.MatchString(id) {
			result.error("USER_ID_FORMAT", "users[%d].id %q is not a UUID", index, id)
		}
		if username != strings.TrimSpace(username) {
			result.error("USERNAME_WHITESPACE", "users[%d].username has leading/trailing whitespace", index)
		}
		if strings.HasPrefix(username, "service-account-") {
			result.warn(
				"SERVICE_ACCOUNT",
				"users[%d] %q looks like a Keycloak service account; the canonical SQL excludes service accounts",
				index,
				username,
			)
		}

		groups, groupsOK := requiredStringArray(object, "groups")
		if !groupsOK {
			result.error("USER_GROUPS", "users[%d].groups must be an array of strings", index)
		}
		roles, rolesOK := requiredStringArray(object, "realmRoles")
		if !rolesOK {
			result.error("USER_REALM_ROLES", "users[%d].realmRoles must be an array of strings", index)
		}

		normalizedMemberships := make(map[string]int)
		for _, groupPath := range groups {
			normalized := strings.TrimPrefix(groupPath, "/")
			normalizedMemberships[normalized]++
			if normalized == "" || normalized != strings.TrimSpace(normalized) {
				result.error(
					"MEMBERSHIP_FORMAT",
					"user %q has invalid group path %q",
					username,
					groupPath,
				)
				continue
			}
			if _, known := knownGroupNames[normalized]; !known {
				result.error(
					"UNKNOWN_MEMBERSHIP_GROUP",
					"user %q references unknown group %q",
					username,
					groupPath,
				)
			}
		}
		reportDuplicates(
			normalizedMemberships,
			"DUPLICATE_MEMBERSHIP",
			fmt.Sprintf("membership for user %q", username),
			result,
		)

		roleCounts := make(map[string]int)
		for _, role := range roles {
			roleCounts[role]++
			switch role {
			case "admin":
				result.Summary.PlatformAdmins++
			case "viewer":
				result.Summary.PlatformViewers++
			case "editor":
			default:
				result.error(
					"UNKNOWN_PLATFORM_ROLE",
					"user %q has unsupported realm role %q",
					username,
					role,
				)
			}
		}
		reportDuplicates(
			roleCounts,
			"DUPLICATE_PLATFORM_ROLE",
			fmt.Sprintf("realm role for user %q", username),
			result,
		)

		if id != "" {
			userIDs[id]++
		}
		if username != "" {
			usernames[username]++
		}
		result.Summary.Memberships += len(groups)
		realm.Users = append(realm.Users, realmUser{
			ID:         id,
			Username:   username,
			Groups:     groups,
			RealmRoles: roles,
		})
	}

	reportDuplicates(userIDs, "DUPLICATE_USER_ID", "user id", result)
	reportDuplicates(usernames, "DUPLICATE_USERNAME", "username", result)
	result.Summary.Groups = len(realm.Groups)
	result.Summary.Users = len(realm.Users)
	if result.Summary.PlatformAdmins == 0 {
		result.warn(
			"NO_SOURCE_PLATFORM_ADMIN",
			"the reconciliation JSON contains no source user with realm role \"admin\"",
		)
	}
	return realm, nil
}

func loadBundle(filePath string, result *AuditResult) (bundleData, error) {
	reader, err := zip.OpenReader(filePath)
	if err != nil {
		return bundleData{}, fmt.Errorf("open ZIP: %w", err)
	}
	defer reader.Close()

	bundle := bundleData{
		tables:  make(map[string][]map[string]any),
		entries: make(map[string]*zip.File),
	}
	var totalUncompressed uint64
	for _, entry := range reader.File {
		clean := path.Clean(strings.ReplaceAll(entry.Name, "\\", "/"))
		if clean != entry.Name || strings.HasPrefix(clean, "/") || clean == "." || clean == ".." ||
			strings.HasPrefix(clean, "../") {
			result.error("UNSAFE_ZIP_PATH", "unsafe ZIP entry name %q", entry.Name)
			continue
		}
		if _, duplicate := bundle.entries[entry.Name]; duplicate {
			result.error("DUPLICATE_ZIP_ENTRY", "duplicate ZIP entry %q", entry.Name)
			continue
		}
		if entry.UncompressedSize64 > maxEntryBytes {
			result.error(
				"ZIP_ENTRY_TOO_LARGE",
				"ZIP entry %q expands to %d bytes (limit %d)",
				entry.Name,
				entry.UncompressedSize64,
				maxEntryBytes,
			)
		}
		totalUncompressed += entry.UncompressedSize64
		bundle.entries[entry.Name] = entry
	}
	if totalUncompressed > maxArchiveBytes {
		result.error(
			"ZIP_TOO_LARGE",
			"ZIP expands to %d bytes (limit %d)",
			totalUncompressed,
			maxArchiveBytes,
		)
	}

	manifestEntry := bundle.entries["manifest.json"]
	if manifestEntry == nil {
		return bundle, fmt.Errorf("manifest.json is missing")
	}
	manifestBytes, err := readZipFile(manifestEntry)
	if err != nil {
		return bundle, fmt.Errorf("read manifest.json: %w", err)
	}
	if err := decodeOneJSON(manifestBytes, &bundle.manifest); err != nil {
		return bundle, fmt.Errorf("invalid manifest.json: %w", err)
	}
	if bundle.manifest.FormatVersion != 1 {
		result.error(
			"FORMAT_VERSION",
			"manifest format_version must be 1, got %d",
			bundle.manifest.FormatVersion,
		)
	}
	if bundle.manifest.UsersSchemaVersion != nil && *bundle.manifest.UsersSchemaVersion != 1 {
		result.error(
			"USERS_SCHEMA_VERSION",
			"manifest users_schema_version must be 1 when present, got %d",
			*bundle.manifest.UsersSchemaVersion,
		)
	}
	if bundle.manifest.SourcePlatform != "kea" {
		result.error(
			"SOURCE_PLATFORM",
			"manifest source_platform must be \"kea\", got %q",
			bundle.manifest.SourcePlatform,
		)
	}
	if bundle.manifest.Tables == nil {
		result.error("MANIFEST_TABLES", "manifest tables must be an object")
		bundle.manifest.Tables = make(map[string]int)
	}
	if bundle.manifest.TupleCount < 0 {
		result.error("MANIFEST_TUPLE_COUNT", "manifest tuple_count cannot be negative")
	}

	for tableName, expectedCount := range bundle.manifest.Tables {
		if expectedCount < 0 {
			result.error(
				"MANIFEST_TABLE_COUNT",
				"manifest table %q has negative count %d",
				tableName,
				expectedCount,
			)
			continue
		}
		entryName := fmt.Sprintf("postgres/%s.jsonl", tableName)
		entry := bundle.entries[entryName]
		if entry == nil {
			result.error(
				"MISSING_TABLE_FILE",
				"manifest declares table %q with %d row(s), but %s is missing",
				tableName,
				expectedCount,
				entryName,
			)
			continue
		}
		rows, rowErr := readJSONLines(entry)
		if rowErr != nil {
			result.error("TABLE_JSONL", "%s: %v", entryName, rowErr)
			continue
		}
		bundle.tables[tableName] = rows
		if len(rows) != expectedCount {
			result.error(
				"TABLE_COUNT_MISMATCH",
				"manifest declares %d row(s) for %q, JSONL contains %d",
				expectedCount,
				tableName,
				len(rows),
			)
		}
		if _, known := knownKeaTables[tableName]; !known {
			result.warn("UNKNOWN_TABLE", "manifest contains unrecognized Kea table %q", tableName)
		}
	}

	for entryName, entry := range bundle.entries {
		if !strings.HasPrefix(entryName, "postgres/") || !strings.HasSuffix(entryName, ".jsonl") {
			continue
		}
		tableName := strings.TrimSuffix(strings.TrimPrefix(entryName, "postgres/"), ".jsonl")
		if _, declared := bundle.manifest.Tables[tableName]; declared {
			continue
		}
		rows, rowErr := readJSONLines(entry)
		if rowErr != nil {
			result.error("TABLE_JSONL", "%s: %v", entryName, rowErr)
			continue
		}
		bundle.tables[tableName] = rows
		if len(rows) > 0 {
			result.error(
				"UNDECLARED_TABLE_FILE",
				"%s contains %d row(s) but is absent from manifest.tables",
				entryName,
				len(rows),
			)
		}
	}

	tuplesEntry := bundle.entries["openfga/tuples.json"]
	if tuplesEntry == nil {
		result.error("MISSING_TUPLES", "openfga/tuples.json is missing")
	} else {
		tupleBytes, tupleErr := readZipFile(tuplesEntry)
		if tupleErr != nil {
			result.error("TUPLES_READ", "read openfga/tuples.json: %v", tupleErr)
		} else if decodeErr := decodeOneJSON(tupleBytes, &bundle.tuples); decodeErr != nil {
			result.error("TUPLES_JSON", "invalid openfga/tuples.json: %v", decodeErr)
		}
	}
	if len(bundle.tuples) != bundle.manifest.TupleCount {
		result.error(
			"TUPLE_COUNT_MISMATCH",
			"manifest declares %d tuple(s), openfga/tuples.json contains %d",
			bundle.manifest.TupleCount,
			len(bundle.tuples),
		)
	}

	if _, embeddedRealm := bundle.entries["keycloak/realm.json"]; embeddedRealm {
		result.warn(
			"EMBEDDED_REALM_OVERRIDDEN",
			"ZIP contains keycloak/realm.json; the supplied reconciliation JSON will replace it, not merge with it",
		)
	}

	result.Summary.SourcePlatform = bundle.manifest.SourcePlatform
	result.Summary.FormatVersion = bundle.manifest.FormatVersion
	result.Summary.TableRows = make(map[string]int, len(bundle.tables))
	for tableName, rows := range bundle.tables {
		result.Summary.TableRows[tableName] = len(rows)
	}
	result.Summary.Tuples = len(bundle.tuples)
	return bundle, nil
}

func crossValidate(bundle bundleData, realm reconciliationData, result *AuditResult) {
	groupIDs := make(map[string]string, len(realm.Groups))
	groupNames := make(map[string]string, len(realm.Groups))
	for _, group := range realm.Groups {
		groupIDs[group.ID] = group.Name
		groupNames[group.Name] = group.ID
	}
	userIDs := make(map[string]string, len(realm.Users))
	for _, user := range realm.Users {
		userIDs[user.ID] = user.Username
	}

	agents := collectEntities(bundle.tables["agent"], "id", "agent", result)
	tags := collectEntities(bundle.tables["tag"], "tag_id", "tag", result)
	documents := collectEntities(bundle.tables["metadata"], "document_uid", "document", result)
	resources := collectEntities(bundle.tables["resource"], "resource_id", "resource", result)
	result.Summary.Tags = len(tags)
	result.Summary.Documents = len(documents)
	result.Summary.Resources = len(resources)

	documentParentTags := make(map[string]map[string]struct{})
	for _, item := range bundle.tuples {
		subjectType, subjectID, subjectOK := splitReference(item.User)
		objectType, objectID, objectOK := splitReference(item.Object)
		if !subjectOK || !objectOK ||
			subjectType != "tag" ||
			item.Relation != "parent" ||
			objectType != "document" {
			continue
		}
		parentTags := documentParentTags[objectID]
		if parentTags == nil {
			parentTags = make(map[string]struct{})
			documentParentTags[objectID] = parentTags
		}
		parentTags[subjectID] = struct{}{}
	}

	mappedAgents := make(map[string]struct{})
	type agentGapSummary struct {
		count    int
		examples []string
	}
	agentGaps := make(map[string]*agentGapSummary)
	for index, row := range bundle.tables["agent"] {
		agentID, _ := stringValue(row["id"])
		payload, ok := objectValue(row["payload_json"])
		if !ok {
			if payloadString, stringOK := stringValue(row["payload_json"]); stringOK {
				if err := json.Unmarshal([]byte(payloadString), &payload); err != nil {
					result.error(
						"AGENT_PAYLOAD",
						"agent row %d (%q) payload_json is neither an object nor valid nested JSON",
						index,
						agentID,
					)
					continue
				}
			} else {
				result.error(
					"AGENT_PAYLOAD",
					"agent row %d (%q) payload_json must be an object",
					index,
					agentID,
				)
				continue
			}
		}
		if payloadType, _ := stringValue(payload["type"]); payloadType == "leader" {
			continue
		}
		template, _ := stringValue(payload["definition_ref"])
		if template == "" {
			template, _ = stringValue(payload["class_path"])
		}
		switch {
		case template == "":
			result.Summary.AgentGaps++
			gap := agentGaps["<missing definition_ref/class_path>"]
			if gap == nil {
				gap = &agentGapSummary{}
				agentGaps["<missing definition_ref/class_path>"] = gap
			}
			gap.count++
			gap.examples = appendLimitedUnique(gap.examples, agentID, maxFindingExamples)
		case hasKey(mappedAgentTemplates, template):
			result.Summary.AgentsMapped++
			mappedAgents[agentID] = struct{}{}
		case hasKey(ignoredAgentTemplates, template):
			result.Summary.AgentsIgnored++
		default:
			result.Summary.AgentGaps++
			gap := agentGaps[template]
			if gap == nil {
				gap = &agentGapSummary{}
				agentGaps[template] = gap
			}
			gap.count++
			gap.examples = appendLimitedUnique(gap.examples, agentID, maxFindingExamples)
		}
		if createdBy, present := stringValue(row["created_by"]); present && createdBy != "" {
			if _, known := userIDs[createdBy]; !known {
				result.error(
					"UNKNOWN_AGENT_CREATOR",
					"agent %q created_by %q is absent from reconciliation users",
					agentID,
					createdBy,
				)
			}
		}
	}
	gapTemplates := make([]string, 0, len(agentGaps))
	for template := range agentGaps {
		gapTemplates = append(gapTemplates, template)
	}
	sort.Slice(gapTemplates, func(i, j int) bool {
		left := agentGaps[gapTemplates[i]].count
		right := agentGaps[gapTemplates[j]].count
		if left != right {
			return left > right
		}
		return gapTemplates[i] < gapTemplates[j]
	})
	for _, template := range gapTemplates {
		gap := agentGaps[template]
		result.addFindingBreakdown(
			severityError,
			"AGENT_MAPPING_GAP",
			fmt.Sprintf("unmapped template %q", template),
			gap.count,
			gap.examples,
		)
	}

	for _, row := range bundle.tables["tag"] {
		tagID, _ := stringValue(row["tag_id"])
		ownerID, _ := stringValue(row["owner_id"])
		if ownerID == "" {
			result.warn("TAG_WITHOUT_OWNER", "tag %q has no owner_id", tagID)
			continue
		}
		if _, user := userIDs[ownerID]; user {
			continue
		}
		if _, group := groupIDs[ownerID]; group {
			continue
		}
		result.error(
			"UNKNOWN_TAG_OWNER",
			"tag %q owner_id %q is neither a reconciliation user nor group",
			tagID,
			ownerID,
		)
	}

	missingDocumentTags := make(map[string]*occurrenceSummary)
	documentsWithoutReplayableParent := make(map[string]*occurrenceSummary)
	for _, row := range bundle.tables["metadata"] {
		documentID, _ := stringValue(row["document_uid"])
		tagIDs, ok := stringSliceValue(row["tag_ids"])
		if !ok {
			result.Summary.DocumentsInvalidTagShape++
			recordOccurrence(documentsWithoutReplayableParent, documentID, "invalid tag_ids")
			result.error("DOCUMENT_TAGS", "document %q tag_ids must be an array of strings", documentID)
			continue
		}
		if len(tagIDs) == 0 {
			result.Summary.DocumentsWithoutKnownTag++
			recordOccurrence(documentsWithoutReplayableParent, documentID, "no tag_ids")
			result.warn("DOCUMENT_WITHOUT_TAG", "document %q has no tag_ids and may be inaccessible", documentID)
			continue
		}
		knownTags := 0
		hasReplayableParent := false
		for _, tagID := range tagIDs {
			if _, known := tags[tagID]; known {
				knownTags++
				if _, linked := documentParentTags[documentID][tagID]; linked {
					hasReplayableParent = true
				}
				continue
			}
			recordOccurrence(missingDocumentTags, tagID, documentID)
		}
		switch {
		case knownTags == len(tagIDs):
			result.Summary.DocumentsFullyTagLinked++
		case knownTags > 0:
			result.Summary.DocumentsPartiallyTagLinked++
		default:
			result.Summary.DocumentsWithoutKnownTag++
		}
		if hasReplayableParent {
			result.Summary.DocumentsWithReplayableParent++
		} else {
			recordOccurrence(
				documentsWithoutReplayableParent,
				documentID,
				fmt.Sprintf("%d declared tag(s), %d present", len(tagIDs), knownTags),
			)
		}
	}
	result.Summary.DocumentsWithoutReplayableParent = len(documentsWithoutReplayableParent)
	result.Summary.MissingDocumentTagIDs = len(missingDocumentTags)
	result.Summary.MissingDocumentTagReferences = occurrenceTotal(missingDocumentTags)
	result.addOccurrenceBreakdowns(
		severityError,
		"UNKNOWN_DOCUMENT_TAG",
		"missing tag",
		missingDocumentTags,
	)
	result.addOccurrenceBreakdowns(
		severityError,
		"DOCUMENT_WITHOUT_REPLAYABLE_PARENT",
		"document",
		documentsWithoutReplayableParent,
	)

	for _, row := range bundle.tables["resource"] {
		resourceID, _ := stringValue(row["resource_id"])
		resourceType, _ := stringValue(row["resource_type"])
		if resourceType != "chat-context" {
			result.warn(
				"UNSUPPORTED_RESOURCE",
				"resource %q kind %q has no Swift equivalent and will be skipped",
				resourceID,
				resourceType,
			)
			continue
		}
		author, _ := stringValue(row["author"])
		if author == "" {
			if doc, ok := objectValue(row["doc"]); ok {
				author, _ = stringValue(doc["author"])
			}
		}
		if author == "" {
			result.error("RESOURCE_WITHOUT_AUTHOR", "chat-context resource %q has no author", resourceID)
		} else if _, known := userIDs[author]; !known {
			result.error(
				"UNKNOWN_RESOURCE_AUTHOR",
				"chat-context resource %q author %q is absent from reconciliation users",
				resourceID,
				author,
			)
		}
	}

	teamIDs := make(map[string]struct{})
	for _, row := range bundle.tables["teammetadata"] {
		teamID, ok := stringValue(row["id"])
		if !ok || teamID == "" {
			result.error("TEAM_METADATA_ID", "teammetadata row has no non-empty id")
			continue
		}
		teamIDs[teamID] = struct{}{}
	}

	adminTeams := make(map[string]struct{})
	ownedAgents := make(map[string]struct{})
	unknownTupleUsers := make(map[string]struct{})
	unknownTupleAgents := make(map[string]*occurrenceSummary)
	unknownTupleTags := make(map[string]*occurrenceSummary)
	unknownTupleTeams := make(map[string]*occurrenceSummary)
	duplicateTuples := make(map[string]int)
	droppedResourceParents := 0
	droppedPersonal := 0

	for index, item := range bundle.tuples {
		subjectType, subjectID, subjectOK := splitReference(item.User)
		objectType, objectID, objectOK := splitReference(item.Object)
		if !subjectOK || !objectOK || item.Relation == "" {
			result.error(
				"TUPLE_SHAPE",
				"tuple[%d] must contain non-empty user, relation and object references",
				index,
			)
			continue
		}
		tupleKey := item.User + "\x00" + item.Relation + "\x00" + item.Object
		duplicateTuples[tupleKey]++

		if (subjectType == "team" && subjectID == "personal") ||
			(objectType == "team" && objectID == "personal") {
			droppedPersonal++
			continue
		}

		if subjectType == "user" && subjectID != "*" {
			if !uuidPattern.MatchString(subjectID) {
				result.error(
					"NON_UUID_USER_TUPLE",
					"tuple[%d] user subject %q is not a UUID and Swift will drop it",
					index,
					subjectID,
				)
			} else if _, known := userIDs[subjectID]; !known {
				unknownTupleUsers[subjectID] = struct{}{}
			}
		}

		if subjectType == "team" {
			teamIDs[subjectID] = struct{}{}
		}
		if objectType == "team" {
			teamIDs[objectID] = struct{}{}
		}

		switch subjectType {
		case "tag":
			if _, known := tags[subjectID]; !known {
				recordOccurrence(unknownTupleTags, subjectID, fmt.Sprintf("tuple[%d] subject", index))
			}
		case "team":
			if _, known := groupIDs[subjectID]; !known {
				recordOccurrence(unknownTupleTeams, subjectID, fmt.Sprintf("tuple[%d] subject", index))
			}
		}

		switch objectType {
		case "agent":
			if _, known := agents[objectID]; !known {
				recordOccurrence(unknownTupleAgents, objectID, fmt.Sprintf("tuple[%d] object", index))
			}
			if item.Relation == "owner" && (subjectType == "user" || subjectType == "team") {
				ownedAgents[objectID] = struct{}{}
			}
		case "tag":
			if _, known := tags[objectID]; !known {
				recordOccurrence(unknownTupleTags, objectID, fmt.Sprintf("tuple[%d] object", index))
			}
		case "document":
			if _, known := documents[objectID]; !known {
				result.error("UNKNOWN_TUPLE_DOCUMENT", "tuple[%d] references absent document %q", index, objectID)
			}
		case "resource":
			if _, known := resources[objectID]; !known {
				result.error("UNKNOWN_TUPLE_RESOURCE", "tuple[%d] references absent resource %q", index, objectID)
			}
			droppedResourceParents++
			continue
		case "team":
			if _, known := groupIDs[objectID]; !known {
				recordOccurrence(unknownTupleTeams, objectID, fmt.Sprintf("tuple[%d] object", index))
			}
			if item.Relation == "owner" && subjectType == "user" {
				if _, known := userIDs[subjectID]; known {
					adminTeams[objectID] = struct{}{}
				}
			}
		}

		if !isReplayableTuple(subjectType, item.Relation, objectType) {
			result.error(
				"UNSUPPORTED_TUPLE",
				"tuple[%d] shape %s --%s--> %s has no Swift equivalent",
				index,
				subjectType,
				item.Relation,
				objectType,
			)
		}
	}

	result.Summary.UnknownTupleAgentIDs = len(unknownTupleAgents)
	result.Summary.UnknownTupleAgentReferences = occurrenceTotal(unknownTupleAgents)
	result.Summary.UnknownTupleTagIDs = len(unknownTupleTags)
	result.Summary.UnknownTupleTagReferences = occurrenceTotal(unknownTupleTags)
	result.Summary.UnknownTupleTeamIDs = len(unknownTupleTeams)
	result.Summary.UnknownTupleTeamReferences = occurrenceTotal(unknownTupleTeams)
	result.addOccurrenceBreakdowns(
		severityError,
		"UNKNOWN_TUPLE_AGENT",
		"missing agent",
		unknownTupleAgents,
	)
	result.addOccurrenceBreakdowns(
		severityError,
		"UNKNOWN_TUPLE_TAG",
		"missing tag",
		unknownTupleTags,
	)
	result.addOccurrenceBreakdowns(
		severityError,
		"UNKNOWN_TUPLE_TEAM",
		"missing team",
		unknownTupleTeams,
	)
	reportDuplicates(duplicateTuples, "DUPLICATE_TUPLE", "OpenFGA tuple", result)
	if len(unknownTupleUsers) > 0 {
		result.warn(
			"UNKNOWN_TUPLE_USERS",
			"%d UUID user subject(s) in OpenFGA are absent from reconciliation users; verify they are only service accounts: %s",
			len(unknownTupleUsers),
			examples(unknownTupleUsers, 5),
		)
	}
	if droppedPersonal > 0 {
		result.warn(
			"DROPPED_PERSONAL_TUPLES",
			"%d tuple(s) touch Kea's shared personal pseudo-team and will be intentionally dropped",
			droppedPersonal,
		)
	}
	if droppedResourceParents > 0 {
		result.warn(
			"DROPPED_RESOURCE_TUPLES",
			"%d resource parent tuple(s) will be intentionally dropped when chat contexts become prompts",
			droppedResourceParents,
		)
	}

	for agentID := range mappedAgents {
		if _, owned := ownedAgents[agentID]; !owned {
			result.warn(
				"AGENT_WITHOUT_OWNER",
				"mapped agent %q has no user/team owner tuple and will be skipped (expected for an unused catalog definition)",
				agentID,
			)
		}
	}

	delete(teamIDs, "personal")
	for teamID := range teamIDs {
		if _, known := groupIDs[teamID]; !known {
			continue
		}
		if _, administered := adminTeams[teamID]; !administered {
			result.error(
				"ADMINLESS_TEAM",
				"team %q (%s) has no resolvable Kea owner and would have no Swift team_admin",
				groupIDs[teamID],
				teamID,
			)
		}
	}
	if len(realm.Groups) > 0 && len(bundle.tuples) == 0 {
		result.error(
			"EMPTY_OPENFGA",
			"reconciliation contains groups but the OpenFGA tuple export is empty; elevated team roles cannot be recovered",
		)
	}

	usedGroups := make(map[string]struct{})
	for teamID := range teamIDs {
		usedGroups[teamID] = struct{}{}
	}
	for _, user := range realm.Users {
		for _, groupPath := range user.Groups {
			groupName := strings.TrimPrefix(groupPath, "/")
			if groupID, known := groupNames[groupName]; known {
				usedGroups[groupID] = struct{}{}
			}
		}
	}
	unusedGroups := 0
	for groupID := range groupIDs {
		if _, used := usedGroups[groupID]; !used {
			unusedGroups++
		}
	}
	if unusedGroups > 0 {
		result.warn(
			"UNUSED_GROUPS",
			"%d reconciliation group(s) are neither referenced by tuples/teammetadata nor assigned to a user",
			unusedGroups,
		)
	}

	result.Summary.TeamsReferenced = len(teamIDs)
}

func isReplayableTuple(subjectType, relation, objectType string) bool {
	if objectType == "team" && subjectType == "user" {
		return relation == "owner" || relation == "manager" || relation == "member" || relation == "public"
	}
	if objectType == "agent" && relation == "owner" {
		return subjectType == "user" || subjectType == "team"
	}
	if objectType == "tag" && (relation == "owner" || relation == "editor" || relation == "viewer") {
		return subjectType == "user" || subjectType == "team"
	}
	if objectType == "tag" && relation == "parent" {
		return subjectType == "tag"
	}
	if objectType == "document" && relation == "parent" {
		return subjectType == "tag"
	}
	if objectType == "team" && relation == "organization" {
		return subjectType == "organization"
	}
	return false
}

func collectEntities(
	rows []map[string]any,
	idField string,
	entityName string,
	result *AuditResult,
) map[string]struct{} {
	entities := make(map[string]struct{}, len(rows))
	for index, row := range rows {
		id, ok := stringValue(row[idField])
		if !ok || id == "" {
			result.error(
				"ENTITY_ID",
				"%s row %d has no non-empty %s",
				entityName,
				index,
				idField,
			)
			continue
		}
		if _, duplicate := entities[id]; duplicate {
			result.error("DUPLICATE_ENTITY_ID", "duplicate %s id %q", entityName, id)
		}
		entities[id] = struct{}{}
	}
	return entities
}

func readZipFile(entry *zip.File) ([]byte, error) {
	if entry.UncompressedSize64 > maxEntryBytes {
		return nil, fmt.Errorf("entry expands beyond %d bytes", maxEntryBytes)
	}
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, maxEntryBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxEntryBytes {
		return nil, fmt.Errorf("entry expands beyond %d bytes", maxEntryBytes)
	}
	return data, nil
}

func readJSONLines(entry *zip.File) ([]map[string]any, error) {
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), maxJSONLineBytes)
	rows := make([]map[string]any, 0)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var row map[string]any
		if err := decodeOneJSON(line, &row); err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNumber, err)
		}
		rows = append(rows, row)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return rows, nil
}

func decodeOneJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return fmt.Errorf("trailing data: %w", err)
	}
	return nil
}

func decodeRawObject(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, fmt.Errorf("must be an object: %w", err)
	}
	if object == nil {
		return nil, fmt.Errorf("must be an object")
	}
	return object, nil
}

func requiredString(object map[string]json.RawMessage, key string) (string, bool) {
	raw, present := object[key]
	if !present {
		return "", false
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", false
	}
	return value, true
}

func requiredStringArray(object map[string]json.RawMessage, key string) ([]string, bool) {
	raw, present := object[key]
	if !present {
		return nil, false
	}
	var values []string
	if err := json.Unmarshal(raw, &values); err != nil || values == nil {
		return nil, false
	}
	return values, true
}

func rawArrayField(
	object map[string]json.RawMessage,
	key string,
) ([]json.RawMessage, bool, error) {
	raw, present := object[key]
	if !present {
		return nil, false, nil
	}
	var values []json.RawMessage
	if err := json.Unmarshal(raw, &values); err != nil || values == nil {
		if err == nil {
			err = fmt.Errorf("null is not an array")
		}
		return nil, true, err
	}
	return values, true, nil
}

func stringValue(value any) (string, bool) {
	text, ok := value.(string)
	return text, ok
}

func objectValue(value any) (map[string]any, bool) {
	object, ok := value.(map[string]any)
	return object, ok
}

func stringSliceValue(value any) ([]string, bool) {
	items, ok := value.([]any)
	if !ok {
		return nil, false
	}
	values := make([]string, 0, len(items))
	for _, item := range items {
		text, textOK := item.(string)
		if !textOK {
			return nil, false
		}
		values = append(values, text)
	}
	return values, true
}

func splitReference(reference string) (string, string, bool) {
	prefix, identifier, found := strings.Cut(reference, ":")
	return prefix, identifier, found && prefix != "" && identifier != ""
}

func hasKey(values map[string]struct{}, key string) bool {
	_, exists := values[key]
	return exists
}

func sortedKeys(values map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func reportDuplicates(
	counts map[string]int,
	code string,
	label string,
	result *AuditResult,
) {
	duplicates := make([]string, 0)
	for value, count := range counts {
		if count > 1 {
			duplicates = append(duplicates, fmt.Sprintf("%q (%d times)", value, count))
		}
	}
	sort.Strings(duplicates)
	for _, duplicate := range duplicates {
		result.error(code, "duplicate %s %s", label, duplicate)
	}
}

func examples(values map[string]struct{}, limit int) string {
	items := make([]string, 0, len(values))
	for value := range values {
		items = append(items, value)
	}
	sort.Strings(items)
	if len(items) > limit {
		return strings.Join(items[:limit], ", ") + fmt.Sprintf(" … (+%d)", len(items)-limit)
	}
	return strings.Join(items, ", ")
}

func appendLimitedUnique(values []string, value string, limit int) []string {
	if value == "" || len(values) >= limit {
		return values
	}
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func recordOccurrence(
	occurrences map[string]*occurrenceSummary,
	identifier string,
	example string,
) {
	occurrence := occurrences[identifier]
	if occurrence == nil {
		occurrence = &occurrenceSummary{}
		occurrences[identifier] = occurrence
	}
	occurrence.count++
	occurrence.examples = appendLimitedUnique(
		occurrence.examples,
		example,
		maxFindingExamples,
	)
}

func occurrenceTotal(occurrences map[string]*occurrenceSummary) int {
	total := 0
	for _, occurrence := range occurrences {
		total += occurrence.count
	}
	return total
}
