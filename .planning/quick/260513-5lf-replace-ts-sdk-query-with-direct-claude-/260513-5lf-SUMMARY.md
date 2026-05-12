---
quick_id: 260513-5lf
status: complete
---

# Summary: Replace TS SDK query() with direct claude -p subprocess

## What changed

Removed the `@anthropic-ai/claude-code` SDK dependency from the test runner and replaced the `query()` call in `start-test.ts` with a direct `claude -p` subprocess spawn.

## Files modified

| File | Change |
|------|--------|
| `cli/src/prompts/start-test.ts` | Rewrote `startTest()` to spawn `claude -p --output-format stream-json` directly instead of calling `query()` from the SDK |
| `cli/package.json` | Removed `@anthropic-ai/claude-code` and `@anthropic-ai/sdk` dependencies |
| `cli/bun.lock` | Updated lockfile (2 packages removed) |

## Key design decisions

- **AsyncGenerator contract preserved**: `index.ts` still does `for await (const message of startTest(...))` — zero changes to the orchestrator
- **MCP config via temp file**: Written to `/tmp/ptr-mcp-{journeyId}-{timestamp}.json`, cleaned up in `finally` block
- **OAuth enforcement**: `ANTHROPIC_API_KEY` stripped from subprocess env (matches `run-journeyhawk.sh` line 43)
- **`--strict-mcp-config`**: Fails fast if state/playwright MCP servers can't connect
- **stderr captured**: Non-zero exit codes logged with stderr content for diagnostics

## What was NOT changed

- `index.ts` — orchestrator (topo sort, state server, reporter, storage state) unchanged
- `system.ts` — system prompt unchanged
- `server.ts` — MCPStateServer unchanged
- MCP server names (`cctr-playwright`, `cctr-state`) — kept as-is (rename is a separate task)
- `run-journeyhawk.sh` — unchanged

## Verification

- `bun build` succeeds (402 modules, 0 errors)
- No imports from `@anthropic-ai/claude-code` or `@anthropic-ai/sdk` remain
- Lint errors reduced from 10 to 7 (all pre-existing patterns)
