# STRATEGIST-RUNBOOK.md
## Operational Rollback Guide — v18.0 Test Strategist Layer

> **U6 DoD requirement** (STRATEGIST-ARCHITECTURE.md §12.bis.1): each phase must document
> how to disable it independently without killing the whole strategist.

---

## 1. The Three-Mode Kill Switch

Every strategist component checks `get_mode()` before any DB write or file mutation.

| Mode | Effect |
|------|--------|
| `ACTIVE` | Full operation — all reads, writes, and mutations fire |
| `READ_ONLY` | Evaluation runs; all writes become dry-run log output only |
| `DISABLED` | Pure passthrough — every component short-circuits immediately |

**Read-through priority** (highest → lowest):
1. `STRATEGIST_MODE_OVERRIDE` env var (per-run flag from `run-journeyhawk.sh --strategist-mode`)
2. `qa_strategy_state.active_mode` in phronex_qa DB
3. `STRATEGIST_MODE` env var in `.qa.env`
4. Fail-safe default: `DISABLED` if DB unreachable

**Fail-safe guarantee:** If phronex_qa is unreachable, all components default to `DISABLED`.
No strategist code ever blocks a JourneyHawk run.

---

## 2. Full Kill (All Components)

Use when: incident in production, unknown blast radius, need immediate safety.

```bash
# In phronex-test-runner/.qa.env
STRATEGIST_MODE=DISABLED
```

Then restart any process that sources `.qa.env` (ComC if using Option A cron, or the shell
session if running `run-journeyhawk.sh` manually).

**Verify:**
```bash
# Next run should print:
# [strategist:DISABLED] short-circuit — no strategist operations
grep "DISABLED.*short-circuit\|skip phase82 seam\|passthrough" /var/log/journeyhawk/*.log
```

**Re-enable:** Change `STRATEGIST_MODE=ACTIVE` (or remove the line — defaults to ACTIVE if DB row exists, DISABLED if DB unreachable).

---

## 3. Per-Component Rollback

### P3 — RCAEngine (STRAT-02)

**What it does:** Classifies each new defect in `qa_known_defects` into a root-cause category. Writes to `qa_defect_rca`. LLM fallback writes proposals to `qa_proposed_heuristics`.

**To disable only RCA (keep everything else):**
```bash
# .qa.env
RCA_LLM_BUDGET_USD=0          # disables LLM fallback (deterministic still runs)
STRATEGIST_MODE=READ_ONLY     # RCA runs but writes nothing to qa_defect_rca
```

**Expected log:**
```
[strategist:READ_ONLY:rca] would write qa_defect_rca: defect_id=123 category=BROKEN_AUTH
```

**Verify:** `SELECT COUNT(*) FROM qa_defect_rca WHERE created_at > NOW() - INTERVAL '1h'` should stay at 0.

**Re-enable:** Remove `STRATEGIST_MODE=READ_ONLY` or set to `ACTIVE`.

---

### P4 — CrossRepoSweepOrchestrator (STRAT-03)

**What it does:** Async cron at 02:00 IST sweeps all 7 product repos for pattern recurrence. Writes to `qa_sweep_overflow`. May file Jira tickets (`file_jira` action).

**To disable only the sweep cron:**
```bash
# Remove the cron entry (Option A — user crontab)
crontab -e
# Delete the line:
# 30 20 * * * ouroborous cd /home/ouroborous/code/phronex-common && ...

# Verify removed:
crontab -l | grep sweep_runner
# Should return nothing
```

The `sweep_runner.py` module is fail-open (exits 0 even if DB unreachable). Removing the cron entry is sufficient — no restart needed.

**To keep sweep running but disable Jira filing:**
```bash
# .qa.env
SWEEP_JIRA_ENABLED=false       # sweep still runs, proposed_action stays 'investigate'
```

**Re-enable:** Re-add cron entry from `phronex-common/scripts/sweep_cron_entry.sh`.

---

