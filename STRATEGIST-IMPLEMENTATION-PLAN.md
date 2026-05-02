# StrategistLayer — Implementation Plan & Effort Estimate

> **Source spec:** `STRATEGIST-ARCHITECTURE.md` (this directory)
> **Status:** Pre-execution plan, awaiting approval
> **Owner:** phronex-common (`phronex_common.testing.*`) + Phronex_Internal_Product_DocChain skill family
> **Execution path:** Standard GSD — each phase becomes a GSD phase with `/gsd:plan-phase` → `/gsd:execute-phase` → `/gsd:verify-work` cycle

---

## 1. How to read this plan

Each phase below has:

- **Effort range** in engineering hours (low / expected / high) — wider range = more unknowns
- **Confidence** — how sure I am the expected value is right (HIGH/MEDIUM/LOW)
- **Critical-path dependencies** — what must be done first
- **Risk factors** — specific things that would push the high estimate
- **GSD phase mapping** — how this maps to milestone phases when planning

**Effort assumes:** single engineer + Claude Code pair-programming, working from a clean DocChain corpus. **No buffer included** for unrelated context-switching, EC2 incidents, or day-job churn — add 20% real-world buffer to any number you commit to.

**Pace assumption:** ~5 productive hours/day. So 40 hours = 1 calendar week of focused work, or 2 calendar weeks at half-pace alongside other work.

---

## 2. Total effort summary

| Block | Phases | Expected hours | Range | Calendar (full-time) | Calendar (half-pace) |
|---|---|---|---|---|---|
| **Block A — Quick wins** (waste reduction) | P1, P2 | **18h** | 14–26h | 4 days | 1.5 weeks |
| **Block B — Foundations** (DB + assessment) | P3, P4, P5 | **40h** | 30–58h | 8 days | 3 weeks |
| **Block C — Strategist core** | P5.5, P6, P7 | **42h** | 32–58h | 8 days | 3 weeks |
| **Block D — DocChain expansion** | P8, P9 | **62h** | 42–96h | 12 days | 5 weeks |
| **Block E — Closed-loop completion** | P10, P11, P12 | **48h** | 36–68h | 10 days | 4 weeks |
| **Block F — Visibility + cutover** | P13, system gate | **18h** | 14–26h | 4 days | 1.5 weeks |
| **TOTAL** | 13 phases + system | **228h** | **168–332h** | **~46 days (9 weeks)** | **~17 weeks (4 months)** |

**Realistic recommendation:** plan for **240–300 hours** of focused work. The architecture promises "exponential improvement" — that compounds *after* the system is built, not during construction.

**Triage option:** Block A alone (18h, ~half a week) eliminates ~50% of current QA waste. If everything else slipped, Block A still pays for itself within 2 QA cycles. Strongly recommend shipping Block A first, *then* deciding whether to commit to the full 9-week build.

> **Phase compression option:** The 13-phase breakdown above is for granular tracking. **§6.bis recommends compressing to 3 GSD phases + 1 P5.5 content interlude + 1 optional Block A spike** — same scope, ~10h less ceremony. Read §6.bis before kicking off `/gsd:plan-phase`.

---

## 3. Phase-by-phase plan

### Block A — Quick wins (Week 1)

#### P1 — RunArbiter (in-run abort gate)

| Field | Value |
|---|---|
| **Effort** | 8h expected (low: 6h, high: 12h) |
| **Confidence** | HIGH — well-scoped, no new dependencies |
| **Depends on** | Nothing (can start immediately) |
| **Risk factors** | RunArbiter behaviour at the edge of cc-test-runner's existing turn-budget logic — requires careful integration testing |
| **GSD mapping** | Single phase: `phronex-common Phase X — Strategist P1 RunArbiter` |

