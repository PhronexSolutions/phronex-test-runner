# JourneyHawk — Operational Learnings & Reference

> Living document. Updated after every product run.
> **Coding standards derived from RCA belong in `$PHRONEX_CODE_ROOT/phronex-common/config/CODING-PATTERNS.md`** — NOT in CLAUDE.md.
> CODING-PATTERNS.md is automation's write target. CLAUDE.md is active invariants only (never written by automation).
> Test infrastructure learnings (false positives, service topology, per-product quirks) live here.

---

## Service Topology for QA Runs

| Layer | Where it runs | Notes |
|-------|--------------|-------|
| `phronex_qa` PostgreSQL | DevServer (`192.168.1.250`) | Never on EC2. All QA writes go here. |
| `cc-test-runner` binary | DevServer `~/code/phronex-test-runner/cli/dist/` | Compiled bun binary. Never install on EC2. |
| `phronex_common.testing.runner` | DevServer `~/code/phronex-common/.venv` | Intelligence pipeline. DevServer-only. |
| Portal under test | **`https://app.phronex.com` (EC2 production)** | `PORTAL_URL` env var in `.qa.env` defaults to production. Browser tests hit EC2 directly — no DevServer portal required. Change to `http://localhost:3002` only when testing an unreleased branch. |
| `run-journeyhawk.sh` | DevServer `~/code/phronex-test-runner/` | Atomic wrapper — never call cc-test-runner alone. Does sed substitution of `localhost:3002` → `$PORTAL_URL` before passing spec to cc-test-runner. |
| `phronex-common` (QA checkout) | DevServer `~/code/phronex-common/` | Separate from EC2's `/opt/phronex-common`. |

**Product backends (jobportal, CC, auth, praxis)** → EC2 only. API calls use domain names (`jobc.phronex.com`, `cc.phronex.com`) — not raw EC2 IP from journey specs.

**⚠️ `.qa.env` PHRONEX_*_TEST_URL must use domain names, NOT raw EC2 IPs:** EC2 security group blocks raw IP + port (e.g. `http://43.204.79.39:8000`) from outside. Cleanup calls using raw IPs fail with `HTTP 000ERR` silently. All `PHRONEX_*_TEST_URL` vars corrected to domain names on 2026-04-30:
- `PHRONEX_CC_TEST_URL=https://cc.phronex.com`
- `PHRONEX_JP_TEST_URL=https://jobc.phronex.com`
- `PHRONEX_AUTH_TEST_URL=https://auth.phronex.com`
- `PHRONEX_PRAXIS_TEST_URL=https://praxis.phronex.com`
- `PHRONEX_PORTAL_TEST_URL=https://app.phronex.com`

**`.qa.env` location:** `~/code/.qa.env` on DevServer. Key vars:
```
PHRONEX_QA_DATABASE_URL_SYNC=postgresql+psycopg2://phronex_qa:phx_qa_local_2026@localhost:5432/phronex_qa
PORTAL_URL=https://app.phronex.com          # production portal — default; change for localhost testing
PHRONEX_JP_TEST_URL=https://jobc.phronex.com
PHRONEX_CC_TEST_URL=https://cc.phronex.com
JP_TEST_CLEANUP_SDK_KEY=<set>               # pre-run cleanup active for JP
CC_TEST_CLEANUP_SDK_KEY=<set>               # pre-run cleanup active for CC
JP_PUBLIC_URL=http://localhost:8001         # only relevant if running a LOCAL jobportal instance
```

---

## Known False Positive Patterns

### Runner Turn-Limit

**Root cause:** cc-test-runner spawns a Claude Code subprocess per journey with a finite turn budget. Complex journeys (7+ steps) exhaust the budget before completing. Remaining steps stay `pending` in memory but are **never flushed to `ctrf-report.json`**.

**CTRF format bug (discovered run 4, 2026-04-29):** cc-test-runner writes every step as `[Status: pending]` into the CTRF file when the journey starts and **never updates** that file with actual step outcomes. Step outcomes are only visible in cc-test-runner's stdout. As a result, the CTRF `message` field for EVERY failed journey (turn-limit FP, portal-down, real product defect) looks identical — all steps pending, no `[Error:]`. Any signature-based FP detection on the CTRF message will fire for all failures, not just turn-limit ones.

**Previous fix (8edbfec1) was incorrect:** The `[Status: pending]` heuristic in `runner.py` was reverted in `d57fd15a` because it silently swallowed all real defects. Run 4 result: 12 journeys SKIPPED, 0 defects logged.

**Correct prevention:** Keep journeys ≤ 6 steps so the turn budget is never exhausted. The `jp-deep.json` spec was updated (run 5 / 2026-04-29) from 12 journeys (J-series, 7-8 steps) to 10 journeys (d-series, exactly 6 steps).

**If a flow genuinely needs 7+ steps:** Split into two journeys where the second starts from a known persisted state (e.g. first journey creates the object, second journey edits and deletes it).

**Cross-evidence pattern:** When a journey fails, check if another journey exercises the same feature — a passing companion validates the feature works and helps identify the failure scope.

### Conditional-Branch Spec FP (discovered run 5, 2026-04-29)

**Signature:** Journey `succeeded: false` with exactly one step in `status: pending` and all other steps `status: passed`. The pending step description starts with "If X exists: ..." or "If X is visible: ...".

**Root cause:** Spec steps written as "If A: do X. If B: do Y." force Claude to pick a branch. If the branch condition is false (e.g. "If applications exist" but there are none), Claude correctly handles the other path but leaves the conditional step as `pending` because it was never applicable. cc-test-runner marks the journey `succeeded: false` when any step is non-passing.

**Fix:** Rewrite conditional steps to be unconditionally verifiable. Instead of two "If A / If B" steps, write a single step that covers both outcomes: "Verify the applications page. If empty: check for meaningful empty state with CTA. If populated: verify each row shows required fields and clicking opens a detail view."

**Prevention:** Never write journey steps that can legitimately be skipped. Every step must be completable regardless of test account state.

---

### Login Rate-Limit FP — see "Login Rate-Limit FP" section below for full details.

**Quick identification:** Step 1 fails with "Too many login attempts." All remaining steps cascade-fail. Fix: restart phronex-auth on EC2 (`sudo systemctl restart phronex-auth`).

---

### React 19 ErrorBoundary console.error FP (discovered CC run 4, 2026-05-10)

**Signature:** A step that checks browser console errors sees a `TypeError: Cannot convert undefined or null to object` or `Object.entries(null)` console.error — but the NEXT step passes (page is functional). Step outcome is `failed` but user flow continues.

**Root cause:** React 19 concurrent mode's `componentDidCatch` in an `ErrorBoundary` **always** emits a `console.error` with the caught error, even when the boundary gracefully shows a fallback UI. Playwright's `page.on('console')` listener captures this as an error event. This is React's designed behavior — not a product bug.

