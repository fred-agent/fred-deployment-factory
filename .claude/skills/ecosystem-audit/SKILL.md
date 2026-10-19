---
name: ecosystem-audit
description: Check that Fred and the applications checked out next to it (agents, knowledge bases, evaluation, satellite products) agree on Fred's published libraries — Python (fred-sdk, fred-runtime, fred-core, fred-pod, capabilities) and npm (@fred-oss/*) — and are on the same branch. Use before an integration pass, after a Fred release, or when a developer asks whether the workspace is aligned or consistent. Reports only; fixes nothing unless asked.
user-invocable: true
argument-hint: [optional: branch, default swift]
---

# Ecosystem audit

`bin/ecosystem-audit` (this repository) is the check; the skill runs it and explains the
findings. Never re-derive the findings by hand: if the script misses something, fix the
script and add a test in `bin/test_ecosystem_audit.py`.

**An audit only reports.** It takes seconds: run the script, explain the findings, stop.
Change nothing in any repository unless the developer then asks for fixes (see "Fixing").

## Run

From this repository's root: `make ecosystem-audit` (fetches `origin/swift` in every
checkout), or `bin/ecosystem-audit --branch <b> [--offline]`. The workspace is every git
checkout next to this one; the one holding `libs/fred-sdk` is Fred, the reference.

## Read the findings

| Section | Means | Fix |
| --- | --- | --- |
| Git | a checkout behind `origin/<branch>`, or uncommitted work | `git pull`; ask before touching uncommitted work |
| Fred libraries | Fred's libs disagree, or the source is ahead of PyPI | applications are held to the PyPI version until Fred publishes |
| Constraints | a `pyproject.toml` excludes the reference version | edit the constraint (keep the project's style), then relock |
| Locks | a `uv.lock` installs another version | `uv lock --upgrade-package <each fred package>` in that project |
| npm packages | a `package.json` or its lock is not on the latest `@fred-oss/*` | `npm install --save-exact @fred-oss/<pkg>@<latest>` in that directory |
| Unreadable files | a TOML file does not parse (often a committed merge conflict) | resolve it, then relock |
| Fred source switch | a project built on fred lacks one of the three `FRED_LIBS` hooks, or commits `[tool.uv.sources]` to the fred checkout | add the hook as in dt-agents (docs/LOCAL-DEVELOPMENT.md, "Work on unreleased fred"); drop the committed source and relock |

These are **decisions for the developer, never fix them on your own**:

- **Constraint styles**: `==` (an application moves when it decides) or `>=` (it follows Fred).
- **Copies of Fred**: a project carrying its own copy of a Fred library is outside the
  published line; aligning it is a migration, not a version bump.

## Fixing (only when the developer asks)

- First list what you will change, in which repositories, and that each relock is followed
  by that repository's `make test` (minutes, not seconds). Start on the developer's go.
- Fixes go on the working branch the developer named, one commit per repository and per
  kind of fix (`chore(deps): ...`). Show the diff; never commit or push without approval.
- A test failing only after a relock may pin a hash of the lock: confirm on a clean tree,
  then update it in the same commit.
- After a fix, rerun the audit: it is done when the section is empty, not when the command ran.
- Fred itself is changed through a GitHub issue and a PR, never as a side effect of an audit.
