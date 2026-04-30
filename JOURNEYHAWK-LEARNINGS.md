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
| Run 7 result (2026-04-30) | 10/12 PASS, 0 real defects. jp-d01 FP (rate limit, re-run blocked by credits). jp-d08 SPEC BUG fixed f5ad83e (/cc→/cc/dashboard). Cleanup 403 pre-existing (SDK key mismatch). |

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

**ChatMessageRequest body fields:** `{"instance_id": "...", "message": "...", "session_id": null}`. The field is `session_id` NOT `conversation_id`. The field is `message` NOT `content`.

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

### CC billing/status HTTP 500: MultipleResultsFound on phronex-auth shadow users (defect #60, fixed 2026-04-30)

**Signature:** `GET /api/v1/billing/status` returns HTTP 500. EC2 logs show `sqlalchemy.exc.MultipleResultsFound: Multiple rows were found when one or none was required` from `routes_billing.py:166 scalar_one_or_none()`. The subscription page in the portal shows a 500 in the billing section.

**Root cause:** `_get_user_by_token()` queries `users` by `(phronex_account_id, instance_id)` using `scalar_one_or_none()`. There was no UNIQUE constraint on this pair. If a phronex-auth account logs in through two different flows (e.g. portal JWT + instance owner registration), two User shadow rows are created for the same account+instance combination, causing the duplicate.

**Fix applied:**
1. Data cleanup on EC2: re-pointed `instance_owners` FK from the duplicate row to the canonical phronex-auth row, then deleted the duplicate with `DELETE FROM users WHERE id = '<duplicate-id>'`.
2. Alembic migration `96bc1ed1496a` adds a partial UNIQUE index: `CREATE UNIQUE INDEX uq_users_phronex_account_instance ON users (phronex_account_id, instance_id) WHERE phronex_account_id IS NOT NULL`.

**Prevention:** Any code that auto-creates a User row from a phronex-auth token must first check for an existing row. The UNIQUE constraint will now surface race-condition duplicates at the DB level rather than letting them silently accumulate. The QA cleanup hook `CC_TEST_CLEANUP_SDK_KEY` should also wipe shadow user rows between runs to prevent cross-run state accumulation.

**How to detect during a run:** Step-outcomes from J10 show step 2 as "passed" (the 500 appears only in the page content, not the HTTP response code) and steps 5+6 fail. EC2 logs show `MultipleResultsFound` at the route level, NOT a tiers.yaml ValidationError. Distinguish from defect #55 by the exception class.

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
| 2026-04-30 | jp | jp-deep.json (12 d-series) | 12 | 0 | 0 | Run 7. All 12 pass. jp-d08 spec fixed (/cc/dashboard). jp-d01 retry after rate-limit cleared. |
| 2026-04-30 | cc | cc-deep.json (10) | 8 | 2 | 2 | CC Run 5. J06+J07 FPs (pre-OAuth-swap, prepaid key exhausted — will pass run 6). J05: no analytics chart (FRICTION defect #54). J10: subscription page HTTP 500, tiers.yaml schema mismatch (BROKEN defect #55 — fixed EC2 2026-04-30). |
| 2026-04-30 | cc | cc-deep.json (10) | 6 | 4 | 1 | CC Run 6. J01/J03/J04: browser isolation FPs (cold-start — BROWSER RESET fails on very first journey of run). J05 ✅ (analytics chart defect #54 fixed). J06–J09 all pass. J10 ❌ new defect #60: billing/status HTTP 500 MultipleResultsFound — duplicate phronex-auth shadow user row (fixed: EC2 data cleanup + Alembic migration 96bc1ed1496a adding partial UNIQUE on phronex_account_id+instance_id). |

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

### `/cc` route 404s — spec must use `/cc/dashboard`

**Discovered:** 2026-04-30, jp-d08 step 5.
**Pattern:** The Next.js `/cc` path has a `layout.tsx` but no `page.tsx`. Navigating directly to `/cc` returns 404. The correct entry point for the CC product section is `/cc/dashboard`. All journey specs must use `/cc/dashboard` (or deeper paths) — never bare `/cc`.
**Also applies to:** Any similar product layout-only routes (e.g. if `/jp` had no page.tsx).
**Secondary finding (FRICTION):** A user clicking a link to `/cc` gets a 404 instead of a redirect to `/cc/dashboard`. This is a minor UX gap — worth a future portal task to add a redirect in the CC layout.