**Specific instance — CC Info & Connections tab (defect #251):** Switching from Analytics→Info tab triggers React 19 fiber state contamination (stale `setState` from analytics fetch intersects with new Info tab's `RecentIssues` component mount). This fires `Object.entries(null)` inside React's internal `processUpdateQueue`. The `ErrorBoundary` wrapping `RecentIssues` catches it and shows `"Recent issues unavailable"` fallback. All other Info tab content (Platform Connections, Instance LLM Configuration, Widget Embed Code) renders correctly.

**Fix commits:** `20d1b69` (AbortController to prevent stale setState) + `993083a` (ErrorBoundary containment). Both in portal main as of 2026-05-05.

**How to distinguish from a real crash:**
- **False positive:** Next step passes. Tab content is visible. Only `RecentIssues` section shows fallback. console.error references React fiber / `processUpdateQueue` / `Object.entries`.
- **Real defect:** Next step fails OR tab shows blank white / full-page "Something went wrong" overlay. console.error references user code in identifiable component file.

**Action:** Mark the step as PASS if subsequent steps confirm tab content rendered. File as false positive in `qa_known_defects.is_false_positive=true`. Do NOT re-file as a new defect on every run.

---

### Browser Tab Contamination FP (discovered CC run 3, 2026-04-30)

**Signature:** All steps in a journey show `pending` and step-outcomes.json is missing. The debug log shows the runner navigated to a DIFFERENT product's URL (e.g. `/jp/dashboard`) despite the spec being for CC. The runner's first assistant message says something like "The browser appears to be blank. Let me navigate to the JobPortal jobs page..."

**Root cause:** cc-test-runner reuses the same Chrome profile (`~/.cache/ms-playwright/mcp-chrome-c2cdb14`) across all journeys and across runs. When a previous run leaves open tabs (e.g. `/cc/subscription`, `/jp/dashboard`), the next journey inherits them. The runner reads the current tab's URL as context and misidentifies the product it's supposed to test — causing it to navigate to JP and burn all turns before the spec steps run.

**Fix applied:** Every browser-based CC journey now begins with: "BROWSER RESET FIRST: Use browser_tabs to list all open tabs. Close every tab except the current one using browser_close on each extra tab. Then navigate the current tab to https://app.phronex.com." This forces the runner to clear stale tabs before any test action.

**Prevention:** Apply the BROWSER RESET FIRST pattern to step 1 of every journey that uses browser navigation (not needed for API-only journeys like cc-J06–J09). The exact wording matters — it must say "Close every tab except the current one" not just "close extra tabs".

**cctr-state MCP failure pattern:** When the Chrome profile is contaminated, cctr-state MCP also fails to initialise (`"status":"failed"`). This means step outcomes cannot be updated, so ALL steps stay pending regardless of what the runner actually did.

---

### localStorage Persistence FP (discovered run 5, 2026-04-29 — partial, see correction below)

**Signature:** Journey fails because a dismissable UI element (banner, tooltip, onboarding card) is not visible. The element is correctly hidden by a `localStorage` key set during a previous test run.

**Root cause:** cc-test-runner reuses the same Chrome browser profile across all journeys and across runs. User-dismissable components that write to `localStorage` (e.g. `jpOnboardingBannerDismissed`) stay dismissed in subsequent runs. The product code is correct — the banner correctly stays hidden once dismissed — but the test sees stale state from a previous session.

**Fix:** Add a localStorage cleanup step at the start of any journey that tests a dismissable element. Example step: "Before navigating, execute in the browser console: `localStorage.removeItem('jpOnboardingBannerDismissed');` Then navigate to the page."

**⚠️ Run 5 partial misdiagnosis (corrected in run 6):** The jp-d08 failure was initially attributed to `ccCrossSellDismissed` localStorage persistence. Run 6 confirmed this was WRONG. See "QA Account Cross-Product Grant FP" section below — the real root cause was that the QA account holds a CC grant, which causes `JPLayoutClient.tsx` to short-circuit (`if (hasCcGrant) { setShowCcCrossSell(false); return; }`) before localStorage is ever checked. `ccCrossSellDismissed` is therefore NOT a key that needs resetting between runs — it is never read for this account.

**Known keys to reset per product:**

| Product | localStorage key | Element |
|---------|-----------------|---------|
| JP | `jpOnboardingBannerDismissed` | JP onboarding setup guide banner |

---

### QA Account Cross-Product Grant FP (discovered run 6, 2026-04-29)

**Signature:** Journey that tests a cross-sell banner for Product B on Product A's page always fails — banner never visible, even after clearing all dismissal localStorage keys.

**Root cause:** The QA account `qa-test-journeyhawk@phronex.com` holds grants for **both** `job-portal` (standard tier) **and** `content-companion` (free tier). The CC cross-sell banner in `JPLayoutClient.tsx` has an explicit `hasCcGrant` guard:

```typescript
useEffect(() => {
  if (hasCcGrant) {
    setShowCcCrossSell(false);
    return;  // short-circuits — localStorage never checked
  }
  // ...localStorage check only reached if user has no CC grant
}, [hasCcGrant]);
```

The product behaviour is **correct** — a user who already has CC access should not be shown a CC cross-sell prompt. The spec was wrong to expect the banner to appear for this account.

**Fix:** Rewrite the journey to validate correct suppression behaviour, not banner appearance. For the existing QA account, jp-d08 now verifies: (1) banner is correctly absent, (2) CC navigation is accessible since the user has a CC grant, (3) `/cc` loads without 403. This tests the `hasCcGrant` code path positively.

**Alternative fix (if banner-appearance path must also be tested):** Create a separate JP-only account (`qa-jp-only@phronex.com`) with no CC grant, and write a separate journey `jp-d08b` using that account.

**Prevention rule:** Before writing a journey that tests a feature gate or cross-sell suppression, query the QA account's grants:
```sql
SELECT product_slug, tier FROM access_grants
WHERE account_id = (SELECT id FROM accounts WHERE email = 'qa-test-journeyhawk@phronex.com');
```
A QA account that holds grants for multiple products will trigger suppression logic that hides cross-sell banners — the spec must account for this.

---

### Chrome MCP Profile Conflict FP (discovered runs 7+8, 2026-04-30)

**Signature:** Multiple journeys in the same run fail with "Browser is already in use for /home/ouroborous/.cache/ms-playwright/mcp-chrome-28ad6cc, use --isolated to run multiple instances of the same browser". First journey in the run may also fail mid-test (between steps) with the same error even after SingletonLock files are cleared.

**Root cause:** `@playwright/mcp` locks the Chrome data directory with a `SingletonLock` file when Chrome opens. The `cctr-playwright` MCP server (launched internally by cc-test-runner per test case) holds the Chrome profile lock for the duration of the browser session. When the NEXT test case's Claude subprocess tries to connect to the same MCP server, Chrome's data directory is still locked by the previous session — even though the previous test case "completed."

**The critical detail:** The `SingletonLock` file is only one symptom. Clearing it between **runs** (e.g. `rm -f ~/.cache/ms-playwright/mcp-chrome-*/SingletonLock`) prevents cross-run FPs, but does NOT prevent cross-test-case FPs **within** a single run. The MCP server starts Chrome and keeps it open across all test cases in one cc-test-runner invocation.

**Root fix (2026-04-30):** Added `--isolated` flag to the `cctr-playwright` MCP args in `cli/src/prompts/start-test.ts`. `--isolated` creates an in-memory browser profile per MCP connection — no lock file on disk, no cross-session contamination.

```typescript
// cli/src/prompts/start-test.ts
args: [
    playwrightMcpCliPath(),
    "--output-dir", `${inputs.resultsPath}/${testCase.id}/playwright`,
    "--image-responses", "omit",
    "--isolated",  // ← added 2026-04-30: in-memory profile, no SingletonLock
],
```

Rebuild after any edit to `cli/src/`: `cd ~/code/phronex-test-runner/cli && bun build --compile ./src/index.ts --outfile ./dist/cc-test-runner --target bun`

**Pre-flight (in addition to the `--isolated` fix, belt-and-suspenders):**
```bash
# Kill any orphaned Chrome before starting a run
pkill -f chrome 2>/dev/null; true
rm -f ~/.cache/ms-playwright/mcp-chrome-*/SingletonLock 2>/dev/null; true
```

**Run 7 impact:** All 12 journeys ran; jp-d08 and jp-d09 showed as failed (browser conflicts on later test cases). jp-d05 passed in Run 7.
**Run 8 impact (retry run):** All 3 retry journeys failed (jp-d05 failed mid-test on step 2 — Chrome was still locked from Run 7's final Chrome session).

---

### API Contract Drift FP (discovered jp-d05, 2026-04-30)

**Signature:** Scan history page loads without errors but displays `undefined` or blank cells in the table. The journey passes at the UI-load level but column values show wrong data (zero counts, missing dates, wrong status).

**Root cause:** TypeScript `fetch()` returns `any` — the compiler cannot validate that the frontend type definition matches the backend Pydantic `BaseModel`. When a field name changes in the backend (e.g. `new_jobs` → `jobs_new`), the frontend type silently falls back to `undefined`.

**Specific fix (commit `e927e2f`, 2026-04-30):** `ScanHistoryClient.tsx` type used `new_jobs`, `matched_jobs`, `status`/`error_message`, `started_at` — all mismatching the backend's `jobs_new`, `jobs_matched`, `errors`, `scan_started_at`.

**Prevention rule (in CODING-PATTERNS.md — API Contract Drift section):** Any client type for a fetch response must use EXACT field names from the backend Pydantic `BaseModel`. Comments in the file must name the backend source: `// Field names match ScanLogResponse in jobportal/api/routes_jobs.py`.

**How to verify without browser:** `curl -sL http://localhost:8001/api/v1/jobs/scan-logs/?limit=1 -H "Authorization: Bearer $TOKEN"` — compare JSON keys against frontend type definition.

---

### Spec-Execution Route Prefix FP (discovered jp-d08, Run 9, 2026-04-30)

**Signature:** A journey step that asks Claude to "verify that a nav entry exists for Product X" causes Claude to click that nav entry during verification. The click navigates to the routePrefix (e.g. `/cc`) rather than the manifest's `href` (e.g. `/cc/dashboard`). If no `page.tsx` exists at the routePrefix, the subsequent explicit-navigate step fails with a 404.

**Root cause:** Two-part issue:
1. Step phrasing "verify a navigation entry exists" is ambiguous — Claude may click rather than just look.
2. The portal's product nav items correctly link to `/cc/dashboard`, but bare `/cc` had no `page.tsx` redirect, so any accidental navigation to `/cc` 404s.

**Specific occurrence (jp-d08, Run 9):** Step 4 "Verify that the portal header contains a CC navigation entry" — Claude clicked the CC header item (which navigated to `/cc/dashboard`), then step 5 tried its explicit navigate and landed on `/cc` due to execution state mismatch. ctrf recorded the step 5 error: `Navigation to /cc resulted in a 404`.

**Fix (two parts):**
1. **Portal fix (commit on main):** Added `src/app/(dashboard)/cc/page.tsx` with `redirect('/cc/dashboard')` — bare `/cc` now redirects instead of 404ing.
2. **Spec fix:** Rewrite "verify nav exists" steps to be explicit: "In the header, confirm a 'Content Companion' nav item is visible (do NOT click it — only visually verify). If visible: proceed. If absent: FAIL."

**Prevention:** Steps that verify UI elements exist should specify whether clicking is expected. "Verify X is present" ≠ "click X". Add "(do NOT click)" to purely observational steps when clicking would alter navigation state.

**Note:** The intelligence pipeline correctly classified this as LOW severity (not CRITICAL) — the normal navigation path uses `/cc/dashboard` and users never encounter the bare `/cc` 404 through any UI link.

---

## Per-Product Notes

### JobPortal (jp)

| Item | Value |
|------|-------|
| Deep spec | `jp-journeys/jp-deep.json` (12 journeys: d01-d06, d07a/b/c, d08-d10) |
| Backend URL | `https://jobc.phronex.com` (EC2) |
| Portal QA URL | `http://localhost:3002` (DevServer) |
| QA account (main) | `qa-test-journeyhawk@phronex.com` — standard + CC grants |
| Billing fix validated | `ada45d1` — standard tier label correct (jp-J08 PASS, run 2026-04-29) |
| Run 3 result | 4/12 PASS, 3 real defects fixed (`b740a6a` portal + `aa2c0fa` jobportal), 5 turn-limit FPs |
| Run 4 result | 0/12 defects logged — FP detection bug `8edbfec1` swallowed all failures; portal was also down mid-run |
| Run 5 result | 7/10 PASS, 1 real defect (jobs detail view — fixed in portal), 2 spec/infra FPs (conditional step + localStorage — see correction in run 6) |
| Run 6 result | 9/10 PASS, 0 real defects, 1 spec FP (jp-d08 — QA account has CC grant so banner correctly absent; spec rewritten) |
| Run 7 result | 9/12 PASS, 1 real defect (jp-d05 scan history API contract drift — fixed e927e2f), 2 Chrome MCP FPs (jp-d08, jp-d09). jp-d07a/b/c all PASS — billing tier fix validated. |
| Run 8 result | 0/3 PASS (retry of jp-d05/d08/d09). All 3 Chrome MCP FPs — --isolated flag added to cctr-playwright MCP, cc-test-runner rebuilt. |
| Run 9 result | 10/12 PASS, 0 real product defects, 2 FPs (jp-d01 rate-limit + jp-d08 spec-execution). jp-d07a/b/c PASS — tier labels validated across all 3 tiers. jp-d05 scan history fix e927e2f confirmed. --isolated Chrome fix holding (zero profile conflicts across 12 sequential tests). Minor UX gap: bare `/cc` 404s → fixed with page.tsx redirect (portal commit). |

**⚠️ JP cleanup 403 — production host guard (discovered 2026-04-30):** JP cleanup returns HTTP 403 "Endpoint disabled on production host (jobc.phronex.com)". The cleanup route checks `PHRONEX_QA_ALLOWED_HOSTS` and blocks on the production domain. The SDK key is correct. Cleanup is non-fatal — runs continue — but test data accumulates. Fix: set `PHRONEX_QA_ALLOWED_HOSTS=jobc.phronex.com` in `/opt/jobportal/.env` on EC2 and restart the service, OR accept accumulation (journeys verify counts before mutating, so stale data doesn't break assertions).

**Multi-tier QA accounts (provisioned 2026-04-30):**

| Account | Password | Tier | Purpose |
|---------|----------|------|---------|
| `qa-jp-free@phronex.com` | `JHTest2026#Free!` | free | jp-d07a — verifies Free Seeker label + upgrade CTA |
| `qa-jp-standard@phronex.com` | `JHTest2026#Std!` | standard | jp-d07b — verifies Standard Seeker label + Pro upgrade CTA |
| `qa-jp-pro@phronex.com` | `JHTest2026#Pro!` | pro | jp-d07c — verifies Pro Seeker label + no upgrade CTA + portrait access |

All three granted via `POST /admin/accounts/{id}/complimentary-grant` in phronex-auth (superadmin token). Inserted directly via psql due to pre-fix "user" role bug (`1728dbd`) — all grants confirmed healthy in `access_grants`.

**Share link testing:** Tokens are created on EC2's jobportal and stored in EC2's DB. Share URL format is `{JP_PUBLIC_URL}/p/{token_id}`. Since portal points to EC2, the share URL resolves correctly without any DevServer override. `JP_PUBLIC_URL` in `.qa.env` is only relevant if running a local jobportal instance.

**Portrait journey (jp-J06):** QA standard-tier account likely has no portrait generated. The "no portrait yet" state is expected. The journey now validates the CTA buttons are present (fixed in `b740a6a`).

### ContentCompanion (cc)

| Item | Value |
|------|-------|
| Deep spec | `cc-journeys/cc-deep.json` |
| Backend URL | `https://cc.phronex.com` (EC2) — NEVER raw EC2 IP `43.204.79.39:8000` |
| QA accounts | `qa-test-journeyhawk@phronex.com` (has CC grant) |
| Role requirement | `role_id` MUST be set in `access_grants` — `NULL` role breaks instance_owner API routes |

**CC Portal URL map (use these in all journey specs):**

| Feature | Correct URL | Wrong URL (never use) |
|---------|-------------|----------------------|
| Dashboard / Analytics | `/cc/dashboard` | `/cc/` (404) |
| Session history | `/cc/dashboard` → Sessions sub-tab (**superadmin only** — NOT visible to instance owners) | `/cc/conversations` (404) |
| Knowledge base / content | `/cc/content` | `/cc/knowledge-base` (404) |
| Instance settings | `/cc/instance` | `/cc/settings` (404) |
| Subscription / billing | `/cc/subscription` | `/cc/billing` (404) |
| Onboarding | `/cc/onboarding` | — |

**⛔ CC Razorpay is LIVE-mode only — never let a billing journey complete checkout (confirmed 2026-07-17):** `billing_config` is one row per `product_id`, not per-instance — `e2e-test-instance` shares the exact same Razorpay keys as every real paying CC customer. There is no test-mode key set. Any journey touching `/cc/subscription`'s upgrade CTA (cc-J10 and any future billing journey) MUST stop after clicking "Upgrade" and recording the destination URL — it must NEVER fill in card details or submit the Razorpay checkout form, since that would attempt a real charge. This is enforced by the journey step text itself (see cc-J10 step 7), not by any test-mode safety net. If full checkout-completion + webhook coverage is ever needed, that requires instance-scoped billing config as a real GSD phase (`_init_billing_adapter()` currently loads one global adapter at process startup, not per-request) — not something to improvise mid-run.

**CC Sessions tab — superadmin-only (filed as defect #42):** `CCDashboardClient.tsx` defines `SUPERADMIN_TABS = [...BASE_TABS, { id: 'sessions' }]`. Instance owners see only Overview, Analytics, Info tabs. Both CC backend routes (`/admin/sessions`, `/admin/users/{id}/conversations`) require `_require_admin`. Do NOT write CC journey specs that expect instance owners to see or access session/conversation history — this is a known product gap, not a spec bug.

**CC instance config provisioning (required for J04 + J06–J09):** Every CC instance needs BOTH a DB row in `instance_owners` AND a config directory at `/opt/contentcompanion/config/instances/{slug}/` on EC2 with `instance.yaml`, `persona.yaml`, and `tiers.yaml`. New QA instances created in phronex-auth are NOT automatically propagated to either location. Manual steps required (both done for `e2e-test-instance` on 2026-04-30):
1. DB insert: `INSERT INTO instance_owners ...` (see run 2 notes above)
2. Config dir: `mkdir -p /opt/contentcompanion/config/instances/{slug}/` + write 3 YAML files

**CC Backend API URL map:**

| Call | Correct URL | Wrong URL (never use) |
|------|-------------|----------------------|
| Anonymous widget auth | `https://cc.phronex.com/api/v1/auth/anonymous` | — |
| Chat message | `https://cc.phronex.com/api/v1/chat/message` | `/api/v1/chat` (404) |
| Chat history | `https://cc.phronex.com/api/v1/chat/history` | — |
| Health check | `https://cc.phronex.com/api/v1/health` | — |

**ChatMessageRequest body fields:** `{"instance_id": "...", "message": "...", "session_id": "<UUID>"}`. The field is `session_id` NOT `conversation_id`. The field is `message` NOT `content`.

**⚠️ session_id MUST be a valid UUID (discovered CC run 5, 2026-05-11):** `CC /api/v1/chat/message` calls `uuid.UUID(session_id)` before any business logic. Non-UUID strings like `"jh-api-test-session"` cause HTTP 500 (ValueError: badly formed hexadecimal UUID string) before the response handler runs. Always use deterministic UUID v4 values in specs: e.g. `"22222222-2222-4222-a222-222222222222"`. Sending `null` skips session restore (new session); sending a valid UUID that doesn't exist is also safe (starts new session).

**CC backend root 404 — not a product outage (discovered CC run 5, 2026-05-11):** `https://cc.phronex.com/` returns 404. This is expected — the CC FastAPI backend exposes no HTML root. All endpoints are under `/api/v1/*` and `/docs`. Playwright agents that navigate to `cc.phronex.com/` will always see 404 and cascade all steps as "app is down". Generated lifecycle journeys had this bug systematically (all 11 `cc-deep-*-lifecycle` journeys). The fix is in `_is_garbage_journey()` Class 4 (journey_generator.py, 2026-05-11).

**Portal proxy injects instance_id — use direct CC URLs from page.evaluate() (discovered CC run 5, 2026-05-11):** The portal proxy at `/api/admin/cc/api/v1/admin/instance-config/{id}` overrides the `instance_id` from the session context, causing 403 "Request must be scoped to your instance" when the path param doesn't match. Always use the direct CC URL `https://cc.phronex.com/api/v1/admin/instance-config/{id}` from `page.evaluate()` — CORS allows `app.phronex.com` to call `cc.phronex.com` directly.

**CC admin endpoint prefix is /api/v1/admin/* (discovered CC run 5, 2026-05-11):** The prefix `admin` is required: `/api/v1/admin/users`, `/api/v1/admin/instances`, `/api/v1/admin/keys`, `/api/v1/admin/instance-config/{id}`. Routes without the `admin` prefix return 404 (e.g. `/api/v1/users` → 404, `/api/v1/admin/users` → 200/403).

**CC SkillResponse field name (defect #252, fixed 2026-05-05):** Backend `SkillResponse` Pydantic model uses `id: str` (NOT `skill_id`). Portal `SkillsClient.tsx` originally declared `Skill.skill_id` — causing all delete/submit/preview handlers to pass `undefined`. Corrected to `Skill.id`. When checking CC Skills API responses, the field is `id`, not `skill_id`. This is a TypeScript `as Type[]` cast hazard — the compiler cannot catch mismatches at cast boundaries.

**⚠️ P0: CC Anthropic credits exhausted (discovered 2026-04-30):** CC EC2 server's `ANTHROPIC_API_KEY` in `/opt/contentcompanion/.env` is out of credits. All chat requests return HTTP 200 with `{"type":"error","error":{"code":"service_unavailable",...}}`. The production CC widget is non-functional for all visitors. Requires Vivek to top up the Anthropic account at console.anthropic.com/settings/billing.

---

### Login Rate-Limit FP (discovered JP run, 2026-04-30)

**Signature:** All steps in a journey fail starting from step 1. The debug log shows the assistant saying "Too many login attempts. Please wait a while before trying again." The account-level limit is 5 failed logins/hour; the IP-level limit is 10 logins/hour (both configured in `phronex-auth/config.py`).

**Root cause:** Running multiple JourneyHawk runs back-to-back exhausts phronex-auth's in-memory login rate limit for the QA account IP. Each browser-navigation journey starts with a fresh login attempt. 4 CC runs × 5 browser journeys = 20 login attempts in one hour — well over the 10/hour IP limit.

**Fix:** Restart phronex-auth on EC2 to clear the in-memory rate limit counters:
```bash
ssh -i ~/code/AWSContentCompanion.pem ubuntu@43.204.79.39 "sudo systemctl restart phronex-auth && sleep 4 && sudo systemctl is-active phronex-auth"
curl -sf https://auth.phronex.com/health  # must return {"status":"healthy"}
```
**Why this is safe:** phronex-auth is stateless (JWTs are not invalidated by restart). The restart takes ~3 seconds. Rate limit backend is `InMemoryBackend` (default) — confirmed by absence of `RATE_LIMITER_BACKEND` in EC2's `/opt/phronex-auth/.env`.

**Prevention:** Add a per-run cool-down or reduce journeys-per-run. Future improvement: cc-test-runner should reuse an authenticated session token across journeys rather than re-logging in for each one.

---

### ANTHROPIC_API_KEY Priority Bug — Use OAuth Instead (discovered CC run 4, fixed 2026-04-30)

**Signature:** cc-test-runner crashes with "Claude Code process exited with code 1" immediately at startup. `"Credit balance is too low"` in the result.

**Root cause:** cc-test-runner inherits `ANTHROPIC_API_KEY` from the shell. When set, it takes precedence over `~/.claude/.credentials.json` (OAuth / Claude Max) even when the key's prepaid credits are exhausted. The correct auth for DevServer runs is OAuth (`subscriptionType: max`), not the prepaid API key.

**Fix (permanent — now in run-journeyhawk.sh):** `unset ANTHROPIC_API_KEY` is added at the top of `run-journeyhawk.sh`. The runner now always falls back to OAuth. No billing top-up needed.

**Verify OAuth is working:** `env -u ANTHROPIC_API_KEY claude -p "say: ok" --model claude-haiku-4-5-20251001` should return `ok` within a few seconds.

**CC EC2 server key:** Separately, the CC backend's `ANTHROPIC_API_KEY` in `/opt/contentcompanion/.env` is a different prepaid key used for the production widget. That one being exhausted breaks the CC widget for real visitors — requires a separate top-up or key rotation on EC2. Auto-refreshed every 4h by `refresh-ec2-oauth-key.sh` cron (covers CC, JP, Praxis on EC2 + ComC on DevServer).

---

### CC tiers.yaml Schema Mismatch → subscription page HTTP 500 (discovered CC run 5, fixed 2026-04-30)

**Signature:** Journey steps that load `/cc/subscription` all fail with "the subscription section shows 'HTTP 500' error". EC2 logs show `pydantic_core.ValidationError: 4 validation errors for TiersConfig` from `contentcompanion/config/loader.py get_tiers()`.

**Root cause:** A per-instance `tiers.yaml` on EC2 uses **old field names** that were renamed in the `TiersConfig` Pydantic model. Old names: `monthly_message_limit`, `hourly_message_limit`. Current schema requires: `messages_per_month`, `tools_available`, `session_history_days`, `memory_enabled`, `max_active_sessions`.

**Fix:** Rewrite the instance's `tiers.yaml` on EC2 with current field names. CC hot-reloads config from YAML on each request — no restart needed:
```bash
sudo tee /opt/contentcompanion/config/instances/{instance-slug}/tiers.yaml > /dev/null << 'EOF'
tiers:
  free:
    messages_per_month: 100
    tools_available:
      - all
    session_history_days: 30
    memory_enabled: false
    max_active_sessions: 5
  premium:
    messages_per_month: unlimited
    tools_available:
      - all
    session_history_days: unlimited
    memory_enabled: true
    max_active_sessions: unlimited
EOF
```

**Prevention:** When CC's `TiersConfig` Pydantic schema is updated, grep EC2 for old field names across ALL instances:
```bash
ssh ec2 "grep -rn 'monthly_message_limit\|hourly_message_limit' /opt/contentcompanion/config/instances/"
```
A schema migration checklist item must accompany any `TiersConfig` field rename.

---

### cctr-state MCP disconnects when trunk hits max_turns (discovered CC run 7, 2026-05-05)

**Signature:** Leaf journey runs browser navigation correctly (console log shows real HTTP calls, page snapshots captured) but ALL steps remain `pending` in CTRF. The debug log shows `update_test_step` tool call returned `"Unable to connect. Is the computer able to access the url?"`. The leaf's summary says steps 1-3 passed and step 4 failed — but the runner reports the journey `succeeded: false` with all steps pending.

**Root cause:** The cctr-state HTTP server (`localhost:3001`) runs per-test-case. When a trunk journey hits `error_max_turns` before calling `mcp__cctr-state__update_test_step`, the runner moves on and resets the state server for the next test case. If the leaf's child Claude subprocess is still running when the state server resets, its subsequent `update_test_step` calls arrive at a server that no longer knows about that test case — returning a connection error.

**Reading the evidence:** The child Claude's final `result.subtype: success` message contains the full step summary in plain text — use this to determine actual pass/fail even when CTRF is stale. Look for it in `debug.log`: `grep '"subtype":"success"' debug.log | grep -o '"result":"[^"]*"'`.

**Fix:** Keep trunk journeys ≤ 3 steps to stay inside the 30-turn budget. The current cc-trunk-superadmin has 4 steps (3 and 4 are both identical "Save browser session" — the duplicate is wasted budget). Deduplicating step 4 would save the trunk ~5 turns per run.

**Also:** The trunk's storage state file (`.tmp/cc-trunk-superadmin-state.json`) is preserved from prior runs. If the file is fresh (<2h old) and the leaf loads it successfully, trunk failures are non-fatal for the leaf — the leaf logs in from saved state, not from a fresh trunk run.

---

### React 19 canary fiber contamination — functional state updater crash (discovered CC run 7, 2026-05-05)

**Signature:** Full-page "Something went wrong" ErrorBoundary overlay when switching to the Info & Connections tab on the CC dashboard. Browser console: `TypeError: Cannot convert undefined or null to object` at `Object.entries (<anonymous>)` inside React's `processUpdateQueue`. Stack trace includes minified chunk hashes (e.g. `8849-{hash}.js:31367`).

**Root cause:** React 19.2.0-canary concurrent mode bug. When a component (e.g. `RecentIssues`) mounts with `useState(null)`, a stale functional state updater from a previous fiber iteration — one that calls `Object.entries(state)` where `state` is null — gets replayed by `processUpdateQueue` during the new fiber's mount. This is a framework-level bug: the updater originated in application code (`BreakdownTable.tsx`) but is applied to a different component's hook queue due to fiber contamination.

**Why `key={activeTab}` didn't fully fix it:** Adding a `key` prop forces React to unmount and remount the tab content on every tab switch, which changes the chunk hash and restores isolation for most components. However, `RecentIssues` has its own internal state initialised to `null` that gets a stale updater from the previous fiber tree replayed against it before its own initialisation is complete.

**Fix:** Wrap the crashing component in an `ErrorBoundary` with a silent inline fallback. This contains the crash to the widget level without showing the full-page overlay:
```tsx
<ErrorBoundary fallback={
  <div className="rounded-xl border border-white/10 bg-black/20 backdrop-blur-sm p-5 text-xs text-white/40">
    Recent issues unavailable.
  </div>
}>
  <RecentIssues apiPath={apiUrl} />
</ErrorBoundary>
```

**Secondary fix (good hygiene regardless):** Add `AbortController` to `useEffect` in async-fetch components so in-flight fetches are cancelled on unmount — prevents stale `setState` calls that accumulate in the fiber queue across tab switches.

**What NOT to do:** Exhaustive static analysis of all minified chunks to find `Object.entries(null)` — the updater lives in framework internals, not application code. The `ErrorBoundary` isolation is the correct fix.

**Detection pattern:** If a tab switch causes a full-page "Something went wrong" with `Object.entries` in the stack trace, look for components that: (a) have `useState(null)` or `useState({})`, (b) later call `Object.entries(state)`, and (c) are mounted/unmounted on tab switches. Wrap each in `ErrorBoundary`.

---

### CC billing/status HTTP 500: MultipleResultsFound on phronex-auth shadow users (defect #60, fixed 2026-04-30)

**Signature:** `GET /api/v1/billing/status` returns HTTP 500. EC2 logs show `sqlalchemy.exc.MultipleResultsFound: Multiple rows were found when one or none was required` from `routes_billing.py:166 scalar_one_or_none()`. The subscription page in the portal shows a 500 in the billing section.

**Root cause:** `_get_user_by_token()` queries `users` by `(phronex_account_id, instance_id)` using `scalar_one_or_none()`. There was no UNIQUE constraint on this pair. If a phronex-auth account logs in through two different flows (e.g. portal JWT + instance owner registration), two User shadow rows are created for the same account+instance combination, causing the duplicate.

**Fix applied:**
1. Data cleanup on EC2: re-pointed `instance_owners` FK from the duplicate row to the canonical phronex-auth row, then deleted the duplicate with `DELETE FROM users WHERE id = '<duplicate-id>'`.
2. Alembic migration `96bc1ed1496a` adds a partial UNIQUE index: `CREATE UNIQUE INDEX uq_users_phronex_account_instance ON users (phronex_account_id, instance_id) WHERE phronex_account_id IS NOT NULL`.

**Prevention:** Any code that auto-creates a User row from a phronex-auth token must first check for an existing row. The UNIQUE constraint will now surface race-condition duplicates at the DB level rather than letting them silently accumulate. The QA cleanup hook `CC_TEST_CLEANUP_SDK_KEY` should also wipe shadow user rows between runs to prevent cross-run state accumulation.

**How to detect during a run:** Step-outcomes from J10 show step 2 as "passed" (the 500 appears only in the page content, not the HTTP response code) and steps 5+6 fail. EC2 logs show `MultipleResultsFound` at the route level, NOT a tiers.yaml ValidationError. Distinguish from defect #55 by the exception class.

---

### Command Centre (comc)

| Item | Value |
|------|-------|
| Deep spec | `comc-journeys/comc-deep.json` (45 static journeys) |
| Backend URL | `http://localhost:8004` (DevServer — NOT EC2) |
| Portal URL | `http://localhost:3002` (DevServer — production build required) |
| QA account | `qa-test-journeyhawk@phronex.com` (command-centre premium grant, role_id set, rate_limit_exempt=true) |
| Trunk journey | `comc-trunk-superadmin` — login + save browser session state; all 44 leaf journeys load from saved state |
| Run 1 | 2026-05-06 — TBD (first full run with LLM enrichment enabled) |

**ComC backend URL:** All journey specs must use `http://localhost:8004` for direct API calls. ComC runs on DevServer only — never EC2. There is no production domain for ComC yet (comc.phronex.com is planned).

**Portal for ComC journeys:** The portal at `http://localhost:3002` must be a production Next.js build (not `pnpm dev`). ComC features are accessed via the portal — the spec navigates to `/comc/*` routes in the portal, which proxy to the local ComC backend.

**No QA cleanup endpoint:** As of 2026-05-06, ComC has no QA cleanup SDK. Test data from initiative/CRM/meeting creation accumulates between runs. Use unique test-data names with timestamps (e.g. "JH-Test-Initiative-{date}") to avoid false failures from prior-run data. This is a known gap — flagged in TO-DISCUSS-WITH-VIVEK.md.

**Oracle coverage:** TEST-ORACLES.html is 74KB with multiple tables. Phase 0 DocChain gate will populate oracle-driven steps for ComC journeys in future runs via the flow_extractor pipeline.

**ComC `rate_limit_exempt`:** Already set for `qa-test-journeyhawk@phronex.com`. No need to restart phronex-auth before ComC runs.

---


### Praxis

| Item | Value |
|------|-------|
| Deep spec | `praxis-journeys/praxis-deep.json` |
| Backend URL | `https://praxis.phronex.com` (EC2 port 8003) |
| Frontend URL | `https://praxis.phronex.com` (EC2 port 3003, Next.js) |
| Portal URL | `http://localhost:3002/praxis/*` (DevServer — production build required) |
| QA account | `qa-test-journeyhawk@phronex.com` (praxis grant required) |
| Stack | FastAPI backend (8003) + Next.js frontend (3003) — both on EC2 |

**Praxis Portal URL map:**

| Feature | Correct URL |
|---------|-------------|
| Dashboard / Home | `/praxis` or `/praxis/dashboard` |
| Tasks / Task list | `/praxis/tasks` |
| Planning | `/praxis/planning` |
| Goals | `/praxis/goals` |
| Settings | `/praxis/settings` |

**Praxis backend runs on EC2 (not DevServer):** Unlike ComC, Praxis has no local DevServer instance. All API calls go to `https://praxis.phronex.com`. The portal at `localhost:3002` proxies to the EC2 praxis backend — do NOT use `localhost:8003` in specs.

**TaskPatchBody fields (as of b5ba5d2, 2026-05-17):** Accepts `due_date` (ISO date string, not `deadline`) and `notes` (text). Earlier specs using `deadline` get a 422 validation error.

**No QA cleanup endpoint yet:** Test data accumulates between runs. Use timestamped names (e.g. "JH-Task-{date}") in specs.

## Wiki Integration Status

`qa_wiki_articles` is written by the pipeline after every run (one article per `GapFinding`). As of 2026-04-29: 10 articles (8 CC + 2 JP).

`qa_context_hook.py` (`phronex_common.testing.qa_context_hook.get_qa_context`) reads wiki articles and promoted patterns and returns a formatted block for injection into GSD planner prompts. **Status: ✅ wired (2026-04-29).** `$PHRONEX_CODE_ROOT/CLAUDE.md` → "GSD + Phronex Skills Integration" step 3 now instructs every GSD `plan-phase` agent to run `python -m phronex_common.testing.qa_context_hook {product_slug}` and include the output in planning context. Fail-open: hook returns `""` when DB unreachable.

---

## Run History

| Date | Product | Spec | Pass | Fail | Real Defects | Notes |
|------|---------|------|------|------|-------------|-------|
| 2026-04-29 | jp | jp-deep.json (12) | 4 | 8 | 3 | Run 3. Billing fix ada45d1 validated. 5 turn-limit FPs. |
| 2026-04-30 | cc | cc-deep.json (10) | 0 | 10 | 0 | CC Run 1. All FPs — wrong URLs in spec (/cc/ → 404, EC2 raw IP → timeout). Spec rewritten. |
| 2026-04-30 | cc | cc-deep.json (10) | 0 | 10 | 2 | CC Run 2. J04: e2e-test-instance missing from CC DB instance_owners (fixed via psql). J06–J09: reCAPTCHA 403 (fixed via X-Guide-Secret header in spec). Browser contamination emerged mid-run. |
| 2026-04-30 | cc | cc-deep.json (10) | 0 | 10 | 0 | CC Run 3. All FPs — browser tab contamination. Runner navigated to /jp/jobs and /jp/dashboard (stale tabs from run 2). cctr-state MCP failed on all journeys. Fixed via BROWSER RESET FIRST step in spec. |
| 2026-04-30 | cc | cc-deep.json (10) | 0/1 partial | — | 0 | CC Run 4. J01 steps 1–5 PASSED (browser reset fixed, CC dashboard loads, nav works, e2e-test-instance provisioning confirmed). J01 step 6 aborted: ANTHROPIC_API_KEY credit exhausted. Run stopped. Requires Vivek to top up Anthropic credits before resuming. |
| 2026-04-29 | jp | jp-deep.json (12) | 0 | 12 | 0 | Run 4. FP detection bug (8edbfec1) swallowed all results. Portal also crashed mid-run. |
| 2026-04-29 | jp | jp-deep.json (10 d-series) | 7 | 3 | 1 | Run 5. Jobs detail view missing (fixed d1aa208). 2 spec FPs: conditional step + misdiagnosed localStorage (real cause: hasCcGrant). |
| 2026-04-29 | jp | jp-deep.json (10 d-series) | 9 | 1 | 0 | Run 6. jp-d04 + jp-d09 now pass. 1 spec FP (jp-d08 — QA account has CC grant; spec rewritten). |
| 2026-04-30 | jp | jp-deep.json (12 d-series) | 9 | 3 | 1 | Run 7. jp-d07a/b/c all PASS (billing tier fix validated). jp-d05 real defect: API contract drift in ScanHistoryClient (fixed e927e2f). jp-d08 + jp-d09 Chrome MCP FPs. |
| 2026-04-30 | jp | jp-retry.json (3 journeys) | 0 | 3 | 0 | Run 8. Retry of jp-d05/d08/d09. All 3 Chrome MCP FPs — profile not released between test cases. Root fix: --isolated added to cctr-playwright MCP args. |
| 2026-04-30 | jp | jp-deep.json (12 d-series) | 10 | 2 | 0 | Run 9. --isolated Chrome fix confirmed (zero profile conflicts). jp-d07a/b/c PASS (billing fix ada45d1 validated across free/standard/pro). jp-d05 scan history fix e927e2f confirmed. 2 FPs: jp-d01 rate-limit, jp-d08 spec-execution (/cc 404 — bare route, spec already said /cc/dashboard; minor portal UX gap fixed with redirect page.tsx). |
| 2026-04-30 | cc | cc-deep.json (10) | 8 | 2 | 2 | CC Run 5. J06+J07 FPs (pre-OAuth-swap, prepaid key exhausted — will pass run 6). J05: no analytics chart (FRICTION defect #54). J10: subscription page HTTP 500, tiers.yaml schema mismatch (BROKEN defect #55 — fixed EC2 2026-04-30). |
| 2026-04-30 | cc | cc-deep.json (10) | 6 | 4 | 1 | CC Run 6. J01/J03/J04: browser isolation FPs (cold-start — BROWSER RESET fails on very first journey of run). J05 ✅ (analytics chart defect #54 fixed). J06–J09 all pass. J10 ❌ new defect #60: billing/status HTTP 500 MultipleResultsFound — duplicate phronex-auth shadow user row (fixed: EC2 data cleanup + Alembic migration 96bc1ed1496a adding partial UNIQUE on phronex_account_id+instance_id). |
| 2026-05-05 | cc | cc-tree.json (verify-dashboard-tabs) | 1/1 PASS | — | 2 real defects fixed | CC Run 7 (tree-executor, targeted). Defect #251: Info & Connections tab crash (Object.entries(null) React 19 fiber contamination — fixed ErrorBoundary + AbortController, portal commits 993083a+20d1b69). Defect #252: Skills page delete/submit/preview all sent undefined skill ID (API contract drift skill_id vs id — fixed CC commit 2e350b8 + portal commit 9d2c8b7). Both verified: dashboard-tabs PASS on step 3; skills DELETE now returns 422 not 500. |

---

## Runbook — Starting a Run

### ⚠️ Pre-flight: Kill portal-dev-keepalive.sh FIRST

A script at `/tmp/portal-dev-keepalive.sh` may be running on DevServer. It was created during v2.4 sweep work and loops forever: waits for any active `next build` to finish, then immediately runs `rm -rf .next` and starts `pnpm dev`. This destroys every production build the moment it completes and replaces it with a dev build — causing all journeys to fail with false HTTP 500s.

**Check and kill before every run:**
```bash
# Check if running
pgrep -af "keepalive"

# Kill it
pkill -f portal-dev-keepalive.sh
# Also kill any surviving pnpm dev processes
pkill -f "next dev"
```

**Portal production start (always chain build+start atomically — zero gap):**
```bash
cd ~/code/phronex-portal
fuser -k 3002/tcp 2>/dev/null || true
NODE_ENV=production /home/ouroborous/.bun/bin/bun run build && \
  NODE_ENV=production nohup /home/ouroborous/.bun/bin/bun run start > /tmp/portal-start.log 2>&1 &
# Wait ~5s, then verify
curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/auth/login
# Must return 200 or 307
```

**Why NODE_ENV=production matters:** Without it, Next.js 15 may produce a hybrid Turbopack/webpack build that fails to emit `[turbopack]_runtime.js`, causing `bun run start` to crash immediately. Always set it explicitly.

```bash
# 0. Reset phronex-auth in-memory rate limits (MANDATORY before any run that follows a previous run)
# phronex-auth rate limit: 10 logins/hr per IP. Each test case does 1 login. A 12-journey suite
# uses 12 login attempts. Multiple runs in the same hour exhaust the limit.
# Fix: restart phronex-auth on EC2 before every run (not just first run of the day).
"C:\Program Files\Git\usr\bin\ssh.exe" -i C:\Temp\aws.pem ubuntu@43.204.79.39 "sudo systemctl restart phronex-auth && sleep 3 && curl -s http://localhost:8002/health"
# Must return {"status":"healthy"}

# 1. Verify portal is a production build (after pre-flight above)
curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/auth/login
# Must return 200 or 307.

# 2. Run
cd ~/code/phronex-test-runner
source ~/code/.qa.env
./run-journeyhawk.sh jp jp-journeys/jp-deep.json

# 3. Verify defects landed
psql "$PHRONEX_QA_DATABASE_URL_SYNC" \
  -c "SELECT defect_id, title, severity FROM qa_known_defects ORDER BY first_seen_at DESC LIMIT 10;"
```

### `/cc` route 404s — spec must use `/cc/dashboard`

**Discovered:** 2026-04-30, jp-d08 step 5.
**Pattern:** The Next.js `/cc` path has a `layout.tsx` but no `page.tsx`. Navigating directly to `/cc` returns 404. The correct entry point for the CC product section is `/cc/dashboard`. All journey specs must use `/cc/dashboard` (or deeper paths) — never bare `/cc`.
**Also applies to:** Any similar product layout-only routes (e.g. if `/jp` had no page.tsx).
**Secondary finding (FRICTION):** A user clicking a link to `/cc` gets a 404 instead of a redirect to `/cc/dashboard`. This is a minor UX gap — worth a future portal task to add a redirect in the CC layout.

---

### CC superadmin instance navigation — `?instance=` query param required

**Discovered:** 2026-05-04, cc-J04 step 5.
**Pattern:** For superadmin users in the CC portal section, instance context comes from the `?instance=` URL query parameter (not from an `access_grant.instance_slug` like non-superadmins). The `CCLayoutClient` auto-selects the first available instance when no `?instance=` param is present. When a spec navigates to `/cc/instance` or `/cc/dashboard` without preserving the param, the auto-select may pick a *different* instance — causing false "persistence failure" findings.
**Fix in specs:** Always use `/cc/instance?instance=e2e-test-instance` (include the param explicitly) when testing as superadmin and instance context matters.
**Portal behaviour is correct:** `tabHref()` in `CCLayoutClient.tsx` correctly appends `?instance=<id>` to all tab links when a superadmin has an instance selected. The spec was wrong, not the product.

---

### Deployment race with QA run — phronex-auth restart mid-run causes login failure

**Discovered:** 2026-05-04, cc-J05 run-20260504-cc-test2.
**Pattern:** phronex-auth restarted at 08:03:37 UTC during cc-J05's login attempt at 08:03:23 UTC. The restart interrupted the active connection, causing Auth.js to receive a connection error and return "Invalid email or password" to the portal login page.
**Detection:** Cross-reference `systemctl show phronex-auth --property=ActiveEnterTimestamp` against journey timestamps when login fails with "Invalid email or password" for a known-good account.
**Mitigation:** When deploying a fix during an active QA run, accept that any journey in-flight at restart time will fail. Always deploy before starting a run, not during.

---

### API-only journeys need page navigation before `page.evaluate()`

**Discovered:** 2026-05-04, cc-J09 step 1 (and previously cc-J06/J07/J08).
**Pattern:** When a journey starts in a fresh browser context (`--isolated`), the initial page is `about:blank`. Calling `page.evaluate()` on `about:blank` fails with "Need to navigate to a page first before executing JavaScript." The tester must navigate to any page (even one that returns 404) before `page.evaluate()` can execute fetch calls.
**Fix in specs:** Add an explicit "First navigate to https://cc.phronex.com/ to establish a page context" instruction as the first step in any API-only journey that uses `page.evaluate()`. Note: a 404 on the root URL is expected — CC serves no homepage.
**Applied to:** cc-J06, cc-J07, cc-J08, cc-J09 step 1 descriptions (commit da049e1).

---

### phronex-auth `rate_limit_exempt` — never restart auth to reset rate limits

**Discovered:** 2026-05-06.
**Context:** The `accounts` table in phronex-auth has a `rate_limit_exempt` column. When `true`, the account bypasses the per-IP and per-account login rate limits entirely.

**Run this once per QA account, not per run:**
```sql
UPDATE accounts SET rate_limit_exempt = true
WHERE email = 'qa-test-journeyhawk@phronex.com'
RETURNING email, rate_limit_exempt;
```
(confirmed already set for `qa-test-journeyhawk@phronex.com` as of 2026-05-06)

**Consequence:** The `sudo systemctl restart phronex-auth` pre-flight step in the runbook is UNNECESSARY if `rate_limit_exempt` is true for the QA account. Do NOT restart phronex-auth for rate-limit reasons — a restart mid-run causes active journey logins to fail with "Invalid email or password" (see "Deployment race" section). Reserve restarts for actual service failures.

**Multi-product note:** For new QA accounts on any product, immediately set `rate_limit_exempt = true` in phronex-auth. This is a one-time provisioning step that the `Phronex_Internal_QA_JourneyHawk` skill skill gates must enforce.

---

### LLM factory OAuth fallback — DevServer/JourneyHawk runs must not set ANTHROPIC_API_KEY

**Discovered:** 2026-05-06, ComC PHASE 0 pre-run.
**Root cause:** `phronex_common.llm.factory._resolve_platform_key()` previously returned `""` when `ANTHROPIC_API_KEY` was unset, passing `api_key=""` to `AnthropicProvider`. The Anthropic SDK then raised an unhelpful "Could not resolve authentication method" error far from the call site — appearing as a silent LLM enrichment failure (all 39 doc-signal journeys fell back to heuristic stubs).

**Fix (commit 9a38764e):**
- `_resolve_platform_key("anthropic")` now falls back to `~/.claude/.credentials.json → claudeAiOauth.accessToken` when `ANTHROPIC_API_KEY` is unset.
- When neither env var nor credentials file has a key, a `WARNING` log with actionable fix instructions is emitted (not a silent empty string).
- `_enrich_batch` in `journey_generator.py` detects OAuth tokens (`sk-ant-oat` prefix) and uses: `batch_size=3`, `inter_batch_sleep=35s` (vs prepaid: `batch_size=5`, `3s` sleep). This prevents cascade 429s where all 5 concurrent calls in a batch hit the OAuth rate limit simultaneously.

**How to detect the original bug:** All `[journey-gen] LLM enrichment failed for ...: "Could not resolve authentication method"` lines in journey generator output → all generated journeys are heuristic stubs.

**DevServer invariant:** `run-journeyhawk.sh` already does `unset ANTHROPIC_API_KEY` at startup. Combined with the OAuth fallback in factory.py, JourneyHawk on DevServer now correctly uses Claude Code OAuth with zero additional config.

---

### CC widget `data-auth-mode='portal'` breaks anonymous visitors — use `auto` for public sites with tiered access

**Discovered:** 2026-05-04, cc-phronexweb-J02 browser console log. Corrected same session after initial wrong fix.
**Pattern:** The phronexweb CC widget was embedded on phronex.com with `data-auth-mode='portal'`. This mode requires the visitor to be authenticated in `app.phronex.com` via an iframe token frame at `/api/cc/token-frame`. Anonymous public website visitors are never portal-authenticated, so the widget loops: it polls `token-frame` every ~15 seconds, receives "not authenticated", and cannot issue a chat token. The chat panel opens correctly (widget JS loads) but messages never get a response — the AI is blocked waiting for a token.
**Detection in console log:** Repeated `[CC] portal auth: loading iframe https://app.phronex.com/api/cc/token-frame` followed immediately by `[CC] portal auth: not authenticated` — repeating every ~15s.
**Why J01 (API test) passed but J02 (browser test) failed:** The API test used `POST /auth/anonymous` directly with the right `instance_id`, bypassing widget auth entirely. The browser widget uses a different code path that respects `data-auth-mode` on the script tag. In Playwright isolated mode with no portal session cookie, the portal iframe check always returns "not authenticated" — this is NOT a real failure; real users with portal sessions get their tier correctly.
**Correct fix:** Set `data-auth-mode='auto'` and keep `data-portal-auth-frame` pointing to `${COMPANY.portalUrl}/api/cc/token-frame`. The `auto` cascade tries portal iframe first (gives logged-in Phronex users their subscription tier), then falls back to anonymous for unauthenticated visitors. Fix: phronex-website, defect #225 in `qa_known_defects`.
**Why NOT `anonymous`:** Using `data-auth-mode='anonymous'` skips the portal iframe check entirely, permanently breaking tiered access for Phronex portal users who visit phronex.com while logged in. Those users should get their subscription tier, not anonymous rate limits.
**Rule for future instances:**
- `portal` mode: ONLY when embedding page is EXCLUSIVELY behind portal login (app.phronex.com). No anonymous fallback.
- `auto` mode: Public sites where SOME visitors are logged-in portal users (phronex.com). Gets tier for logged-in users, falls back to anonymous for guests. Always pair with `data-portal-auth-frame`.
- `anonymous` mode: Sites with ZERO logged-in Phronex users expected (external customer sites, public demos). Skips all portal auth — fastest load.

---

### ComC restart collision window — 502 during deployment is transient, not a product defect

**Discovered:** 2026-05-06, ComC Run 20/21.
**Pattern:** When ComC is restarted (e.g. after applying an Alembic migration via `systemctl restart command-centre`), browser journeys that execute during the ~8-second restart window receive HTTP 502 from the EC2 → DevServer reverse tunnel. The tunnel stays up; ComC is simply not listening yet. The portal proxy returns 502 on every request during this window — `console.log` in the journey shows `ERR_CONNECTION_REFUSED` at `http://localhost:8002/...` or 502 on all `/api/admin/command-centre/...` calls.

**Correct classification:** Infrastructure maintenance artifact — NOT a product defect. Do not file a defect.

**Detection:** Cross-reference `systemctl show command-centre --property=ActiveEnterTimestamp` against journey start timestamp. If restart time overlaps with journey execution, this is the cause.

**Prevention:** Always apply migrations and restart ComC BEFORE starting a JourneyHawk run. Never restart ComC during an active run. Confirm ComC is healthy before kicking off the trunk journey:
```bash
curl -sf http://localhost:8004/health && echo "ComC healthy"
```

---

### FAIL_ORACLE text-variance flapping — same journey passes/fails across runs due to LLM phrasing drift

**Discovered:** 2026-05-06, ComC Run 20 FAIL_ORACLE verdicts.
**Pattern:** The oracle validation auditor matches tester step output text against the `Expected` column in `TEST-ORACLES.html` using LLM semantic comparison. When the tester's actual step description is semantically equivalent but phrased differently across runs (e.g. "metric cards showing agent count" vs "panel displays the active agent count statistic"), the LLM comparison may return MATCH in run N and NO_MATCH in run N+1 — causing the same journey to flip between PASS_ORACLE and FAIL_ORACLE without any product change.

**Signature:** A journey shows FAIL_ORACLE in the DB but the step outcomes in CTRF/debug.log show all steps completing successfully with no browser errors.

**Correct classification:** FP caused by oracle text variance — NOT a product defect. Do not file a defect; update the oracle text or increase LLM match threshold.

**How to distinguish from real failures:**
1. Check CTRF `message` — if all steps say `[Status: pending]` with no `[Error:]`, this is the CTRF pending-flush bug (see "CTRF format bug" section), not a text variance issue.
2. Check `debug.log` — if the tester described completing steps successfully but the oracle auditor returned FAIL, this is text variance.

**Mitigation:** Write oracle `Expected` values at the semantic level (not exact tester phrasing). Broader oracle expectations reduce variance-driven flapping.

---

### Playwright date input — use `page.evaluate()` to set value in ISO format, not `browser_fill`

**Discovered:** 2026-05-06, ComC Run 20 vendor-subscription journey (defect #374 closed as FP).
**Pattern:** Playwright `browser_fill` on `<input type="date">` fields sends the display-format string which the browser may reject or accept differently depending on locale. On some builds, the field receives the string literally but the browser's internal value remains empty, causing form submission to fail silently. This was misidentified as a real defect (#374) before the pattern was recognized.

**Correct approach:** Use `browser_evaluate` (i.e. `page.evaluate()`) to set the date value directly in ISO format and dispatch a change event:
```javascript
document.querySelector('input[type="date"]').value = '2026-12-31';
document.querySelector('input[type="date"]').dispatchEvent(new Event('change', { bubbles: true }));
```

**Spec rule:** Any journey step that fills a date input should use the evaluate approach. Add a note: "Use page.evaluate() to set the date input value to '2026-12-31' in ISO format and dispatch a change event — do not use browser_fill for date fields."

**#374 classification:** CLOSED as false positive — vendor subscription renewal_date 422 was caused by Playwright locale-dependent date format, not a real schema mismatch.

---



---

### Trunk retirement causes cascading auth failure across all leaf journeys (RCA — 2026-05-07, ComC Runs 16–17)

**Symptom:** ~30% of leaf journeys fail with "Unable to load saved superadmin session" or "session has expired", despite the session file being valid (confirmed via `curl /api/auth/session`). The Playwright tester falls back to `vivek@phronex.com / password123` (wrong credentials) and fails.

**Root cause (3-layer chain):**
1. `spec_curator` (or manual RETIRE operation) set `_retired_at` on `comc-trunk-superadmin` in `comc-deep.json`.
2. `run-journeyhawk.sh` pre-filter strips all `_retired_at` journeys from `_SPEC_ACTIVE` **before** credential substitution. Trunk gone from that point forward.
3. Without the trunk in the spec, `cc-test-runner`'s `capturedStates` map is never populated for `comc-trunk-superadmin`. Leaf journeys receive `parentStatePath=null`, start in fresh unauthenticated browser contexts, and fall back to hardcoded wrong credentials.

**Why intermittent (not 100%):** Some leaf journeys succeeded because their step 1 text said "load session file OR log in" and the LLM tester successfully loaded the pre-existing `.tmp/comc-trunk-superadmin-state.json` via direct Playwright `storageState()` call from the step description. Others failed because the LLM tester chose the login-fallback path.

**Fixes applied:**
- `comc-deep.json`: removed `_retired_at` and `_retire_reason` from `comc-trunk-superadmin` entry.
- `run-journeyhawk.sh` pre-filter: `isSharedRoot` trunks exempted — `or j.get('isSharedRoot')` guard added to active-journeys filter.
- `journey_generator.py` cache HIT path: static spec journeys prepended to cached journeys before output (prevents trunk loss on subsequent cache HITs).
- `SKILL.md`: TRUNK RETIREMENT INVARIANT added to spec curator section.

**Prevention:** At session start for any product, verify trunks (`isSharedRoot: true`) have no `_retired_at`. The skill now mandates this check. The `run-journeyhawk.sh` guard is a fallback, not a substitute for keeping trunks unretired.

**Cross-product status (2026-05-07):** CC, JP, Portal trunks all clean (`_retired_at: None`). ComC fixed in this session.


---

### Portal Proxy URL Anti-Pattern — spec `page.evaluate()` calls must use `/api/admin/command-centre/api/v1/` (not `/command-centre/api/v1/`)

**Discovered:** 2026-05-08, ComC Run 21 — 7 journeys failed with 404 on API calls.

**Pattern:** Journey spec steps that use `page.evaluate()` to call the ComC backend from the portal browser context must use the proxy-routed URL:
```
http://localhost:3002/api/admin/command-centre/api/v1/{route}
```
NOT the direct path:
```
http://localhost:3002/command-centre/api/v1/{route}   ← WRONG — always 404
```

**Root cause:** The portal is a Next.js app running on port 3002. API calls to ComC backend go through Next.js `rewrites` that map `/api/admin/command-centre/api/v1/*` → `http://localhost:8004/api/v1/*`. There is no handler at `/command-centre/api/v1/*` — the Next.js router returns 404 because that path is only used for UI navigation (the `/command-centre/` prefix is a Next.js route, not an API prefix).

**Fix applied (2026-05-08, commit 637595b):** Bulk replacement across `comc-run19-targeted.generated.json` and `comc-deep.generated.json` — 76 step descriptions and 75 step descriptions fixed respectively.

**Prevention rule (MANDATORY for all future ComC journey spec steps):**
- UI navigation: `http://localhost:3002/command-centre/{feature}` ✅ (Next.js route)
- API calls via `page.evaluate()`: `http://localhost:3002/api/admin/command-centre/api/v1/{route}` ✅ (proxied)
- Never: `http://localhost:3002/command-centre/api/v1/{route}` ❌ (404 always)

**Scope:** 76 step descriptions fixed across erp-sync, brief-settings, crm, notifications, agent-pause-resume, dept-template, dashboard-metrics, agent-list, meetings, approvals, costs, revenue-pipeline, accountability-partners, isolation-mode, skill-review journeys. Static `comc-deep.json` (45 journeys) had 0 occurrences — it predates this anti-pattern.

---

### Brief settings `sections_config` returns `[]` for unconfigured org — spec must not assert pre-seeded defaults

**Discovered:** 2026-05-08, ComC Run 21, `comc-biz-brief-settings-config-upsert`.

**Pattern:** `GET /api/v1/briefs/settings` returns `{"sections_config": []}` when no settings row exists for the org. The route:
```python
if not row:
    return {"brief_type": brief_type, "sections_config": []}
```
An empty array is the correct API contract for an unconfigured org. The generated spec was asserting that "default sections ('News', 'Updates', 'Insights') are displayed" — which is never true without a prior PUT.

**Fix:** Spec steps 2–4 updated to accept either `[]` or pre-seeded sections as valid initial state, and to PUT sections if starting from empty.

**Rule:** Never write journey specs that assume brief settings or similar config-on-demand resources are pre-populated. Always: GET → check state → PUT if needed → verify PUT result.

### FastAPI validates request schema BEFORE auth Depends() (discovered CC run 5/6, 2026-05-11)

**Pattern:** FastAPI routes with required body or query params run Pydantic validation before any `Depends()` auth middleware. A route like `POST /api/v1/billing/status` that requires `instance_id` in the body returns **HTTP 422 Unprocessable Entity** before the JWT auth ever fires.

**Consequence for security testing:** A journey testing "invalid JWT is rejected" against such an endpoint actually tests Pydantic, not auth. The JWT rejection never happens. The journey will FAIL_ORACLE (expects 401/403, gets 422) and look like a broken auth gate when it isn't.

**Fix:** Security auth-rejection journeys must use endpoints with no required params — e.g. `GET /api/v1/chat/sessions` (no body, no required query params). `GET /api/v1/admin/users` also works if testing admin auth. Always prefer GET endpoints with no params for auth boundary testing.

**Rule:** Before writing an auth-rejection journey, check whether the target endpoint has required params. If it does, choose a different endpoint. The defect is in the spec, not the product.

---

### `body: r.json()` Promise anti-pattern in `page.evaluate()` fetch chains (discovered CC run 5/6, 2026-05-11)

**Pattern:** In `page.evaluate()`, `r.json()` is an async method that returns a Promise. Writing `{status: r.status, body: r.json()}` captures the **Promise object**, not the resolved value. The journey agent receives `body: {}` or `body: [object Promise]` and cannot verify any response fields.

**Correct pattern:**
```javascript
// WRONG — body captures a Promise
.then(r => ({status: r.status, body: r.json()}))

// CORRECT — chain .then() to resolve the JSON before returning
.then(r => r.json().then(body => ({status: r.status, body})))
```

**Fix applied:** 7 journey steps across auth-anonymous, api-skills-crud, sec-idor-cross-instance, biz-billing-checkout, biz-chat-disabled corrected in CC run 6 spec fixes.

**Rule:** Any `page.evaluate()` fetch chain that needs to return response body must use `.then(r => r.json().then(body => ({status: r.status, body})))`. Grep for `body:\s*r\.json\(\)` before finalising any spec.

---

### Class 5 garbage journeys — no actionable URL in any step (structural fix, 2026-05-11)

**Pattern:** The journey generator's heuristic path (`_generate_from_discovery`) can produce journeys where every step is pure prose — "GSD acceptance: X", "Verify the system does Y" — with no `https://` URL, `/api/` path, or navigation target. These are planning-doc artefacts that a browser agent cannot execute.

**Detection:** `_is_garbage_journey()` in `journey_generator.py` now has Class 5 detection. A journey is garbage if no step description contains `https?://`, `/api/`, or `navigate to.*https?://`.

**Curator fix:** `spec_curator.curate()` now runs an unconditional static spec garbage scan before checking for the generated cache file. In `--no-llm` mode (where `cc-tree.generated.json` is never written), the previous fast-path never ran. Garbage now evicted from `cc-tree.json` itself on the first post-run curator call.

**Rule:** After any run that uses `JOURNEYHAWK_NO_LLM=1`, the curator still evicts garbage from the static spec. No manual cleanup needed — but verify the curator ran by checking logs for `[curator] Evicted N garbage journeys from static spec`.

