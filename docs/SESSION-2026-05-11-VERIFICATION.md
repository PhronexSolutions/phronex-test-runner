# Session 2026-05-11 — Implementation Verification Checklist

Captures all requirements from the overnight JourneyHawk analysis session and
what was implemented to address them. Use this during the next CC/JP/ComC test
run to verify each capability end-to-end.

---

## 1. Credential Guessing — Permanent Fix

**Requirement:** Claude test agent was guessing credentials when trunk sessions
expired mid-run because generated journeys had no explicit credential references.
Three-point fix needed:

| Point | What | Where | Commit |
|-------|------|-------|--------|
| 1a | `_build_steps_from_route()` emits `QA_SUPERADMIN_PASSWORD` and `qa-test-journeyhawk@phronex.com` placeholder tokens in login steps | `journey_generator.py` | `3a3ba8a5` (pcommon) |
| 1b | `EnrichJourney` prompt instructs LLM to use exact credential placeholders | `llm_tasks/enrichment.py` | `3a3ba8a5` (pcommon) |
| 1c | Second-pass sed in `run-journeyhawk.sh` replaces credential placeholders (not just URLs) | `run-journeyhawk.sh` line ~987 | `9386214` (test-runner) |

### Verification steps (next run)

- [ ] **V1.1** Grep generated spec files for `QA_SUPERADMIN_PASSWORD` — should appear in login steps of non-oracle journeys BEFORE sed runs
- [ ] **V1.2** After sed pass, grep for `QA_SUPERADMIN_PASSWORD` — should be ZERO (all replaced with actual credentials)
- [ ] **V1.3** Watch browser console/logs during trunk-expired runs — should NOT see "Incorrect password" or "Invalid credentials" errors from guessed passwords
- [ ] **V1.4** Check enriched journeys (`*.enriched.json` if cached) — login steps should reference `QA_SUPERADMIN_PASSWORD`, not "log in if needed" or "enter admin credentials"

---

## 2. Journey Graph Merging

**Requirement:** Detect that Journey A (15 steps) and Journey B (12 overlapping + 7 new)
share a common prefix, then graft B's unique leaf branch onto A. Make specs grow
deeper with each run instead of wider. Remove duplication while augmenting journeys
with each new learning.

| Component | File | Lines | Commit |
|-----------|------|-------|--------|
| Step fingerprinter | `testing/step_fingerprinter.py` | 138 | `38c6ba90` |
| Journey merger (SUBTREE_GRAFT + PREFIX_MERGE) | `testing/journey_merger.py` | 216 | `38c6ba90` |
| Curator Operation 2.5 wiring | `testing/spec_curator.py` | +30 lines | `38c6ba90` |
| `--merge-depth` CLI flag | `run-journeyhawk.sh` | +8 lines | `349b596` |
| Runner parameter propagation | `testing/runner.py` | +3 lines | `38c6ba90` |

**Merge logic:**
- SUBTREE_GRAFT: donor journey ≥80% steps covered by host → graft unique tail
- PREFIX_MERGE: ≥60% prefix ratio → merge shared prefix + branch at divergence point
- `--merge-depth N` flag: minimum overlapping steps to consider (default 5)
- Curation log: `operation=graph_merged` with `reason=SUBTREE_GRAFT` or `PREFIX_MERGE`

### Verification steps (next run)

- [ ] **V2.1** Run with `--merge-depth 5` (default) and check curator output: `graph_merged=N` should appear in the `[curator]` log line
- [ ] **V2.2** Query `qa_curation_log WHERE operation = 'graph_merged'` — should have entries with `reason` containing SUBTREE_GRAFT or PREFIX_MERGE
- [ ] **V2.3** Compare spec count before/after curation — merged journeys should reduce total count while increasing average step depth
- [ ] **V2.4** Check that merged journeys have valid step IDs (no duplicates, no gaps in step ordering)
- [ ] **V2.5** Portal: QA Dashboard → Feedback Loop tab → "Journey graph merges" section should show merge entries per product

---

## 3. DocChain Test Feedback Loop (Test → Learn → Document → Test)