**Tasks:**
1. Create `phronex_common/testing/strategist/arbiter.py` (~80 LOC)
2. Define `ArbiterDecision`, `RunState`, `JourneyResult` dataclasses in `phronex_common/testing/strategist/types.py`
3. Wire into `phronex-test-runner/runner.py` after-journey hook
4. Add `qa_journeys.abort_reason` column (Alembic revision)
5. Unit tests: 3 abort conditions + wiki-driven abort + continue path
6. Acceptance demo: induce deliberate auth rate-limit, confirm abort at journey 4
7. Update `JOURNEYHAWK-LEARNINGS.md` with new abort behaviour
8. Run `strategist_dod_check.py P1` (script doesn't exist yet — see P3)

**Note:** P1 ships before `strategist_dod_check.py` exists. For P1 only, U8 is verified manually. P3 builds the checker script, which is then required for P2 onwards.

---

#### P2 — Fixture Guard

| Field | Value |
|---|---|
| **Effort** | 10h expected (low: 8h, high: 14h) |
| **Confidence** | HIGH — straightforward DB + preflight script |
| **Depends on** | Nothing (parallelisable with P1) |
| **Risk factors** | Initial fixture inventory is manual — getting accurate seed data for ComC/Praxis/etc requires domain knowledge, not just engineering |
| **GSD mapping** | Single phase: `phronex-common Phase X+1 — Strategist P2 Fixture Guard` |

**Tasks:**
1. Alembic revision for `qa_fixture_requirements` table (with R5 provenance fields)
2. Create `phronex_common/testing/strategist/preflight_fixtures.py`
3. Hand-author initial fixture inventory: ~15 entries across 7 products (ComC pipeline, Praxis people/skills, CC flagged, etc.) — **2h of this 10h is the inventory itself**
4. Wire `preflight_fixtures.py` into runner.py before run set is finalised
5. Write `reseed_expired_fixtures.sh` cron script
6. Add cron entry to DevServer crontab
7. Unit tests: MISSING fixture drops journey, SEEDED proceeds, EXPIRED triggers reseed
8. Acceptance demo: extended portal suite drops 4 known-doomed journeys with explicit messages

---

### Block B — Foundations (Week 2–3)

#### P3 — Self-Assessment to DB + Baseline

| Field | Value |
|---|---|
| **Effort** | 14h expected (low: 10h, high: 22h) |
| **Confidence** | MEDIUM — schema design questions emerge mid-build |
| **Depends on** | P1, P2 (need run-arbiter outcomes + fixture-drop counts to compute meaningful grades) |
| **Risk factors** | Grade rubric (`qa_grade_rubrics`) is opinionated — first version will be wrong, expect 1–2 revision cycles after first runs. Cycle-close gate (R1) is subtle to implement correctly. |
| **GSD mapping** | Single phase: `phronex-common Phase X+2 — Strategist P3 Self-Assessment + Baseline` |

**Tasks:**
1. Alembic revision: `qa_strategy_state`, `qa_cycle_assessment`, `qa_grade_rubrics`, `qa_baseline_run`, `qa_strategist_events`
2. Seed `qa_grade_rubrics` with `rubric_version='v1'` thresholds (4h of design + write — get this right)
3. Create `phronex_common/testing/strategist/post_run.py` — writes state + assessment after every run
4. Implement cycle-close gate (R1): `cycle_closed_at` only set when verify-run conditions met
5. Implement baseline capture: one-shot script `capture_baseline.py` per product
6. Build `phronex_common/scripts/strategist_dod_check.py` (U8 mechanical checker) — required from this phase forward
7. Wire `qa_strategist_events` logging library — reused by every subsequent phase
8. Unit tests + integration test through phronex_qa
9. Acceptance demo: trigger flaky verify-run, observe cycle stays open

---

#### P4 — RCAEngine + qa_defect_rca

| Field | Value |
|---|---|
| **Effort** | 16h expected (low: 12h, high: 24h) |
| **Confidence** | MEDIUM — heuristics tuning is iterative |
| **Depends on** | P3 (needs `qa_strategist_events` + DoD checker) |
| **Risk factors** | Heuristics YAML — initial 10 patterns will miss real defects; expect 2–3 tuning passes after observing classifier hit-rate on real data. LLM fallback prompt engineering. |
| **GSD mapping** | Single phase: `phronex-common Phase X+3 — Strategist P4 RCAEngine` |

**Tasks:**
1. Alembic revision: `qa_defect_rca`, `qa_proposed_heuristics`
2. Author `phronex_common/testing/rca/heuristics.yaml` — start with 10 deterministic patterns covering top defect classes from existing `qa_known_defects` data
3. Build `phronex_common/testing/rca/engine.py` — deterministic-first match, LLM-fallback
4. Build LLM-fallback prompt + cost-cap enforcement
5. Implement structured `pattern_signature` tuple (R2)
6. Build `backfill_rca_history.py` opt-in script
7. Unit tests: each heuristic + LLM mock + budget cap exceeded
8. Acceptance demo: file 5 defect classes, observe correct classifications

---

#### P5 — CrossRepoSweepOrchestrator

| Field | Value |
|---|---|
| **Effort** | 10h expected (low: 8h, high: 14h) |
| **Confidence** | HIGH — well-scoped once RCA exists |
| **Depends on** | P4 (sweeps consume RCA's `pattern_signature` + `sweep_query`) |
| **Risk factors** | Cron timing on DevServer — must coordinate with existing 02:00 IST cron jobs |
| **GSD mapping** | Single phase: `phronex-common Phase X+4 — Strategist P5 CrossRepoSweep` |

**Tasks:**
1. Alembic revision: `qa_sweep_overflow` table
2. Build `phronex_common/testing/rca/sweep.py` — bounded sweep orchestrator
3. Implement budget enforcement (3 RISK/repo, 30-day cooldown, confidence-gate)
4. Cron script `nightly_sweep.sh` — adds to DevServer crontab
5. Async job queue (simple Postgres-backed table, not Celery — keep it simple)
6. Unit tests + integration test with mock repo set
7. Acceptance demo: file `billing-config` RCA, observe overnight sweep finds JP + CC instances

---

### Block C — Strategist core (Week 4)

#### P5.5 — Hand-authored TEST-ORACLES.html (proof-of-value before P9)

| Field | Value |
|---|---|
| **Effort** | 12h expected (low: 8h, high: 18h) |
| **Confidence** | MEDIUM — content quality matters more than code |
| **Depends on** | Nothing strictly — but doing it after P3 means we know what fields the oracles need |
| **Risk factors** | Determining the right oracle format is iterative — first 3 oracles will be rewritten when the next 7 reveal pattern issues |
| **GSD mapping** | Manual content work, not a GSD phase — direct `/gsd:quick` task |

**Tasks:**
1. Read `phronex-portal/.docs/USER-SPEC.html` and identify 10 testable features
2. Author `phronex-portal/.docs/TEST-ORACLES.html` — 10 entries with full preconditions, procedure, expected state, failure modes, access prereqs, data prereqs
3. Convert 3 oracles to journey specs manually — validates the format is unambiguous
4. Capture lessons in `phronex-common/skills/Phronex_Internal_Product_DocChain/children/docchain-test-oracles/REQUIREMENTS.md`
5. Acceptance demo: a 4th journey converted by Claude (or a human) without re-reading the format spec

---

#### P6 — StrategistLayer.pre_run()

| Field | Value |
|---|---|
| **Effort** | 16h expected (low: 12h, high: 24h) |
| **Confidence** | MEDIUM — orchestration of 4 question modules |
| **Depends on** | P3 (state DB), P4 (RCA), P5 (sweep history), P5.5 (oracle format for Q4 fixture verification) |
| **Risk factors** | Hysteresis (R4) is non-obvious to implement — easy to get wrong. Cold-start logic (R12) needs careful testing. |
| **GSD mapping** | Single phase: `phronex-common Phase X+5 — Strategist P6 Pre-Run Assessment` |

**Tasks:**
1. Build `phronex_common/testing/strategist/pre_run.py` orchestrator
2. Build 4 question modules: `yield_trend.py`, `spec_coverage.py`, `ethos_priorities.py`, `fixture_verification.py`
3. Implement signal hysteresis (R4) — flip requires 2 consecutive runs
4. Implement cold-start exit (R12) — 3 runs OR 30 days
5. Replace existing `RunFilter` in runner.py with Strategist output consumer
6. Console output: log mutations applied, journeys dropped, journeys added — operator must be able to audit
7. Unit tests: each question independently + integration of all 4
8. Acceptance demo: 2 clean runs → signal flips MAINTAIN→EXPAND on run 3

---

#### P7 — WikiTestMutation directives

| Field | Value |
|---|---|
| **Effort** | 14h expected (low: 10h, high: 20h) |
| **Confidence** | MEDIUM — JSONB schema work + applier logic |
| **Depends on** | P6 (Strategist consumes mutations) |
| **Risk factors** | JSONB column migration on a populated `qa_wiki_articles` table needs care — backfill defaults for existing rows |
| **GSD mapping** | Single phase: `phronex-common Phase X+6 — Strategist P7 WikiMutations` |

**Tasks:**
1. Alembic revision: `qa_wiki_articles` ALTER — add 4 JSONB columns + change `is_contradicted` to `contradicted_in: TEXT[]` (R3)
2. Backfill: existing articles get `contradicted_in='{}'`, `test_mutation=NULL`, etc.
3. Build `phronex_common/testing/wiki/mutations.py` — applier that mutates journey specs in-memory
4. Implement bounded confidence promotion (+0.10/cap 0.95)
5. Implement mutation expiry (`expires_after_runs`)
6. Wire into pre_run pipeline (after P6 lands)
7. Unit tests: ADD_STEP, ADD_JOURNEY, SKIP_JOURNEY, REQUIRE_FIXTURE mutations
8. Acceptance demo: file `HAND_CODED_TAB_ID` article, observe ADD_STEP applied to all admin journeys

---

### Block D — DocChain expansion (Week 5–7) — biggest block, biggest unknowns

#### P8 — DocChain stage gates split

| Field | Value |
|---|---|
| **Effort** | 14h expected (low: 10h, high: 22h) |
| **Confidence** | MEDIUM — touches the JourneyHawk skill markdown which has its own quirks |
| **Depends on** | P5.5 (TEST-ORACLES format proven) |
| **Risk factors** | Bootstrap mode (R9) — STUB.html generation is conceptually simple but each child skill needs to handle its own stub case. Coordinating skill markdown updates with code changes. |
| **GSD mapping** | Single phase: `phronex-common Phase X+7 — Strategist P8 DocChain Stage Gates` |

**Tasks:**
1. Build `phronex_common/testing/docchain/stage_gates.py` with 6 stages
2. Each stage emits a `StageContextBundle` consumed by downstream
3. Implement bootstrap mode (R9): missing artefact → STUB.html with `confidence=LOW, stub=true`
4. Update `~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md` — replace monolithic PHASE 0 with 6 staged sub-gates
5. Update `phronex-common/skills/Phronex_Internal_Product_DocChain/SKILL.md` — bootstrap-mode behaviour for child skills
6. Unit tests: each stage gate halts cleanly on missing artefact
7. Integration test: rename USER-SPEC.html → gate halts → invoke DocChain → restore → gate proceeds
8. SkillBuilder gate (per CLAUDE.md invariant): SKILL.md changes go through `/Phronex_Builder_Dev_SkillBuilder`

---

#### P9 — New DocChain child skills (3 skills)

| Field | Value |
|---|---|
| **Effort** | 48h expected (low: 32h, high: 80h) — **biggest single phase** |
| **Confidence** | LOW — skill quality depends on iteration loops with real artefacts |
| **Depends on** | P5.5 (oracle format), P8 (stage gates can consume the new artefacts) |
| **Risk factors** | (a) Each skill is essentially a small DSL parser + generator, (b) generators must produce HTML that matches the hand-authored P5.5 baseline within 20% drift, (c) running against 4 products and validating outputs is ~1 day per skill per product = 12 days alone |
| **GSD mapping** | **Three GSD phases — one per skill**: P9a docchain-test-oracles, P9b docchain-integration-map, P9c docchain-quality-standards |

**Per-skill breakdown (each ~16h):**

For each of `docchain-test-oracles`, `docchain-integration-map`, `docchain-quality-standards`:

1. SkillBuilder gate (CLAUDE.md invariant): use `/Phronex_Builder_Dev_SkillBuilder` to design the skill — 2h
2. Implement skill scaffolding under `phronex-common/skills/Phronex_Internal_Product_DocChain/children/{skill}/` — 2h
3. Implement extractor (reads codebase + git history) — 4h
4. Implement HTML generator — 3h
5. Run against 4 products, iterate on output quality — 4h (this is the high-variance part)
6. Diff against hand-authored P5.5 baseline (only for `docchain-test-oracles`) — 1h
7. Acceptance demo: ComC produces all 3 artefacts, JourneyHawk consumes them next run

**Why the high range:** if any skill needs ≥3 iteration cycles to produce useful output (likely for `docchain-quality-standards` since "quality thresholds" are inherently fuzzy), add 8h per affected skill.

---

### Block E — Closed-loop completion (Week 8–9)

#### P10 — ValidationAuditor

| Field | Value |
|---|---|
| **Effort** | 14h expected (low: 10h, high: 20h) |
| **Confidence** | MEDIUM — depends heavily on TEST-ORACLES.html quality from P9 |
| **Depends on** | P9 (TEST-ORACLES.html generated) |
| **Risk factors** | Detecting "DRIFT" between original intent and observed behaviour is the hardest part — easy to over-flag |
| **GSD mapping** | Single phase: `phronex-common Phase X+10 — Strategist P10 ValidationAuditor` |

**Tasks:**
1. Build `phronex_common/testing/strategist/validation_auditor.py`
2. Parse USER-SPEC + TEST-ORACLES → spec_features list
3. Match against `qa_journeys` + `qa_known_defects` for coverage
4. Detect 3 drift types: UNCOVERED, BUILT_BUT_EMPTY, DRIFT
5. Write findings as `qa_wiki_articles` with `defect_class='COVERAGE_GAP'`
6. Calibrate `qa_cycle_assessment.validation_grade` against rubric
7. Acceptance demo: deliberately add USER-SPEC section with no journey, auditor flags within one cycle

---

#### P11 — UXObserver + qa_ux_signals

| Field | Value |
|---|---|
| **Effort** | 12h expected (low: 8h, high: 18h) |
| **Confidence** | MEDIUM — needs integration with cc-test-runner step hooks |
| **Depends on** | P9 (QUALITY-STANDARDS.html provides thresholds) |
| **Risk factors** | cc-test-runner step instrumentation — does the existing API expose enough to extract step_count, load_time_ms, empty_state_shown? May need cc-test-runner changes. |
| **GSD mapping** | Single phase: `phronex-common Phase X+11 — Strategist P11 UXObserver` |

**Tasks:**
1. Alembic revision: `qa_ux_signals` table
2. Build `phronex_common/testing/strategist/ux_observer.py`
3. Define observation hooks in cc-test-runner (or via post-run log parsing if hooks unavailable)
4. Implement per-run signal cap (R13) with fuzzy dedup → `occurrence_count` increment
5. Wire QUALITY-STANDARDS.html threshold lookups into `threshold_source` field
6. Build monthly review query → wire into portal panel (precursor for P13)
7. Acceptance demo: portal run produces ≥1 PERF signal for any page > 2s load

---

#### P12 — FeedbackConsolidator end-to-end

| Field | Value |
|---|---|
| **Effort** | 22h expected (low: 16h, high: 32h) |
| **Confidence** | MEDIUM — touches 5 destinations, each with its own write rules |
| **Depends on** | P10, P11 (consolidator needs validation + UX outputs) |
| **Risk factors** | Reversibility (`feedback_consolidator_undo.py`) is non-trivial — must track what was written where for each cycle. PROPOSED-INVARIANTS.md queue across 7 products. |
| **GSD mapping** | Single phase: `phronex-common Phase X+12 — Strategist P12 FeedbackConsolidator` |

**Tasks:**
1. Build `phronex_common/testing/strategist/feedback_consolidator.py`
2. Implement 5 destination writers: CODING-PATTERNS.md, DocChain FEEDBACK.md, PROPOSED-INVARIANTS.md (per product), WikiStore promotion, TEST-ORACLES.html append
3. Implement write-rate guards (1 per cycle per pattern)
4. Build `feedback_consolidator_undo.py CYCLE_ID` — every write is reversible
5. Add Tier 2 housekeeping check: block if PROPOSED-INVARIANTS.md > 10 unresolved entries > 14 days (R8)
6. Update `Phronex_Internal_Dev_Housekeeping` skill with the new check
7. Acceptance demo: close cycle with 2 fixed defects, observe correct writes to all 5 destinations

---

### Block F — Visibility + cutover (Week 10)

#### P13 — Portal TESTING_QUALITY panel

| Field | Value |
|---|---|
| **Effort** | 14h expected (low: 10h, high: 20h) |
| **Confidence** | HIGH — frontend pattern is well-established |
| **Depends on** | P12 (panel surfaces consolidator outputs) |
| **Risk factors** | UI design iterations — first version will need 1–2 revisions for clarity |
| **GSD mapping** | Single phase: `phronex-portal Phase X — Strategist P13 TESTING_QUALITY panel` |

**Tasks:**
1. Read existing `AuditDashboardPanel.tsx` patterns
2. Add `TESTING_QUALITY` category + label
3. New backend endpoint `/api/admin/testing-quality/summary` → reads from `qa_cycle_assessment` + `qa_strategist_events`
4. Render: latest cycle grade (4 dimensions + overall), trend arrow, days since last cycle close, STRATEGIST_MODE, RCA classifier hit-rate, top 5 active wiki mutations, PROPOSED-INVARIANTS.md queue depth
5. Phase completion bar: P1✅ P2✅ … (per §12.bis.5 forcing function)
6. Link to evidence bundles for latest run per product
7. UIGate compliance: brand tokens, copy review
8. Acceptance demo: all 7 products render correctly, grades match DB

---

#### System gate — S1–S8 GA monitoring (continuous)

| Field | Value |
|---|---|
| **Effort** | 4h expected (low: 4h, high: 6h) |
| **Confidence** | HIGH — straightforward cron + queries |
| **Depends on** | All previous phases |
| **Risk factors** | None — this is a monitoring layer over existing data |

**Tasks:**
1. Build `phronex_common/scripts/check_ga_gates.py` — runs all 8 S1–S8 checks
2. Cron entry: weekly check, posts to portal Audit tab
3. When all 8 green for 30 days → fire `qa_strategist_events` with `event_type='SYSTEM_GA'`
4. Telegram/email notification to Vivek when GA fires (existing communications abstraction)

---

## 4. Critical-path dependency graph

```
                                     ┌────────────────────┐
                                     │   Block A (Week 1) │
                                     │  P1 ───┐  P2       │ (parallelisable)
                                     └────────┼───────────┘
                                              │
                              ┌───────────────┴───────────────┐
                              │     Block B (Weeks 2–3)       │
                              │  P3 ──► P4 ──► P5             │ (serial)
                              └───────────────┬───────────────┘
                                              │
                          ┌───────────────────┴────────────────────┐
                          │           Block C (Week 4)             │
                          │  P5.5 ──► P6 ──► P7                    │ (serial; P5.5 can start earlier)
                          └───────────────────┬────────────────────┘
                                              │
                          ┌───────────────────┴────────────────────┐
                          │        Block D (Weeks 5–7)             │
                          │  P8 ──► P9a, P9b, P9c (parallelisable) │ (3 parallel skills)
                          └───────────────────┬────────────────────┘
                                              │
                          ┌───────────────────┴────────────────────┐
                          │      Block E (Weeks 8–9)               │
                          │  P10, P11 ──► P12                      │ (P10 + P11 parallel)
                          └───────────────────┬────────────────────┘
                                              │
                          ┌───────────────────┴────────────────────┐
                          │       Block F (Week 10+)               │
                          │  P13 ──► System Gate (continuous)      │
                          └────────────────────────────────────────┘
```

**Critical path** (longest sequential chain): P1/P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9 (slowest skill) → P10/P11 → P12 → P13

**Parallelisation opportunities** (if you ever have 2 sessions running concurrently):
- P1 + P2 in week 1
- P10 + P11 in week 8
- P9a + P9b + P9c (limited gain — each is iterative, hard to truly parallelise without confusion)

---

## 5. Effort distribution by repo

| Repo | Hours | % of total |
|---|---|---|
| `phronex-common` (most code) | 158h | 69% |
| `phronex-test-runner` (runner.py wiring + content) | 26h | 11% |
| Skills (`~/.claude/skills/` + DocChain children) | 30h | 13% |
| `phronex-portal` (P13 panel) | 14h | 6% |
| **Total** | **228h** | **100%** |

**Implication:** ~70% of work is in `phronex-common` — milestone scoping should treat this as primarily a phronex-common milestone (e.g. `v18.0 — Test Strategist Layer`), with smaller scoped phases in test-runner, portal, and skills.

---

## 6. Recommended milestone scoping

If you want to ship this through GSD's milestone structure, I'd recommend **two milestones, not one**:

### Milestone A — `phronex-common v18.0 — Test Strategist Layer (Foundations)`
**Phases:** P1, P2, P3, P4, P5, P5.5, P6, P7
**Effort:** 110h (~22 days full-time, ~8 weeks half-pace)
**Outcome:** Strategist is operational with deterministic RCA, cross-repo sweeps, wiki-driven mutations. FP rate down 40%, abort gate prevents 90% of waste. **Quality Ladder grades available but learning grade capped at C** (FeedbackConsolidator not yet built).

### Milestone B — `phronex-common v19.0 — Test Strategist Layer (Closed Loop)`
**Phases:** P8, P9 (3 skills), P10, P11, P12, P13, system gate
**Effort:** 118h (~24 days full-time, ~9 weeks half-pace)
**Outcome:** Full closed loop operational. Generated DocChain artefacts feed deterministic journey generation. FeedbackConsolidator writes back to engineering knowledge base. Portal panel surfaces grades. Path to GA via S1–S8 over 30 days.

**Why two milestones?** Milestone A delivers ~80% of the immediate QA value in less time. If priorities change after Milestone A, Milestone B can be deferred without leaving the system in a broken state.

---

## 6.bis Recommended phase compression — 13 phases → 3 phases + 1 interlude

> **Context:** §3 lists 13 individually-tracked phases (P1–P13) for granularity. After review, that's overhead-heavy for a single-engineer build. This section documents the recommended compression to **3 GSD phases + 1 content interlude + 1 optional spike** — same scope, fewer ceremony cycles.

### Why compress

Each `/gsd:plan-phase` → `/gsd:execute-phase` → `/gsd:verify-work` cycle costs ~1h of ceremony (planning prompt, plan-checker, executor spawn, verification gate). At 13 phases that's ~13h of pure ceremony before any code is written. Compressing to 3 cuts ~10h while keeping all the architectural milestones that actually matter.

The cost: less granular checkpointing inside a single phase. If Phase 2 goes off-rails at task 14, you'll only catch it at the phase-end verify gate, not at a P-boundary. That's an acceptable tradeoff for solo work where Vivek is reviewing commits anyway — but would be wrong for a multi-engineer team.

### The recommended structure

| GSD phase | Bundled P-numbers | Effort | Why these together |
|---|---|---|---|
| **Optional Block A spike** (`/gsd:quick`, not a full GSD phase) | P1 + P2 | 18h | Two independent waste-reduction wins. Ship as a `/gsd:quick` to validate the architecture's basic claims (abort gates fire, fixture guard catches FPs) before committing to Phase 1. **Defers the milestone start** until you have real data. |
| **Phase 1 — Strategist Core** | P3 + P4 + P5 | 40h (range 30–58h) | All three build the strategist's *brain*: state DB (P3) + RCA classifier (P4) + cross-repo sweep (P5). They share the new `qa_defect_rca` schema and the deterministic-first heuristics file. Splitting them creates artificial seams. |
| **P5.5 interlude** (`/gsd:quick`, **NOT bundled into Phase 2**) | P5.5 | 12h | Hand-author 5 TEST-ORACLES.html files. **Kept separate** because if it gets bundled with code work, it will be skipped — content tasks always lose to coding tasks when both share a phase. Forcing it as its own deliverable is the only way it gets done. |
| **Phase 2 — Strategist Brain** | P6 + P7 + P8 + P9 | 90h (range 70–128h) | The full closed-feedback layer: pre-run question machinery (P6) + WikiStore mutations (P7) + DocChain stage gates (P8) + 3 new DocChain skills (P9). All four mutate the WikiStore schema and the DocChain corpus together — splitting them would force re-running migrations and re-generating the corpus twice. |
| **Phase 3 — Closed Loop** | P10 + P11 + P12 + P13 + system gate | 70h (range 54–98h) | The audit, observation, consolidation, and visibility layers. Each consumes outputs from Phase 2 and writes back to engineering knowledge base. Bundled because the FeedbackConsolidator (P12) is the integration point for the other three — building them serially without shared context is wasteful. |
| **Total** | All 13 + system | **~230h** | Same as 13-phase version |

### Tradeoffs vs the 13-phase version

| Lost (13 → 3) | Gained (13 → 3) |
|---|---|
| Granular checkpoint visibility — can't say "P4 done, P5 next" cleanly | ~10–13h less ceremony |
| Course-correction at every P boundary (you can still abort mid-phase, just less cleanly) | Cohesive PRs — Phase 1 is one mergeable unit, not 5 |
| Easier to explain progress to a stakeholder ("we shipped P3 of 13") | Less context-switching between planning and execution |
| Easier to defer/reorder a single P | Subagent spawned by `/gsd:execute-phase` gets richer context — fewer hand-offs |
| Verify-work runs more often, catches drift earlier | Reviewer sees 3 large PRs instead of 13 small ones (preference dependent) |

### Why P5.5 stays separate (and not as a 4th phase)

P5.5 is content authoring (5 hand-written HTML files), not code. Three reasons to isolate it:
1. **Content tasks always lose to code tasks** when bundled. Without a separate forcing function it will be deferred indefinitely.
2. **Phase 2 (P6–P9) depends on P5.5's output** — the DocChain skills need real TEST-ORACLES examples to extract patterns from. P5.5 must complete before Phase 2 starts.
3. **`/gsd:quick` is the right tool for it** — no code, no migrations, no verification gate beyond "5 files exist and review well." A full phase ceremony would be overkill.

### Why optional Block A spike, not Phase 0

The Block A spike (P1 + P2 as `/gsd:quick`) is offered as **optional** because it's a hedge, not a dependency. Phase 1 can technically start without it. But:
- If you've never confirmed that abort gates actually fire correctly, you're committing 230h based on architectural belief.
- 18h to validate the assumption before the big commit is cheap insurance.
- If Block A reveals issues (e.g. cc-test-runner can't be aborted cleanly), the architecture needs revision before Phase 1, not after.

### Recommended kickoff sequence

```
Week 1   : Block A spike (18h)         → validate abort + fixture
Week 2   : decide go/no-go on full plan → adjust estimates from real data
Weeks 3–4: Phase 1 — Strategist Core (40h)
Week 5   : P5.5 interlude (12h)        → 5 hand-authored TEST-ORACLES
Weeks 6–9: Phase 2 — Strategist Brain (90h)
Weeks 10–12: Phase 3 — Closed Loop (70h)
```

At half-pace (5 productive hours/day, mixed with other work), this maps to ~22 calendar weeks instead of the ~17 weeks for raw 228h estimate — the extra 5 weeks accommodate review time between phases and one inevitable scope-discovery iteration.

### How this maps to milestone scoping

The 3-phase compression composes cleanly with §6's two-milestone view:

- **Milestone A (`v18.0 — Foundations`)** = optional Block A + Phase 1 + P5.5 interlude + part of Phase 2 (specifically P6 + P7) — ~110h
- **Milestone B (`v19.0 — Closed Loop`)** = remainder of Phase 2 (P8 + P9) + Phase 3 — ~118h

Or, if you prefer milestone boundaries to align with phase boundaries:
- **Milestone A** = Block A + Phase 1 + P5.5 — ~70h ("the strategist works")
- **Milestone B** = Phase 2 — ~90h ("the strategist learns")
- **Milestone C** = Phase 3 — ~70h ("the strategist teaches")

The second decomposition is cleaner conceptually. Recommended unless you specifically want to ship a v18.0 with closed-loop preview.

---

## 7. What I'd cut if forced to ship in 4 weeks instead of 9

If the calendar is the hard constraint, this is the **80/20** subset:

| Ship | Skip / Defer | Rationale |
|---|---|---|
| P1, P2 | — | Quick wins, eliminate 50% of waste |
| P3 (state DB only, skip baseline) | Baseline capture | Strategist can compute trends without baseline; baseline matters for "exponential" claim, not Day-1 utility |
| P4 (deterministic only, no LLM fallback) | LLM fallback, qa_proposed_heuristics | Hand-author 15 heuristics covering 90% of seen defects; LLM is polish |
| P5 (manual sweep on demand) | Cron automation, sweep_overflow | Run sweeps manually after each cycle; skip the cron + bounded queue logic |
| P6 (signal only, no mutations applied) | Hysteresis, mutation application | Strategist *reports* signal; humans apply changes manually |
| **Total cut effort:** ~80h saved | **Remaining:** ~50h = 4 weeks |

This 4-week scope ships a **read-only Strategist** that surfaces decisions but doesn't enforce them. Still a major upgrade over the current "blind run" state.

---

## 8. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| P9 (DocChain skills) takes 80h instead of 48h | MEDIUM | +30h | Hand-authored P5.5 baseline catches format issues early. Hard cap: if any single skill exceeds 24h, deliver hand-written artefacts and defer auto-generator. |
| RCA heuristics need 5+ tuning passes (P4 + P10) | MEDIUM | +12h | Tune based on real `qa_known_defects` data, not synthetic. Limit initial scope to 10 patterns. |
| Cycle-close gate (R1) reveals more edge cases | LOW | +6h | Comprehensive test cases authored in P3. Add cases as discovered without rebuilding. |
| `qa_wiki_articles` schema migration corrupts data | LOW | High | Backfill defaults conservative; alembic test on staging first; full DB backup before P7 migration |
| FeedbackConsolidator writes wrong data to CODING-PATTERNS.md | MEDIUM | High | Reversible writes (P12 task 4); write-rate guards (P12 task 3); first 4 weeks of P12 are READ_ONLY mode |
| cc-test-runner doesn't expose UX hooks needed for P11 | MEDIUM | +8h | Fall back to log parsing; defer richer UX signals to v19.1 |
| Vivek's calendar means real elapsed time > estimated | HIGH | +50% calendar | Acknowledged: half-pace (17 weeks instead of 9) is the realistic plan |

---

## 9. Pre-flight before starting P1

Before kicking off P1, the following should be true (15 minutes of work):

1. ✅ `STRATEGIST-ARCHITECTURE.md` reviewed and committed (already done)
2. ✅ `STRATEGIST-IMPLEMENTATION-PLAN.md` reviewed and committed (this document)
3. ⬜ `qa_known_defects` exported to JSON for heuristics seeding analysis (10 minutes — needed for P4 prep)
4. ⬜ Decide phase shape: 13 granular phases (§3) **or** 3-phase compression (§6.bis) — recommended: §6.bis
5. ⬜ Decide milestone scoping: 2-milestone (§6) or 3-milestone aligned with phases (§6.bis) — Vivek decision
6. ⬜ Confirm Block A approval: 18h commitment to ship P1 + P2 first as `/gsd:quick`, then re-evaluate
7. ⬜ Run `/gsd:new-milestone v18.0 — Test Strategist Layer (Foundations)` to formalise

---

## 10. Recommendation

**Ship Block A first (18h, ~half a week of focused work).** This:
- Eliminates ~50% of current QA waste with minimal risk
- Validates the architecture's basic premises (abort gates work, fixture guards prevent FPs)
- Gives concrete data to refine estimates for Block B onwards
- Leaves the door open to defer Blocks B–F if priorities shift

After Block A ships and runs for 2 QA cycles, we'll have real data on:
- How often abort gates fire (validates P1 design)
- How many journeys get dropped by fixture guard (validates P2 inventory completeness)
- What new defect classes emerge that weren't in the heuristics inventory (informs P4 effort)

Then commit to Milestone A (Block A already done + Blocks B + C) — total remaining ~92h, which at half-pace is ~6 weeks of mixed work.