### P5.5 — TEST-ORACLES.html baselines

**What it does:** Provides the per-product verdict rubric that ValidationAuditor (P10) reads. Without this file, ValidationAuditor returns `UNVERIFIABLE` for all steps (non-blocking).

**To disable ValidationAuditor for a specific product (e.g. Portal):**
```bash
# Remove or rename the oracle file for that product
mv /home/ouroborous/code/phronex-portal/.docs/TEST-ORACLES.html \
   /home/ouroborous/code/phronex-portal/.docs/TEST-ORACLES.html.disabled
```

**Expected behaviour:** ValidationAuditor logs `[oracle] TEST-ORACLES.html missing for portal — all verdicts UNVERIFIABLE`. No crash. `qa_journey_verdicts` rows are written with `verdict='UNVERIFIABLE'`.

**Re-enable:** Restore the file.

---

### P10 — ValidationAuditor (STRAT-13)

**What it does:** After each run, reads the TEST-ORACLES rubric and writes per-step `PASS_ORACLE`/`FAIL_ORACLE`/`UNVERIFIABLE` verdicts to `qa_journey_verdicts`. Fires `ORACLE_FAIL` events to `qa_strategist_events`.

**To disable only ValidationAuditor:**
```bash
# STRATEGIST_MODE=READ_ONLY causes ValidationAuditor to evaluate but not write
STRATEGIST_MODE=READ_ONLY
```

Verdicts are logged to stderr (`[strategist:READ_ONLY:validation]`) but not persisted.

**Full disable (no evaluation):**
```bash
STRATEGIST_MODE=DISABLED
```

**Verify disable:** `SELECT COUNT(*) FROM qa_journey_verdicts WHERE created_at > NOW() - INTERVAL '1h'` returns 0.

---

### P11 — UXObserver (STRAT-14)

**What it does:** Computes 6 fatigue metrics per run (retry rate, abandonment rate, time-on-task delta, error-recovery loop count, oracle-skip rate, feedback-prompt opt-out rate). Writes to `qa_ux_signals`. ">95% approval rate" triggers a calibration prompt.

**To disable:**
```bash
STRATEGIST_MODE=READ_ONLY     # metrics computed, nothing written
# or
STRATEGIST_MODE=DISABLED      # metrics not computed at all
```

**Expected log (READ_ONLY):**
```
[strategist:READ_ONLY:ux] would write qa_ux_signals: cycle_id=42 retry_rate=0.12
```

---

### P12 — FeedbackConsolidator (STRAT-15) — Highest Risk

**What it does:** Writes proposed changes to 5 sinks: CODING-PATTERNS.md, DocChain FEEDBACK.html, DocChain PROPOSED-INVARIANTS.html, WikiStore (`qa_wiki_articles`), TEST-ORACLES queue. All writes are reversible via git diff.

**This is the highest-risk component.** When in doubt, flip to READ_ONLY rather than DISABLED — READ_ONLY preserves the audit trail of *what would have been written* without touching files.

**To flip to dry-run (recommended for incidents):**
```bash
STRATEGIST_MODE=READ_ONLY
```

**Expected log:**
```
[strategist:READ_ONLY:feedback] would write CODING-PATTERNS.md: [new pattern: ...]
[strategist:READ_ONLY:feedback] would write WikiStore: article_id=99 confidence bump
```

**To revert a write that already landed:**
```bash
# FeedbackConsolidator tracks all writes in qa_proposed_heuristics
# Find the entry:
psql $QA_DATABASE_URL -c "SELECT id, sink, summary, applied_at FROM qa_proposed_heuristics ORDER BY applied_at DESC LIMIT 10;"

# Each write produces a reversible git patch stored in evidence_json.
# To revert CODING-PATTERNS.md:
cd /home/ouroborous/code/phronex-common
git diff HEAD~1 -- config/CODING-PATTERNS.md   # confirm what changed
git revert HEAD --no-commit                      # or manually restore the file
```

