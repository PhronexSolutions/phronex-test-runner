# JourneyHawk — Operational Learnings & Reference

> Living document. Updated after every product run.
> Coding standards derived from RCA belong in `D:/Coding/CLAUDE.md`.
> Test infrastructure learnings (false positives, service topology, per-product quirks) live here.

---

## Service Topology for QA Runs

| Layer | Where it runs | Notes |
|-------|--------------|-------|
| `phronex_qa` PostgreSQL | DevServer (`192.168.1.250`) | Never on EC2. All QA writes go here. |
| `cc-test-runner` binary | DevServer `~/code/phronex-test-runner/dist/` | Compiled bun binary. Never install on EC2. |
| `phronex_common.testing.runner` | DevServer `~/code/phronex-common/.venv` | Intelligence pipeline. DevServer-only. |
| `phronex-portal` (QA instance) | DevServer `~/code/phronex-portal` port 3002 | Production build (`bun run start`). Browser tests hit this, NOT EC2. |
| `run-journeyhawk.sh` | DevServer `~/code/phronex-test-runner/` | Atomic wrapper — never call cc-test-runner alone. |
| `phronex-common` (QA checkout) | DevServer `~/code/phronex-common/` | Separate from EC2's `/opt/phronex-common`. |

**Product backends (jobportal, CC, auth, praxis)** → EC2 only. The QA portal on DevServer points to EC2 for all API calls (e.g. `JP_API_URL=https://jobc.phronex.com`).

**`.qa.env` location:** `~/code/.qa.env` on DevServer. Contains:
```
PHRONEX_QA_DATABASE_URL_SYNC=postgresql+psycopg2://phronex_qa:phx_qa_local_2026@localhost:5432/phronex_qa
JP_PUBLIC_URL=http://localhost:8001   # only relevant if running local jobportal — otherwise EC2 default applies
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
| Backend URL | `https://cc.phronex.com` (EC2) |
| QA accounts | `qa-cc-owner@phronex.com` with `role_id = instance_owner` |
| Role requirement | `role_id` MUST be set in `access_grants` — `NULL` role breaks instance_owner API routes |

---

## Wiki Integration Status

`qa_wiki_articles` is written by the pipeline after every run (one article per `GapFinding`). As of 2026-04-29: 10 articles (8 CC + 2 JP).

`qa_context_hook.py` (`phronex_common.testing.qa_context_hook.get_qa_context`) reads wiki articles and promoted patterns and returns a formatted block for injection into GSD planner prompts. **Status: ✅ wired (2026-04-29).** `D:/Coding/CLAUDE.md` → "GSD + Phronex Skills Integration" step 3 now instructs every GSD `plan-phase` agent to run `python -m phronex_common.testing.qa_context_hook {product_slug}` and include the output in planning context. Fail-open: hook returns `""` when DB unreachable.

---

## Run History

| Date | Product | Spec | Pass | Fail | Real Defects | Notes |
|------|---------|------|------|------|-------------|-------|
| 2026-04-29 | jp | jp-deep.json (12) | 4 | 8 | 3 | Run 3. Billing fix ada45d1 validated. 5 turn-limit FPs. |
| 2026-04-29 | cc | cc-deep.json | — | — | — | Run 2. See cc-d-run-2 in qa_known_defects. |
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