**Requirement:** Close the flywheel: JH finds defects/patterns → writes to QA DB →
new DocChain child reads high-confidence patterns → appends `<section id="test-insights">`
to TEST-ORACLES.html → enriches USER-SPEC.html with edge cases → next JH run generates
deeper journeys from enriched docs.

| Component | File | Lines | Commit |
|-----------|------|-------|--------|
| Test insights injector (DocChain child) | `docchain/children/test_insights_injector.py` | 426 | `38c6ba90` |
| Stage gate wiring (pre-run injection) | `docchain/stage_gate.py` | +12 lines | `38c6ba90` |
| Runner Phase 90 A8 (post-run injection) | `testing/runner.py` | +25 lines | `432f2acf` |
| Flywheel metrics DB table | `testing/_qa_db.py` | +30 lines | `432f2acf` |
| SKILL.md Phase 0.5 documentation | `Phronex_Internal_QA_JourneyHawk/SKILL.md` | +20 lines | `432f2acf` |
| Tests (29 tests, 5 classes) | `tests/testing/test_test_insights_injector.py` | 228 | `38c6ba90` |

**Injection sources (4 QA DB tables):**
- `qa_wiki_articles` — confidence ≥ 0.70
- `qa_patterns` — occurrence_count ≥ 3
- `qa_known_defects` — fixed_at IS NOT NULL (proven edge cases only)
- `qa_prevention_rules` — status = 'active'

**Two injection points:**
- Pre-run: `stage_gate.py` calls `inject_test_insights()` after DocChain gates pass
- Post-run: `runner.py` Phase 90 A8 calls it after resource verification

**Properties:** idempotent (re-running produces identical output), resolved-only
(no speculative defects), data-source traceability (`data-source="journeyhawk"` attribute).

### Verification steps (next run)

- [ ] **V3.1** After a run with ≥1 fixed defect: check `TEST-ORACLES.html` — should contain `<section id="test-insights">` with `<h3>` sub-sections (Edge Cases, Patterns, Prevention Rules)
- [ ] **V3.2** Check `USER-SPEC.html` — should contain `<aside class="test-insights" data-source="journeyhawk">` elements per feature section
- [ ] **V3.3** Run the injector twice — output should be identical (idempotency: old block replaced, not appended)
- [ ] **V3.4** Query `qa_feedback_loop_metrics` — should have a row for this run with `wiki_articles`, `patterns`, `defects`, `prevention_rules` counts
- [ ] **V3.5** Check `oracles_modified` and `spec_modified` booleans in the metrics row — should be true if injections occurred
- [ ] **V3.6** Portal: QA Dashboard → Feedback Loop tab → "Feedback loop flywheel" section should show aggregated stats
- [ ] **V3.7** Portal: "Injection history by product" table should show the run with a coloured breakdown bar
- [ ] **V3.8** On the NEXT run after injection: verify journey generation reads the enriched docs and produces deeper/more targeted journeys (compare journey step count and specificity to pre-injection baseline)

---

## 4. Pre-commit Prevention Guard

**Requirement:** Active prevention rules from `qa_prevention_rules` (learned from
JourneyHawk defect analysis) should block commits that reintroduce the same anti-patterns.

| Component | File | Lines | Commit |
|-----------|------|-------|--------|
| Guard core module | `testing/prevention_guard.py` | 223 | `2cf3a5cd` |
| CLI entry point | `testing/prevention_guard_cli.py` | 43 | `2cf3a5cd` |
| Shell hook script | `scripts/prevention-guard-hook.sh` | 30 | `2cf3a5cd` |
| Tests (22 tests, 5 classes) | `tests/testing/test_prevention_guard.py` | 259 | `2cf3a5cd` |
| MachineSetup auto-install | `skills/.../setup_project.py` | +35 lines | `30dcb4b1` |
| MachineSetup SKILL.md v1.3 | `skills/.../SKILL.md` | +10 lines | `30dcb4b1` |

**Design decisions:**
- Fail-open: exits 0 if `PHRONEX_QA_DATABASE_URL` unset or DB unreachable
- Filters out invalid regex patterns and LLM-generated prose (>8 words)
- Scans only source files (.py, .ts, .tsx, .js, .jsx, .sh, .sql)
- Uses same query pattern as `qa_context_hook.py`: `%s = ANY(applicable_products) OR 'all' = ANY(applicable_products)`

