# Deprecated Portal Journey Specs

## Deprecated (smoke-only — superseded by portal-tree.json)

The following files are **smoke-only** (page loads, no state mutations) and cannot run in JourneyHawk:

- `portal-smoke.json` — DEPRECATED: first-generation spec, localhost:3002 URLs, plaintext credentials
- `portal-retest.json` — DEPRECATED: one-off retest file, not a live spec
- `portal-debug-j01.json` — DEPRECATED: debug-only, single-step

## Current Specs

| File | Journeys | Purpose |
|------|----------|---------|
| `portal-tree.json` | 20 nodes (tree) | **Active** — full portal test suite with trunk/branch/leaf model |
| `portal-admin-deep.json` | 9 journeys | Admin panel BSC groups (53 tabs) — still valid, runs standalone |
| `portal-deep.json` | 12 journeys | Pre-tree deep spec — still valid for regression |
| `portal-deep-extended.json` | Praxis/extra | Extension journeys — partially superseded by portal-tree.json Praxis leaf |

## Running the portal suite

```bash
# Full portal run with intelligence pipeline:
./run-journeyhawk.sh portal portal-journeys/portal-tree.json

# Smoke run — superadmin auth check only (no intelligence pipeline):
./cli/cc-test-runner -t portal-journeys/portal-tree.json -o results-smoke-portal --runJourney portal-trunk-superadmin

# Owner RBAC smoke:
./cli/cc-test-runner -t portal-journeys/portal-tree.json -o results-smoke-owner --runJourney portal-trunk-owner
```

## Regenerate portal-admin-deep.json after adminTabs.ts changes

```bash
cd phronex-test-runner
source .qa.env
python scripts/generate-portal-admin-deep.py \
  --admin-tabs ../../phronex-portal/src/app/(dashboard)/admin/adminTabs.ts \
  --out portal-journeys/portal-admin-deep.json
```
