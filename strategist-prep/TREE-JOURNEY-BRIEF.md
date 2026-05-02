# Tree-Based Journey Architecture — Quick Brief

## What this is
Redesign cc-test-runner's journey execution model from "fully isolated vertical slices" to a **dependency tree** where shared ancestor journeys run once and their browser state (cookies + localStorage) is captured and injected into child journeys. This eliminates redundant login/navigation overhead and enables severity inference from tree depth.

## Problem solved
- Current: 12 journeys × full login+nav = ~25 min, 12 auth requests, 12 Chrome instances
- Target: 1 login per account tier root + children reuse that session = ~8-10 min, 4 auth requests

## Core mechanism
`@playwright/mcp` already supports `--storage-state <path>` flag (native, confirmed in v0.0.70+). After a root journey completes, the runner calls `browser_evaluate` to invoke `playwright.context.storageState()` — OR, more cleanly, the MCP server spawned for the root writes its session to disk automatically via `--save-session`. The child journey's MCP server is launched with `--storage-state <path>` pointing at the parent's saved state file.

## Spec format changes (jp-deep.json)

```json
[
  {
    "id": "jp-root-login",
    "description": "Login as main QA account and reach JP dashboard",
    "isSharedRoot": true,
    "stateOutputPath": ".tmp/jp-root-login-state.json",
    "steps": [
      {"id": 1, "description": "Navigate to https://app.phronex.com/auth/login and log in with qa-test-journeyhawk@phronex.com ..."},
      {"id": 2, "description": "Wait for dashboard to load. Verify: JP dashboard shows without errors. Save browser state."}
    ]
  },
  {
    "id": "jp-d01-document-upload",
    "description": "Upload test-resume.pdf and verify it appears in documents list",
    "dependsOn": "jp-root-login",
    "depth": 1,
    "steps": [
      {"id": 1, "description": "Navigate to https://app.phronex.com/jp/documents (already logged in — skip login)"},
      ...
    ]
  },
  {
    "id": "jp-root-tier-free",
    "description": "Login as free-tier QA account",
    "isSharedRoot": true,
    "stateOutputPath": ".tmp/jp-root-tier-free-state.json",
    "steps": [...]
  },
  {
    "id": "jp-d07a-free-tier",
    "dependsOn": "jp-root-tier-free",
    "depth": 1,
    "steps": [...]
  }
]
```

## Changes required

### 1. `cli/src/types/test-case.ts`
Add to `testCaseSchema`:
```typescript
isSharedRoot: z.boolean().optional().default(false),
stateOutputPath: z.string().optional(),   // where root writes its session
dependsOn: z.string().optional(),          // parent journey ID
depth: z.number().optional().default(0),  // 0=root, 1=direct child, 2=grandchild
```

### 2. `cli/src/index.ts`
Replace the simple sequential `for (testCase of testCases)` loop with:

```typescript
// Phase 1: build dependency graph, topological sort
const graph = buildDependencyGraph(inputs.testCases);  // Map<id, TestCase[]>
const roots = inputs.testCases.filter(tc => tc.isSharedRoot);
const orphans = inputs.testCases.filter(tc => !tc.dependsOn && !tc.isSharedRoot);

// Phase 2: execute roots first — in order
const capturedStates: Map<string, string> = new Map();  // journeyId -> stateFilePath
for (const root of [...roots, ...orphans]) {
    await runJourney(root, server, reporter, null);
    if (root.isSharedRoot && root.stateOutputPath) {
        capturedStates.set(root.id, root.stateOutputPath);
    }
}

// Phase 3: execute children, injecting parent state
const children = inputs.testCases.filter(tc => tc.dependsOn);
for (const child of children) {
    const parentStatePath = capturedStates.get(child.dependsOn!) ?? null;
    await runJourney(child, server, reporter, parentStatePath);
}
```

Add `runJourney(testCase, server, reporter, storageStatePath)` helper that wraps the current per-journey logic.

### 3. `cli/src/prompts/start-test.ts`
Accept optional `storageStatePath: string | null` parameter:

