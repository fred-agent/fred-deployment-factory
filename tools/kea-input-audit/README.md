# Kea input audit

Standalone source-side preflight for the two immutable Kea-to-Swift cutover
inputs. It uses only the Go standard library and performs no network call.

Build:

```bash
cd tools/kea-input-audit
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags="-s -w" -o dist/kea-input-audit-linux-amd64 .
```

Cross-compile for a Windows target (e.g. Git Bash / MINGW64 on the
operator's workstation) the same way, no toolchain other than Go needed:

```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
  go build -trimpath -ldflags="-s -w" -o dist/kea-input-audit-windows-amd64.exe .
```

Run:

```bash
./kea-input-audit-linux-amd64 kea-snapshot.zip kea-realm-reconciliation.json
# Windows / Git Bash (MINGW64):
./kea-input-audit-windows-amd64.exe kea-snapshot.zip kea-realm-reconciliation.json
```

## Extract the reconciliation JSON

`extract-kea-reconciliation.sh` is the reference read-only Postgres extraction
used for the production cutover. It needs only `psql`; neither `jq` nor Keycloak
administration access is required:

```bash
export KEA_KEYCLOAK_DSN='postgresql://...'
./extract-kea-reconciliation.sh
./dist/kea-input-audit-linux-amd64 \
  kea-snapshot.zip kea-realm-reconciliation.json
```

The extraction script contains no credential or production value. The generated
JSON is sensitive operational data: it contains usernames, stable Keycloak ids,
group names, memberships and platform roles. `umask 077` creates it privately,
and the default output names are git-ignored in this directory. Transfer and
retain it only through approved secure channels. A checksum is integrity
metadata, not a substitute for protecting the JSON itself.

## Delivering the Windows binary by email

Most mail gateways strip `.exe` attachments. Base64-encode the binary into a
plain `.txt` first — Git Bash / MINGW64 ships `base64` via coreutils, so no
extra tooling is needed on either end:

```bash
# sender
base64 -w0 dist/kea-input-audit-windows-amd64.exe > kea-input-audit-windows-amd64.exe.b64.txt
sha256sum dist/kea-input-audit-windows-amd64.exe   # send this alongside, out of band
```

```bash
# recipient (Git Bash / MINGW64)
base64 -d kea-input-audit-windows-amd64.exe.b64.txt > kea-input-audit-windows-amd64.exe
sha256sum kea-input-audit-windows-amd64.exe        # compare against the sender's value
./kea-input-audit-windows-amd64.exe kea-snapshot.zip kea-realm-reconciliation.json
```

Findings are aggregated for production-sized inputs:

- every distinct finding code is always printed, even when earlier checks produce
  thousands of occurrences;
- repeated findings show their total count and at most ten representative
  examples;
- agent mapping gaps are broken down by source template, with the number of agent
  instances and representative agent ids for each template;
- documents are split into fully tag-linked, partially tag-linked, without any
  known tag, and invalid `tag_ids`; missing tag references report both occurrence
  and unique-id counts;
- document metadata is also cross-checked against replayable OpenFGA
  `tag --parent--> document` relations, so a present tag row is not mistaken for
  an authorization link that the Swift import can actually restore;
- dangling OpenFGA agent, tag and team references report occurrence and unique-id
  counts, plus the twenty most frequent missing ids;
- `--json` exposes the same complete per-code counts and agent-template breakdown.

The embedded Swift mapping includes both identities of the generic configurable
assistant: `v2.react.basic` and its legacy v1 class path
`agentic_backend.core.agents.basic_react_agent.BasicReActAgent`.

Exit status:

- `0`: structurally ready for the Swift dry-run;
- `1`: blocking input problem;
- `2`: usage or local read failure.

`PASS` does not replace the Swift dry-run. The dry-run remains authoritative
for live target identities and the target agent-template catalog.