### Verification steps (next run/commit)

- [ ] **V4.1** On DevServer with `PHRONEX_QA_DATABASE_URL` set: stage a file containing a known anti-pattern (e.g. `status = "ok"`) and attempt `git commit` — should see violation report and exit 1
- [ ] **V4.2** Same commit with `git commit --no-verify` — should bypass the guard
- [ ] **V4.3** On a machine WITHOUT `PHRONEX_QA_DATABASE_URL`: `git commit` should pass silently (fail-open)
- [ ] **V4.4** Run `setup_project.py --audit` — should show prevention-guard link status for each repo
- [ ] **V4.5** Check that portal and ComC repos (which have their own pre-commit hooks) were NOT overwritten

---

## 5. Bug Fix: Injector DB Schema Mismatch

**Requirement:** `_fetch_prevention_rules()` in `test_insights_injector.py` used wrong
column names that silently returned empty results.

| Before (broken) | After (fixed) | Commit |
|-----------------|---------------|--------|
| `WHERE is_active = true` | `WHERE status = 'active'` | `2cf3a5cd` |
| `AND product_slug IN (%s, 'all')` | `AND (source_product_slug = %s OR %s = ANY(applicable_products))` | `2cf3a5cd` |

### Verification steps (next run)

- [ ] **V5.1** Run injector against a product with active prevention rules — the "Prevention Rules" section in TEST-ORACLES.html should now be populated (was previously always empty due to the query error)
- [ ] **V5.2** Check injector stderr/logs — no psycopg2 `UndefinedColumn` errors

---

## 6. Machine Sync — Prevention Guard Hook Auto-Install

**Requirement:** New machines (Acer laptop) should get the prevention guard hook
installed automatically during project setup.

| Component | Change | Commit |
|-----------|--------|--------|
| `setup_project.py` | `install_git_hooks()` symlinks `prevention-guard-hook.sh` → `.git/hooks/pre-commit` for each project | `30dcb4b1` |
| `setup_project.py` | Audit mode reports hook status per repo | `30dcb4b1` |
| `setup_project.py` | Fixed pre-existing Python 3.13 f-string syntax error (line 340) | `30dcb4b1` |
| `SKILL.md` v1.3 | Documents hook in setup flow, sync checklist, failure runbook | `30dcb4b1` |

### Verification steps (on Acer machine)

- [ ] **V6.1** Run `python setup_project.py --role fullstack` — should print "pre-commit hook: linked to prevention-guard-hook.sh" for each repo
- [ ] **V6.2** Run `python setup_project.py --audit` — "Git Pre-commit Hooks" section should show status per repo
- [ ] **V6.3** Without `PHRONEX_QA_DATABASE_URL` set: `git commit` in any repo should pass (fail-open)

---

## Hook Installation Status (DevServer — 2026-05-11)

| Repo | Hook Status |
|------|-------------|
| phronex-common | LINKED |
| phronex-portal | Existing (cross-product import checker) |
| phronex-test-runner | LINKED |
| phronex-auth | LINKED |
| contentcompanion | LINKED |
| jobportal | LINKED |
| praxis | LINKED |
| phronex-command-centre | Existing (Alembic chain validator) |
| phronex-website | LINKED |

---

## Commit Reference (All Repos)

**phronex-common** (5 commits):
- `38c6ba90` — journey graph merger + DocChain test insights injector
- `432f2acf` — wire test feedback loop into SKILL.md + flywheel metrics table
- `98515fb1` — exempt runner='db' journeys from Class 5 garbage filter
- `2cf3a5cd` — pre-commit prevention guard + fix injector DB schema
- `30dcb4b1` — wire prevention guard hook into MachineSetup skill

**phronex-portal** (1 commit):
- `dc919c9` — add Feedback Loop tab to QA dashboard

**phronex-test-runner** (2 relevant commits):
- `9386214` — extend second-pass sed to replace credential placeholders
- `349b596` — add --merge-depth flag to run-journeyhawk.sh

**jobportal** (1 commit):
- `b5cf699` — refresh DocChain auto-generated docs
