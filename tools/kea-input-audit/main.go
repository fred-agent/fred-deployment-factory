package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const version = "0.3.0"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	flags := flag.NewFlagSet("kea-input-audit", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	jsonOutput := flags.Bool("json", false, "print the complete audit result as JSON")
	showVersion := flags.Bool("version", false, "print the version and exit")
	flags.Usage = func() {
		fmt.Fprintf(
			flags.Output(),
			"Usage: %s [--json] <kea.zip> <reconciliation.json>\n",
			filepath.Base(os.Args[0]),
		)
		fmt.Fprintln(
			flags.Output(),
			"\nAudits both Kea cutover inputs without network access or external dependencies.",
		)
	}

	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *showVersion {
		fmt.Printf("kea-input-audit %s\n", version)
		return 0
	}
	if flags.NArg() != 2 {
		flags.Usage()
		return 2
	}

	result, err := Audit(flags.Arg(0), flags.Arg(1))
	if err != nil {
		fmt.Fprintf(os.Stderr, "kea-input-audit: %v\n", err)
		return 2
	}

	if *jsonOutput {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(result); err != nil {
			fmt.Fprintf(os.Stderr, "kea-input-audit: encode result: %v\n", err)
			return 2
		}
	} else {
		printHumanResult(result)
	}

	if result.Status == statusPass {
		return 0
	}
	return 1
}

func printHumanResult(result AuditResult) {
	fmt.Println("KEA INPUT AUDIT")
	fmt.Printf("ZIP             %s\n", result.Bundle.Path)
	fmt.Printf("SHA-256         %s\n", result.Bundle.SHA256)
	fmt.Printf("Reconciliation  %s\n", result.Reconciliation.Path)
	fmt.Printf("SHA-256         %s\n", result.Reconciliation.SHA256)
	fmt.Println()
	fmt.Printf(
		"Source: %s · format: %d · groups: %d · users: %d · memberships: %d\n",
		result.Summary.SourcePlatform,
		result.Summary.FormatVersion,
		result.Summary.Groups,
		result.Summary.Users,
		result.Summary.Memberships,
	)
	fmt.Printf(
		"Tuples: %d · teams: %d · agents: %d mapped / %d ignored / %d gaps\n",
		result.Summary.Tuples,
		result.Summary.TeamsReferenced,
		result.Summary.AgentsMapped,
		result.Summary.AgentsIgnored,
		result.Summary.AgentGaps,
	)
	fmt.Printf(
		"Tags: %d · documents: %d · resources: %d · platform admins: %d · viewers: %d\n",
		result.Summary.Tags,
		result.Summary.Documents,
		result.Summary.Resources,
		result.Summary.PlatformAdmins,
		result.Summary.PlatformViewers,
	)
	fmt.Printf(
		"Document tags: %d fully linked · %d partially linked · %d without known tag · %d invalid tag_ids\n",
		result.Summary.DocumentsFullyTagLinked,
		result.Summary.DocumentsPartiallyTagLinked,
		result.Summary.DocumentsWithoutKnownTag,
		result.Summary.DocumentsInvalidTagShape,
	)
	fmt.Printf(
		"Document authorization links: %d with replayable tag→document parent · %d without\n",
		result.Summary.DocumentsWithReplayableParent,
		result.Summary.DocumentsWithoutReplayableParent,
	)
	if result.Summary.MissingDocumentTagReferences > 0 {
		fmt.Printf(
			"Dangling document→tag refs: %d reference(s) across %d missing tag id(s)\n",
			result.Summary.MissingDocumentTagReferences,
			result.Summary.MissingDocumentTagIDs,
		)
	}
	if result.Summary.UnknownTupleAgentReferences > 0 ||
		result.Summary.UnknownTupleTagReferences > 0 ||
		result.Summary.UnknownTupleTeamReferences > 0 {
		fmt.Printf(
			"Dangling OpenFGA refs: agents %d/%d · tags %d/%d · teams %d/%d (unique ids/references)\n",
			result.Summary.UnknownTupleAgentIDs,
			result.Summary.UnknownTupleAgentReferences,
			result.Summary.UnknownTupleTagIDs,
			result.Summary.UnknownTupleTagReferences,
			result.Summary.UnknownTupleTeamIDs,
			result.Summary.UnknownTupleTeamReferences,
		)
	}

	if len(result.Findings) > 0 {
		fmt.Println()
		for _, finding := range result.Findings {
			if finding.Count == 1 && len(finding.Examples) == 1 && len(finding.Breakdown) == 0 {
				fmt.Printf(
					"[%s] %s: %s\n",
					finding.Severity,
					finding.Code,
					finding.Examples[0],
				)
				continue
			}
			fmt.Printf(
				"[%s] %s: %d occurrence(s)",
				finding.Severity,
				finding.Code,
				finding.Count,
			)
			if finding.Distinct > 0 {
				fmt.Printf(" across %d distinct value(s)", finding.Distinct)
			}
			fmt.Println()
			for _, item := range finding.Breakdown {
				fmt.Printf("  - %d × %s", item.Count, item.Label)
				if len(item.Examples) > 0 {
					fmt.Printf(" (examples: %s)", joinQuoted(item.Examples))
				}
				fmt.Println()
			}
			for _, example := range finding.Examples {
				fmt.Printf("  - %s\n", example)
			}
			if finding.BreakdownOmitted > 0 {
				fmt.Printf(
					"  - … %d additional distinct value(s) omitted from the display\n",
					finding.BreakdownOmitted,
				)
			}
		}
	}

	fmt.Println()
	if result.Status == statusPass {
		if result.WarningCount == 0 {
			fmt.Println("PASS — inputs are structurally ready for the Swift dry-run.")
		} else {
			fmt.Printf(
				"PASS WITH %d WARNING(S) — review warnings, then run the Swift dry-run.\n",
				result.WarningCount,
			)
		}
		fmt.Println("The Swift dry-run remains the final semantic go/no-go gate.")
		return
	}
	fmt.Printf(
		"FAIL — %d blocking error(s), %d warning(s). Do not transfer or import these inputs.\n",
		result.ErrorCount,
		result.WarningCount,
	)
}

func joinQuoted(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, value := range values {
		quoted = append(quoted, fmt.Sprintf("%q", value))
	}
	return strings.Join(quoted, ", ")
}

func checkReadableRegularFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("not a regular file")
	}
	return nil
}
