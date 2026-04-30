# Deprecated Portal Journey Specs

The following files are **smoke-only** (page loads, no state mutations) and cannot run in JourneyHawk:

- `portal-smoke.json`
- `portal-retest.json`
- `portal-debug-j01.json`

They are superseded by **`portal-admin-deep.json`** — 9 deep journeys covering all 7 admin tab groups (53 tabs) plus RBAC boundary checks for owner and user roles.

To regenerate `portal-admin-deep.json` after `adminTabs.ts` changes:
```bash
cd phronex-test-runner
source .qa.env
python scripts/generate-portal-admin-deep.py \
  --admin-tabs ../../phronex-portal/src/app/(dashboard)/admin/adminTabs.ts \
  --out portal-journeys/portal-admin-deep.json
```

To run the full portal deep audit via JourneyHawk:
```bash
cd phronex-test-runner
./run-journeyhawk.sh portal portal-journeys/portal-admin-deep.json
```
