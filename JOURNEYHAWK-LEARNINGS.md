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

### localStorage Persistence FP (discovered run 5, 2026-04-29)

**Signature:** Journey fails because a dismissable UI element (banner, tooltip, onboarding card) is not visible. The element is correctly hidden by a `localStorage` key set during a previous test run.

**Root cause:** cc-test-runner reuses the same Chrome browser profile across all journeys and across runs. User-dismissable components that write to `localStorage` (e.g. `ccCrossSellDismissed`, `jpOnboardingBannerDismissed`) stay dismissed in subsequent runs. The product code is correct — the banner correctly stays hidden once dismissed — but the test sees stale state from a previous session.

**Fix:** Add a localStorage cleanup step at the start of any journey that tests a dismissable element. Example step: "Before navigating, execute in the browser console: `localStorage.removeItem('ccCrossSellDismissed');` Then navigate to the page."

**Known keys to reset per product:**

| Product | localStorage key | Element |
|---------|-----------------|---------|
| JP | `ccCrossSellDismissed` | CC cross-sell banner on JP dashboard |
| JP | `jpOnboardingBannerDismissed` | JP onboarding setup guide banner |

---

## Per-Product Notes

### JobPortal (jp)

| Item | Value |
|------|-------|
| Deep spec | `jp-journeys/jp-deep.json` (10 journeys, d-series, all exactly 6 steps) |
| Backend URL | `https://jobc.phronex.com` (EC2) |
| Portal QA URL | `http://localhost:3002` (DevServer) |
| QA account | `qa-test-journeyhawk@phronex.com` (standard tier) |
| Billing fix validated | `ada45d1` — standard tier label correct (jp-J08 PASS, run 2026-04-29) |
| Run 3 result | 4/12 PASS, 3 real defects fixed (`b740a6a` portal + `aa2c0fa` jobportal), 5 turn-limit FPs |
| Run 4 result | 0/12 defects logged — FP detection bug `8edbfec1` swallowed all failures; portal was also down mid-run |
| Run 5 result | 7/10 PASS, 1 real defect (jobs detail view — fixed in portal), 2 spec/infra FPs (conditional step + localStorage) |

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
| 2026-04-29 | jp | jp-deep.json (10 d-series) | 7 | 3 | 1 | Run 5. Jobs detail view missing (fixed). 2 spec/infra FPs: conditional step + localStorage. |

---

## Runbook — Starting a Run

```bash
# 1. Verify portal is a production build
curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/auth/login
# Must return 200. If 500: bun run build && bun run start (see pre-flight checklist)

# 2. Run
cd ~/code/phronex-test-runner
source ~/code/.qa.env
./run-journeyhawk.sh jp jp-journeys/jp-deep.json

# 3. Verify defects landed
psql "$PHRONEX_QA_DATABASE_URL_SYNC" \
  -c "SELECT defect_id, title, severity FROM qa_known_defects ORDER BY first_seen_at DESC LIMIT 10;"
```
