# JourneyHawk — Operational Learnings & Reference

> Living document. Updated after every product run.
> Coding standards derived from RCA belong in `D:/Coding/CLAUDE.md`.
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

**CC Sessions tab — superadmin-only (filed as defect #42):** `CCDashboardClient.tsx` defines `SUPERADMIN_TABS = [...BASE_TABS, { id: 'sessions' }]`. Instance owners see only Overview, Analytics, Info tabs. Both CC backend routes (`/admin/sessions`, `/admin/users/{id}/conversations`) require `_require_admin`. Do NOT write CC journey specs that expect instance owners to see or access session/conversation history — this is a known product gap, not a spec bug.

**CC instance config provisioning (required for J04 + J06–J09):** Every CC instance needs BOTH a DB row in `instance_owners` AND a config directory at `/opt/contentcompanion/config/instances/{slug}/` on EC2 with `instance.yaml`, `persona.yaml`, and `tiers.yaml`. New QA instances created in phronex-auth are NOT automatically propagated to either location. Manual steps required (both done for `e2e-test-instance` on 2026-04-30):
1. DB insert: `INSERT INTO instance_owners ...` (see run 2 notes above)
2. Config dir: `mkdir -p /opt/contentcompanion/config/instances/{slug}/` + write 3 YAML files

**CC Backend API URL map:**

| Call | Correct URL |
|------|-------------|
| Anonymous widget auth | `https://cc.phronex.com/api/v1/auth/anonymous` |
| Chat message | `https://cc.phronex.com/api/v1/chat` |
| Health check | `https://cc.phronex.com/api/v1/health` |

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

### API Credit Exhaustion Blocker (discovered CC run 4, 2026-04-30)

**Signature:** cc-test-runner crashes with "Claude Code process exited with code 1". The debug.log ends with `"Credit balance is too low"` in the result message. The `/v1/models` endpoint returns 200 (models list doesn't consume credits) but any `/v1/messages` call returns HTTP 400 with `{"type":"invalid_request_error","message":"Your credit balance is too low..."}`.

**Root cause:** The cc-test-runner inherits `ANTHROPIC_API_KEY` from the shell environment. When that key's prepaid credit balance is zero, every Claude Code subprocess invocation fails immediately on the first API call. The runner binary crashes and no subsequent journeys execute.

**Fix:** Top up credits at https://console.anthropic.com/settings/billing. Verify with: `curl -s https://api.anthropic.com/v1/messages -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'`. HTTP 200 = credits available; HTTP 400 = still empty.

**Not a false positive.** Unlike the CTRF pending-step pattern, this crash is unambiguous — the run genuinely did not execute.

---

## Wiki Integration Status

`qa_wiki_articles` is written by the pipeline after every run (one article per `GapFinding`). As of 2026-04-29: 10 articles (8 CC + 2 JP).

`qa_context_hook.py` (`phronex_common.testing.qa_context_hook.get_qa_context`) reads wiki articles and promoted patterns and returns a formatted block for injection into GSD planner prompts. **Status: ✅ wired (2026-04-29).** `D:/Coding/CLAUDE.md` → "GSD + Phronex Skills Integration" step 3 now instructs every GSD `plan-phase` agent to run `python -m phronex_common.testing.qa_context_hook {product_slug}` and include the output in planning context. Fail-open: hook returns `""` when DB unreachable.

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