**Rate guards (auto-limiting without intervention):**
- Max 3 CODING-PATTERNS entries per day (pg_advisory_lock enforced)
- Max 5 WikiStore mutations per hour
- Requires oracle confidence ≥ 0.70 before any write fires

---

### P13 — STRATEGIST_MODE Auto-Degrade (STRAT-16)

**What it does:** When 2 consecutive `learning_grade=F` cycles are detected, automatically demotes `qa_strategy_state.active_mode` from `ACTIVE` to `READ_ONLY`. Fires a consolidated alert via `phronex_common.communications`.

**After auto-degrade fires, manual re-enable is required:**
```bash
# Check current DB-backed mode
psql $QA_DATABASE_URL -c "SELECT product_slug, active_mode, consecutive_f_count FROM qa_strategy_state;"

# Re-enable after fixing the root cause
psql $QA_DATABASE_URL -c "UPDATE qa_strategy_state SET active_mode='ACTIVE', consecutive_f_count=0 WHERE product_slug='<slug>';"
```

**To disable auto-degrade (run ACTIVE even with consecutive F grades):**
```bash
# .qa.env — STRATEGIST_AUTO_DEGRADE is checked inside auto_degrade_check()
STRATEGIST_AUTO_DEGRADE_ENABLED=false
```

> Note: This env var gates the `auto_degrade_check()` call inside `_phase82_seam`. The DB row
> update (which `get_mode()` reads) only happens when auto-degrade fires — disabling it means
> the DB mode stays as-is regardless of F-grade streaks.

---

## 4. Incident Escalation Decision Tree

```
Incident occurs during JourneyHawk run
    │
    ├─ Unknown blast radius or urgent?
    │       └─► Full kill: STRATEGIST_MODE=DISABLED in .qa.env
    │
    ├─ Specific component writing unexpected data?
    │       └─► STRATEGIST_MODE=READ_ONLY — preserves audit trail
    │
    ├─ FeedbackConsolidator wrote bad data to CODING-PATTERNS.md?
    │       └─► git revert the entry (reversibility guarantee — each write trackable)
    │           then set STRATEGIST_MODE=READ_ONLY until root cause found
    │
    ├─ Auto-degrade fired unexpectedly?
    │       └─► Check qa_strategy_state.consecutive_f_count
    │           Investigate qa_journeys.learning_grade for last 2 cycles
    │           Fix root cause, then UPDATE qa_strategy_state SET active_mode='ACTIVE'
    │
    └─ GA cron firing SYSTEM_GA prematurely?
            └─► Check qa_strategist_events for SYSTEM_GA rows with wrong milestone_version
                DELETE the duplicate row (idempotent dedup uses event_type+milestone_version)
```

---

## 5. Verification Commands Reference

```bash
# Current effective mode for each product
psql $QA_DATABASE_URL -c "SELECT product_slug, active_mode FROM qa_strategy_state;"

# Recent strategist events (last 24h)
psql $QA_DATABASE_URL -c "SELECT event_type, phase_id, created_at FROM qa_strategist_events ORDER BY created_at DESC LIMIT 20;"

# Cycle gate holds
psql $QA_DATABASE_URL -c "SELECT cycle_id, gate_passed, held_emission, failure_reasons FROM qa_cycle_log ORDER BY created_at DESC LIMIT 10;"

# FeedbackConsolidator proposed writes (pending)
psql $QA_DATABASE_URL -c "SELECT id, sink, status, summary FROM qa_proposed_heuristics WHERE status='pending_apply' ORDER BY created_at DESC;"

# DoD check (structural invariants)
PHRONEX_QA_DATABASE_URL_SYNC=$QA_DATABASE_URL python phronex-common/scripts/strategist_dod_check.py
```

---

*Last updated: 2026-05-02 — U6 DoD gap closure (quick 260502-o3t)*
*Architecture reference: STRATEGIST-ARCHITECTURE.md §12.bis.1*
