---
name: ecosystem-audit
description: Check that Fred and the applications checked out next to it (agents, knowledge bases, evaluation, satellite products) agree on Fred's published libraries — Python (fred-sdk, fred-runtime, fred-core, fred-pod, capabilities) and npm (@fred-oss/*) — and are on the same branch. Use before an integration pass, after a Fred release, or when a developer asks whether the workspace is aligned or consistent.
user-invocable: true
argument-hint: [optional: branch, default swift]
---

# Ecosystem audit

`bin/ecosystem-audit` (this repository) is the check; the skill runs it, explains the
findings and fixes what is mechanical. Never re-derive the findings by hand: if the script
misses something, fix the script and add a test in `bin/test_ecosystem_audit.py`.

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
| npm packages | a `package.json` or its lock is not on the latest `@fred-oss/*` | `npm install @fred-oss/<pkg>@<latest>` in that directory |
| Unreadable files | a TOML file does not parse (often a committed merge conflict) | resolve it, then relock |

These are **decisions for the developer, never fix them on your own**:

- **Constraint styles**: `==` (an application moves when it decides) or `>=` (it follows Fred).
- **Installed from Fred's source**: a `[tool.uv.sources]` path to the Fred checkout. The lock
  then records the source, and an image build that sets `UV_NO_SOURCES*` resolves from PyPI
  instead of the lock.
- **Copies of Fred**: a project carrying its own copy of a Fred library is outside the
  published line; aligning it is a migration, not a version bump.

## Working rules

- Fixes go on the working branch the developer named, one commit per repository and per
  kind of fix (`chore(deps): ...`). Show the diff; never commit or push without approval.
- After a fix, rerun the audit: it is done when the section is empty, not when the command ran.
- Relocking changes what an application runs: run that repository's `make test` afterwards.
- Fred itself is changed through a GitHub issue and a PR, never as a side effect of an audit.
