---
phase: 260503-5tp
plan: "01"
subsystem: cli-runner
tags:
  - tree-executor
  - zod-schema
  - jp-deep
  - playwright-session
  - topo-sort
dependency_graph:
  requires: []
  provides:
    - tree-executor (Kahn topo-sort with capturedStates session forwarding)
    - jp-deep.json 26-node multi-level tree
    - resolveParams param substitution
    - --runJourney ancestor-chain filter
  affects:
    - JourneyHawk jp-deep run behaviour
tech_stack:
  added:
    - Kahn's topological sort (inline, no new dependency)
    - resolveParams {{param}} template substitution
    - --runJourney CLI flag (commander .option)
    - --storage-state / --save-session playwright MCP args
  patterns:
    - capturedStates Map<string, string> for cross-journey session forwarding
    - isSharedRoot + stateOutputPath for trunk nodes that save browser state
    - dependsOn for dependency graph edges
key_files:
  created: []
  modified:
    - cli/src/types/test-case.ts
    - cli/src/index.ts
    - cli/src/prompts/start-test.ts
    - cli/src/utils/args.ts
    - jp-journeys/jp-deep.json
    - cli/cc-test-runner
decisions:
  - "z.record(z.string(), z.unknown()) required in Zod v4 (two-arg form — single-arg removed)"
  - "resolveParams exported from start-test.ts and imported in index.ts; resolution applied before server.setTestState so Claude receives substituted text"
  - "dist/cc-test-runner excluded from commit (gitignored by .gitignore:dist rule); cli/cc-test-runner committed instead"
metrics:
  duration: "~18 minutes"
  completed: "2026-05-03"
  tasks_completed: 3
  tasks_total: 3
  files_changed: 6
---

# Phase 260503-5tp Plan 01: TypeScript Tree Executor + jp-deep.json 26-Node Multi-Level Tree Restructure Summary

**One-liner:** Kahn topo-sort loop with capturedStates session forwarding, resolveParams {{param}} substitution, and jp-deep.json rebuilt as a 26-node multi-tier tree targeting https://app.phronex.com.

## What Was Built

### cli/src/types/test-case.ts
- Extracted inline step object into named `stepSchema` constant
- Added 6 new optional fields to `testCaseSchema`: `isSharedRoot`, `role`, `stateOutputPath`, `dependsOn`, `params`, `cleanupSteps`
- All fields have defaults — flat journey specs without any tree fields continue to parse and run unchanged
- Fixed Zod v4 `record` API: used `z.record(z.string(), z.unknown())` (v4 requires two arguments)

### cli/src/index.ts
- Added `capturedStates: Map<string, string>` to track session file paths per journey ID
- Implemented `topoSort()` using Kahn's algorithm — parents always run before children; cycle-detection fallback logs a warning instead of infinite-looping
- Implemented `runJourney()` helper that resolves params before calling `server.setTestState`, then calls `startTest(testCase, parentStatePath)`
- Replaced the flat `for (const testCase of inputs.testCases)` loop with a topo-sorted loop that wires `capturedStates.get(dependsOn)` as `parentStatePath`

### cli/src/prompts/start-test.ts
- Added `resolveParams()` (exported): replaces `{{paramName}}` placeholders with string-coerced values from the params record; unknown keys left as-is
- Updated `startTest` signature to `(testCase: TestCase, storageStatePath: string | null = null)`
- Playwright MCP args built as a `const` array; `--storage-state <path>` appended if `storageStatePath` is non-null; `--save-session <path>` appended if node is a shared root with a `stateOutputPath`

### cli/src/utils/args.ts
- Added `runJourney?: string` to `CLIOptions` interface
- Added `.option("--runJourney <id>", ...)` to the Commander program
- After test cases parse, if `--runJourney` is set: walks the `dependsOn` chain upward to collect the ancestor chain, filters `testCases` to only that chain, and sorts by chain order (ancestors first)

