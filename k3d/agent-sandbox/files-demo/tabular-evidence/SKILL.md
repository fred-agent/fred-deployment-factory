---
name: tabular-evidence
description: Analyze a mounted CSV file with Python and report counts, totals, and outliers with source rows.
argument-hint: "[absolute path to a CSV file under /inputs]"
---

# Tabular evidence

1. Locate the requested CSV file under `/inputs/corpus` or `/inputs/attachments`.
2. Run `python /skills/tabular-evidence/analyze.py <absolute CSV path>` in the sandbox.
3. Report the computed totals and the highest value, citing the source row number.
4. Do not claim that files outside the mounted input directory were inspected.
