---
phase: quick-260718-fz2
plan: 01
subsystem: qa-tooling
tags: [journeyhawk, observability, logs, bash]
requires: []
provides:
  - "scripts/summarize-run.sh — pure-text sprint-log metric extractor + RUN-LOG.md row appender"
affects:
  - "overnight-runs/RUN-LOG.md (gitignored run output)"
tech-stack:
  added: []
  patterns: ["house-style bash: set -euo pipefail, SCRIPT_DIR resolution, [tag] stderr logging"]
key-files:
  created:
    - scripts/summarize-run.sh
  modified: []
decisions:
  - "promoted column sources the curator `promoted=N` value (per plan), not the Summary `Patterns promoted:` value — they differ (0 vs 9 in sprint11)"
  - "readiness rendered as LEVEL(composite) e.g. HOLD(0.325) when both present"
  - "RUN-LOG.md path resolved relative to script dir; no absolute home paths (No-Hardcoding invariant)"
metrics:
  duration: "~6 min"
  completed: "2026-07-18"
---

# Quick Task 260718-fz2: Run-Summary Extractor for JourneyHawk Sprint Logs Summary

Added `scripts/summarize-run.sh`, a pure-text tool that parses key run metrics (curator counts, CrossRepoSweep signal count, strategy defect_rate, readiness, and the Summary block) from a single JourneyHawk sprint log and appends one markdown row per invocation to `overnight-runs/RUN-LOG.md` — turning per-run diagnosis from a raw-log grep hunt into a one-row lookup.

## What Was Built

- **Task 1** — `scripts/summarize-run.sh` (123 lines, executable). House-style bash (`#!/bin/bash`, `set -euo pipefail`, `SCRIPT_DIR` resolution, `[summarize]` stderr logging). Extracts 14 columns: Date (log mtime), Product, Run ID, Journeys, Pass, Fail, Gaps, Defects, Promoted (curator), Coverage, defect_rate, Sweep, Readiness, Log. Every metric field defaults to em dash `—` when absent; the only hard error (exit 1) is a missing log-file argument. Auto-bootstraps the RUN-LOG.md title + table header on first run, then append-only via `>>`. No DB / LLM / phronex-common / `.qa.env`.

- **Task 2** — Proven end-to-end against the two real logs from the sibling `cc-journeyhawk-sprint1` worktree (copied into this worktree's `overnight-runs/` for the proof, since `overnight-runs/` is gitignored and not present in a fresh worktree):
  - **Happy path (sprint11.log, completed run):** row fully populated — Product=cc, Run ID=ead5a72a-..., coverage=70->70, defect_rate=0.00, readiness=HOLD(0.325), promoted=0 (legitimate curator value, not em dash). Journeys=0 is a real value for that run, correctly rendered as `0` not `—`.
  - **Incomplete path (sprint12.log, in-progress, 0 metric lines):** exits 0, appends a second row whose metric fields are all `—`, with Log=sprint12.log still populated. No crash.
  - **Append-only:** both rows coexist below the header separator; re-running appends, never overwrites.
  - **Error path:** `overnight-runs/does-not-exist.log` exits 1 with `[summarize] ERROR: log file not found: ...`.
  - Plan's automated verify command emits `ALL_OK`.

## Evidence — RUN-LOG.md rows produced

```
| Date | Product | Run ID | Journeys | Pass | Fail | Gaps | Defects | Promoted | Coverage | defect_rate | Sweep | Readiness | Log |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-07-18 11:36 | cc | ead5a72a-d021-477d-bfff-b9451f8178b6 | 0 | 0 | 0 | 0 | 0 | 0 | 70->70 | 0.00 | 0 | HOLD(0.325) | sprint11.log |
| 2026-07-18 11:36 | — | — | — | — | — | — | — | — | — | — | — | — | sprint12.log |
```

(The `2026-07-18 11:36` date reflects the mtime of the copied log files in this fresh worktree, not the original run-finish time. In normal use against logs written in place, `date -r` yields the actual run-finish timestamp.)

## Deviations from Plan

None — plan executed exactly as written. `promoted` intentionally sources the curator `promoted=N` line (per the plan's explicit field mapping), which differs from the Summary-block `Patterns promoted:` value; this is by design, not a bug.

## Commits

- `f1a8a04` — feat(quick-260718-fz2): add run-summary extractor for JourneyHawk sprint logs (Task 1)

Task 2 is a verification/proof task; its only output (`overnight-runs/RUN-LOG.md`) is gitignored run output, so it produces no commit — as expected per the task constraints.

## Self-Check: PASSED

- `scripts/summarize-run.sh` — FOUND (executable, 123 lines, passes `bash -n`)
- Commit `f1a8a04` — FOUND in git log
- `overnight-runs/RUN-LOG.md` — present as untracked/gitignored run output (expected)
