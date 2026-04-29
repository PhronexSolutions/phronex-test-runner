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

### Runner Turn-Limit (fixed in runner.py 2026-04-29)

**Signature:** CTRF `message` field contains `[Status: pending]` with no `[Status: failed]` and no `[Error:` substring.

**Root cause:** cc-test-runner spawns a Claude Code subprocess per journey with a finite turn budget. Complex journeys (7+ steps involving navigation + verify + cleanup) exhaust the budget before completing. Remaining steps are marked `pending` and the journey is marked `failed`.

**Fix:** `runner.py` `_detect_gaps_and_upsert` now detects this pattern and skips `detect_gaps` entirely — the journey produces no `qa_known_defects` row and no wiki article. A `SKIP [runner-turn-limit]` line is printed instead.

**Prevention:** Keep journeys ≤ 6 steps. If a flow genuinely needs 7+ steps, split into two journeys where the second starts from a known persisted state.

**Cross-evidence pattern:** When `jp-J-X` fails with pending steps, check if another journey that exercises the same feature (e.g. jp-J10 for delete, jp-J04 for jobs page) passes — that cross-validates the feature works and confirms the FP.

---

## Per-Product Notes

### JobPortal (jp)

| Item | Value |
|------|-------|
| Deep spec | `jp-journeys/jp-deep.json` (12 journeys) |
| Backend URL | `https://jobc.phronex.com` (EC2) |
| Portal QA URL | `http://localhost:3002` (DevServer) |
| QA accounts | `qa-jp-free@phronex.com`, `qa-jp-standard@phronex.com`, `qa-jp-pro@phronex.com` |
| Billing fix validated | `ada45d1` — standard tier label correct (jp-J08 PASS, run 2026-04-29) |
| Run 3 result | 4/12 PASS, 3 real defects fixed (`b740a6a` portal + `aa2c0fa` jobportal), 5 turn-limit FPs |

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
