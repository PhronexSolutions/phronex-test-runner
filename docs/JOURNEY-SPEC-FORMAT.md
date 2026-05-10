# Journey Spec JSON Format — Canonical Reference

> **Purpose:** This is the authoritative schema for journey spec `.json` files consumed by cc-test-runner.
> **Source of truth:** `cli/src/types/test-case.ts` (Zod schema). This document mirrors it for agents that generate specs.
> **CRITICAL:** Any agent generating journey specs MUST use `dependsOn`, NEVER `parentId`. The runner ignores `parentId` — journeys using it become orphans (no inherited auth state).

---

## TestCase Schema

```jsonc
{
  "id": "product-journey-name",           // REQUIRED — alphanumeric + hyphens only, regex: /^[a-zA-Z0-9-]+$/
  "description": "What this journey verifies",  // REQUIRED
  "steps": [                              // REQUIRED — array of Step objects
    { "id": 1, "description": "..." }
  ],

  // Tree structure fields (all optional)
  "isSharedRoot": false,                  // true ONLY for trunk journeys
  "role": "verify",                       // "root" | "branch" | "verify" | "teardown" | "observation"
  "stateOutputPath": ".tmp/state.json",   // ONLY on trunks — where to save Playwright storageState
  "dependsOn": "trunk-journey-id",        // ⚠️ MUST be "dependsOn" — NEVER "parentId"
  "depth": 1,                             // 0=trunk, 1=branch, 2=leaf (internal classification)
  "params": {},                           // key-value params passed to the journey

  // Optional advanced fields
  "cleanupSteps": [],                     // Steps to run on teardown
  "persistence": {                        // Data persistence verification
    "after_step": "...",
    "navigate_away": "...",
    "navigate_back": "...",
    "assert": "..."
  },
  "dirty_state": [],                      // Dirty-state scenarios
  "human_required": {                     // Marks journey as needing human interaction
    "reason": "captcha",                  // mic_input | video_watch | captcha | biometric | visual_verify | physical_action
    "instruction": "...",
    "max_seconds": 30,
    "after_step": "..."
  }
}
```

## Step Schema

```jsonc
{
  "id": 1,                                // OPTIONAL — numeric step identifier
  "description": "What to do and verify",  // REQUIRED — the runner's LLM reads this
  "status": "pending",                     // "pending" | "passed" | "failed" — set by runner
  "error": "...",                          // Set by runner on failure
  "action": "..."                         // Optional action hint
}
```

---

## Tree Linking — The `dependsOn` Field

The cc-test-runner resolves journey execution order as a DAG using `dependsOn`:

```
Trunk (depth 0, isSharedRoot: true)
  └── dependsOn → Branch (depth 1)
        └── dependsOn → Leaf (depth 2)
```

- **Trunks** save Playwright `storageState` to `stateOutputPath`
- **Branches/leaves** inherit auth state by loading their parent's `storageState`
- The runner walks `dependsOn` chains: `cli/src/index.ts:145-146`
- `parentId` is NOT in the Zod schema — any journey using it becomes an orphan

### Common mistake

```jsonc
// ❌ WRONG — parentId is ignored by the runner
{ "id": "my-journey", "parentId": "my-trunk", ... }

// ✅ CORRECT — dependsOn is resolved by the DAG
{ "id": "my-journey", "dependsOn": "my-trunk", ... }
```

### Cross-product evidence

| Spec file | `dependsOn` count | `parentId` count |
|-----------|-------------------|------------------|
| portal-tree.json | 19 | 0 |
| comc-deep.json | 64 | 0 |
| jp-deep.json | 22 | 0 |
| cc-tree.json | 42 | 0 |

All products use `dependsOn`. Zero `parentId` anywhere.

---

## Non-Browser Executors

Journeys with `executor` field (not in the Zod schema but used by `run-journeyhawk.sh`) route to non-browser runners:

| Executor value | Runner | What it does |
|---------------|--------|-------------|
| `http` | `dispatch_non_browser_journeys` | Direct HTTP API calls via httpx |
| `db` | `dispatch_non_browser_journeys` | Direct database queries via psycopg2 |
| `playwright` (default) | cc-test-runner CLI | Browser-based Playwright journeys |

---

## Placeholder Substitution

`run-journeyhawk.sh` performs sed replacement before running. **Use the exact bare sentinel strings below — NOT dunder-wrapped `__X__` format.**

| Sentinel string (use verbatim) | Replaced with | Source |
|--------------------------------|--------------|--------|
| `http://localhost:3002` | `$PORTAL_URL` (default: `https://app.phronex.com`) | `.qa.env` or shell |
| `QA_SUPERADMIN_PASSWORD` | `$PHRONEX_PORTAL_TEST_PASSWORD` | `.qa.env` |
| `qa-test-journeyhawk@phronex.com` | `$PHRONEX_PORTAL_TEST_EMAIL` | `.qa.env` |
| `QA_OWNER_EMAIL` | `$QA_OWNER_EMAIL` | `.qa.env` |
| `QA_OWNER_PASSWORD` | `$QA_OWNER_PASSWORD` | `.qa.env` |
| `QA_USER_EMAIL` | `$QA_USER_EMAIL` | `.qa.env` |
| `QA_USER_PASSWORD` | `$QA_USER_PASSWORD` | `.qa.env` |

**❌ WRONG** (dunder format — not recognised by the sed step):
```jsonc
"Navigate to __PORTAL_URL__ and enter password __QA_PORTAL_PASSWORD__"
```

**✅ CORRECT** (bare sentinel — sed replaces these at runtime):
```jsonc
"Navigate to http://localhost:3002 and enter password QA_SUPERADMIN_PASSWORD"
```

The `{{paramName}}` double-curly syntax is a separate mechanism resolved by the TypeScript `resolveParams()` from a journey's `params: {}` object — it is NOT the same as shell credential injection.