```typescript
export const startTest = (testCase: TestCase, storageStatePath: string | null = null) => {
    ...
    mcpServers: {
        "cctr-playwright": {
            type: "stdio",
            command: "node",
            args: [
                playwrightMcpCliPath(),
                "--output-dir", `${inputs.resultsPath}/${testCase.id}/playwright`,
                "--image-responses", "omit",
                "--isolated",
                ...(storageStatePath ? ["--storage-state", storageStatePath] : []),
            ],
        },
    }
}
```

For root journeys with `stateOutputPath`, add `--save-session` to MCP args so the session is automatically written to the output dir. Then the runner copies/symlinks it to `stateOutputPath`.

### 4. Root journey cleanup steps
Root journeys don't do any product-specific verification — they ONLY establish authenticated state and verify the dashboard loads. Child journeys own their own cleanup. This is expressed in the spec itself (root steps never include delete/cleanup operations).

### 5. Isolation mode: per-journey override
Add `--run-journey <id>` CLI flag to cc-test-runner. When set:
- If the named journey has a `dependsOn`, run the parent root first (silently), capture state, then run the target journey
- If the journey is a root, run it directly
- Enables: `cc-test-runner -t spec.json -o results --run-journey jp-d09-jobs-list-detail`

### 6. Cleanup tree (shared cleanup for shared ancestor)
Add `cleanupSteps` array to `TestCase` (optional). Root journeys can declare shared cleanup (logout, delete session). Runner executes cleanup ONCE after all children complete, not after each child.

```json
{
  "id": "jp-root-login",
  "isSharedRoot": true,
  "cleanupSteps": [
    {"id": 1, "description": "Navigate to /auth/logout and confirm logged out"}
  ]
}
```

## Severity inference from tree depth
- `depth: 0` (root failure) → CRITICAL — login/auth broken, ALL children blocked
- `depth: 1` (direct child) → HIGH unless it's a config/admin flow
- `depth: 2+` → MEDIUM/LOW unless description contains "payment", "billing", "data loss"
- Override: any step description matching financial/PII keywords → bump severity regardless of depth

This can be implemented in `phronex_common.testing.strategist.gap_detector` as a `_infer_severity_from_depth` helper.

## Reusability (phronex-common extraction)
The dependency graph builder + topological sort belongs in:
`phronex_common.testing.journey_graph.JourneyGraph`

Methods:
- `from_spec(spec: list[dict]) -> JourneyGraph`
- `topological_order() -> list[TestCase]`  — roots first, then children
- `get_children(root_id: str) -> list[TestCase]`
- `run_order_for_single(journey_id: str) -> list[TestCase]`  — returns [root, target] for isolated runs

This makes the same graph logic available to:
- JourneyHawk (phronex-test-runner) ← primary consumer
- CI smoke test runner (future)
- Dev-mode single-journey runner (`/Phronex_Internal_QA_JourneyHawk run jp-d09`)
- Build validation (run depth-0 roots only as smoke test)

## Files to change
| File | Repo | Change |
|------|------|--------|
| `cli/src/types/test-case.ts` | phronex-test-runner | Add 4 optional fields to schema |
| `cli/src/index.ts` | phronex-test-runner | Replace loop with graph executor |
| `cli/src/prompts/start-test.ts` | phronex-test-runner | Accept storageStatePath param |
| `cli/src/utils/args.ts` | phronex-test-runner | Add `--run-journey` flag |
| `jp-journeys/jp-deep.json` | phronex-test-runner | Restructure as tree spec |
| `src/phronex_common/testing/journey_graph.py` | phronex-common | New: graph builder + topo sort |
| `src/phronex_common/testing/strategist/gap_detector.py` | phronex-common | Add depth-based severity inference |

## Constraints
- G5: no SQLAlchemy/asyncpg in phronex-common module
- Backward compat: specs without `dependsOn` run exactly as before (orphan = standalone)
- `--isolated` flag stays on all journeys — storage state is injected at context level, not by sharing a live Chrome process
- No live browser sharing between journeys — state file only. Avoids Chrome lock conflicts.

## Expected outcome
- 12-journey JP run: ~25 min → ~8-10 min
- Auth requests: 12 → 4 (one per account tier root)
- Severity inference: automatic from tree depth
- Single-journey isolation: `--run-journey <id>` handles pre-flight automatically