### jp-journeys/jp-deep.json
- Replaced 12 flat localhost journeys with a 26-node multi-level tree:
  - 4 trunk roots (`isSharedRoot: true, role: "root"`): jp-trunk-main, jp-trunk-free, jp-trunk-standard, jp-trunk-pro
  - 9 branch nodes (`role: "branch"`, each with `stateOutputPath`): jp-branch-dashboard, jp-branch-jobs-list, jp-branch-job-detail, jp-branch-profile, jp-branch-documents, jp-branch-config, jp-branch-subscription-free, jp-branch-subscription-standard, jp-branch-subscription-pro
  - 13 leaf nodes (`role: "verify"`): jp-verify-dashboard-stats, jp-verify-jobs-search, jp-verify-jobs-save, jp-verify-job-apply, jp-verify-job-ai-cover-letter, jp-verify-profile-update, jp-verify-documents-upload, jp-verify-config-byok, jp-verify-config-yaml, jp-verify-tier-free, jp-verify-tier-standard, jp-verify-tier-pro, jp-verify-portrait-regen
- All URLs changed from `http://localhost:3002/...` to `https://app.phronex.com/...`
- Passwords replaced with env var references (QA_PASS_MAIN, QA_PASS_FREE, QA_PASS_STANDARD, QA_PASS_PRO from .qa.env)
- Tier leaf nodes use `{{expectedTierLabel}}` and `{{expectedTier}}` params for parameterized verification

## Commits

| Hash | Description |
|------|-------------|
| ab78457 | feat(runner): tree executor + jp-deep.json 26-node multi-level tree restructure |

## Verification Results

| Check | Result |
|-------|--------|
| `bun tsc --noEmit` | PASS (exit 0, 0 errors) |
| jp-deep.json node count | 26 nodes (4 trunks / 9 branches / 13 leaves) |
| localhost URL count | 0 |
| `bun build --compile` | PASS (exit 0, 404 modules bundled) |
| Binary file type | ELF 64-bit LSB executable (100 MB) |
| Smoke test `--help` | PASS (prints usage, no crash) |
| Flat spec backward compat | PASS (all new fields have defaults; existing files parse unchanged) |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Zod v4 z.record() requires two arguments**
- **Found during:** Task 1 — first `bun tsc --noEmit` run
- **Issue:** Zod v4 changed `z.record(valueType)` to require two arguments: `z.record(keyType, valueType)`. The plan specified `z.record(z.unknown())` which worked in Zod v3 but produces a TypeScript error in Zod v4.0.17 (installed in this repo).
- **Fix:** Changed to `z.record(z.string(), z.unknown())`
- **Files modified:** cli/src/types/test-case.ts
- **Commit:** ab78457

**2. [Rule 3 - Blocking] cli/dist/cc-test-runner is gitignored**
- **Found during:** Task 3 — git staging
- **Issue:** `.gitignore` line 83 contains `dist` which matches `cli/dist/cc-test-runner`. The binary cannot be committed from that path.
- **Fix:** Per plan fallback instruction ("Stage cli/cc-test-runner (the root-level build artifact, if present)"), staged `cli/cc-test-runner` instead. The file exists as an untracked binary after `bun build`.
- **Files modified:** cli/cc-test-runner (committed as new file)
- **Commit:** ab78457

## Known Stubs

None — all new functionality is fully wired. jp-deep.json params are operator-authored values, not placeholder data.

## Threat Flags

None — no new network endpoints, auth paths, or trust boundary surfaces beyond what was specified in the plan's threat model.

## Self-Check: PASSED

- cli/src/types/test-case.ts: EXISTS
- cli/src/index.ts: EXISTS
- cli/src/prompts/start-test.ts: EXISTS
- cli/src/utils/args.ts: EXISTS
- jp-journeys/jp-deep.json: EXISTS (26 nodes verified)
- cli/cc-test-runner: EXISTS (committed as ELF binary)
- Commit ab78457: EXISTS in git log
