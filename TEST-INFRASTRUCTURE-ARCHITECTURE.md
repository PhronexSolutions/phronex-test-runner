# Phronex Test Infrastructure — As-Built Architecture

> **Last updated:** 2026-05-04
> **Status:** Living document reflecting implemented code (not a spec — see `STRATEGIST-ARCHITECTURE.md` for the original design spec).
> **Scope:** Complete architecture of QA/testing infrastructure: `phronex-common/src/phronex_common/testing/` (89 Python files, 19,862 LOC) and `phronex-test-runner/` (shell orchestrator + cc-test-runner).
> **Milestones implemented:** v17.0 (QA Foundation), v18.0 (Test Strategist Layer), v19.0 (PQIP), v20.0 (PQIP Gap Closure)

---

## 1. System Overview

The Phronex QA system is a **learning-loop test infrastructure** that:
- Runs customer-journey browser tests via Claude Code agents (cc-test-runner + Playwright MCP)
- Classifies failures using deterministic heuristics (100% heuristic in production, zero LLM cost)
- Feeds findings back into the development engine (wiki articles, prevention rules, coding patterns)
- Measures product readiness across 10 weighted dimensions (SHIP/DEMO/DEVELOP/HOLD)
- Tracks journey reliability using Wilson confidence intervals (STABLE/FLAKY/BROKEN/INSUFFICIENT_DATA)

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           run-journeyhawk.sh (~740 lines)                    │
│                                                                             │
│  ┌─────────────────┐    ┌──────────────────┐    ┌────────────────────────┐ │
│  │   BLOCK A       │    │   BLOCK B        │    │      BLOCK C           │ │
│  │   Pre-Run       │───▶│   Execution      │───▶│  Intelligence Pipeline │ │
│  │   (Steps 0-1b)  │    │   (Step 1)       │    │  (Steps 2-4)           │ │
│  └─────────────────┘    └──────────────────┘    └────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
         │                        │                         │
         ▼                        ▼                         ▼
┌─────────────────┐   ┌───────────────────┐   ┌────────────────────────────┐
│ Stage gate      │   │ cc-test-runner    │   │ runner.py (1,456 LOC)      │
│ Resource verify │   │ (Claude agent +   │   │ ├── Evidence collector     │
│ Fixture guard   │   │  Playwright MCP)  │   │ ├── Gap detector           │
│ Depth scorer    │   │                   │   │ ├── RCA Engine (heuristic) │
│ Q1-Q4 signals   │   │ Wrapped by        │   │ ├── ValidationAuditor     │
│ Recommender     │   │ RunArbiter:       │   │ ├── UX Observer           │
│ Wiki mutations  │   │ • 3-fail abort    │   │ ├── FeedbackConsolidator  │
│                 │   │ • 30min timeout   │   │ ├── Readiness scorer      │
│                 │   │ • 5min/journey    │   │ ├── Confidence scorer     │
│                 │   │ • 50% net-fail    │   │ ├── Strategist report     │
│                 │   │                   │   │ └── CycleCloseGate        │
│                 │   │ Handoff queue     │   │                            │
│                 │   │ (PQIP §12)        │   │                            │
└─────────────────┘   └───────────────────┘   └────────────────────────────┘
                                                           │
                                                           ▼
                                              ┌────────────────────────────┐
                                              │     phronex_qa DB          │
                                              │  26+ tables, DevServer     │
                                              │  (192.168.1.250:5432)      │
                                              └────────────────────────────┘
```

---

## 2. Module Inventory (89 files, 19,862 LOC)

### 2.1 Core Orchestration

| Module | LOC | Purpose |
|--------|-----|---------|
| `runner.py` | 1,456 | Main intelligence pipeline. Reads CTRF → evidence → gaps → RCA → verdicts → learning |
| `run-journeyhawk.sh` | ~740 | Shell wrapper chaining Blocks A/B/C. Single entry point for all runs |

### 2.2 Strategist Sub-Package (`strategist/` — 22 files, ~4,490 LOC)

| Module | Purpose | Reads | Writes |
|--------|---------|-------|--------|
| `questions.py` | Q1-Q4 signal computation | qa_known_defects, qa_journey_verdicts, qa_wiki_articles, qa_confidence_scores | — |
| `recommender.py` | Journey priority scoring (4-signal weighted + human_required penalty) | qa_confidence_scores | — |
| `fixture_guard.py` | Pre-filters journeys with missing fixtures | qa_test_resources | fixture-decisions.json |
| `mutations.py` | Applies wiki test_mutation directives (ADD_STEP/SKIP_JOURNEY/etc) | qa_wiki_articles | mutated spec |
| `run_arbiter.py` | Wraps cc-test-runner, SIGTERMs on cascading failures | — | abort_reason.json |
| `rca/engine.py` | Root cause classification (heuristic-first, LLM fallback) | qa_known_defects | qa_defect_rca |
| `validation_auditor.py` | TEST-ORACLES.html → PASS/FAIL/NO_ORACLE verdicts | .docs/TEST-ORACLES.html | qa_journey_verdicts |
| `ux_observer.py` (515 LOC) | 6 UX fatigue metrics per run | qa_ux_signals | qa_ux_signals |
| `feedback_consolidator.py` | 5 sinks (CODING-PATTERNS, DOCCHAIN, INVARIANTS, WIKI, ORACLES) | qa_proposed_heuristics | qa_proposed_heuristics |
| `cycle_gate.py` | Quality gate for cycle closure emission | qa_journey_verdicts, qa_confidence_scores | qa_cycle_log |
| `mode.py` | Strategist mode (ACTIVE/READ_ONLY/DISABLED) + auto-degrade | qa_strategy_state | qa_strategy_state |
| `post_run.py` | Updates strategy state after run | — | qa_strategy_state |
| `report.py` | Post-run strategist summary (aggregates all signals) | all qa_* tables | stdout |
| `orchestrator.py` | High-level orchestration API | — | — |
| `hysteresis.py` | Prevents mode thrashing between states | qa_strategy_state | — |
| `ga_monitor.py` | Google Analytics real-user signal integration | — | — |
| `slug_normaliser.py` | Product slug normalization across conventions | — | — |
| `abort_reasons.py` | Abort reason enum definitions | — | — |
| `fixture_detectors.py` | Fixture detection heuristics | — | — |
| `feedback.py` | Feedback data models | — | — |
| `_feedback_rate_guards.py` | Rate limiting for feedback writes | — | — |
| `_feedback_reversibility.py` | Reversibility scoring for proposed changes | — | — |
| `_feedback_sinks.py` | Individual sink implementations | — | — |

### 2.3 PQIP Modules (Phases 85-88)

| Module | LOC | CLI | Purpose |
|--------|-----|-----|---------|
| `readiness_scorer.py` | 631 | `--product {slug}` | 10-dimension weighted composite (SHIP≥0.85) |
| `confidence_scorer.py` | 305 | `--product {slug}` | Wilson confidence intervals (STABLE/FLAKY/BROKEN) |
| `coverage_analyzer.py` | 591 | `--product {slug}` | USER-SPEC.html → journey coverage mapping |
| `risk_scorer.py` | — | `--product {slug} --diff HEAD~1` | P(break) from git diff |
| `architecture_feedback.py` | — | `--product {slug}` | Quarterly defect pattern → architecture ROI |
| `velocity_tracker.py` | — | — | Per-area defect velocity metrics |
| `visual_regression.py` | — | — | Screenshot comparison against baselines |
| `propagation_engine.py` | — | — | Cross-product defect pattern detection |
| `rule_generator.py` | — | — | Auto-generates prevention rules |
| `prevention_generator.py` | — | — | Prevention rule YAML from RCA patterns |

### 2.4 Foundation Modules (Phases 65-66, v17.0)

| Module | Purpose |
|--------|---------|
| `isolation.py` | Production URL denylist (`assert_not_production()`) |
| `cleanup.py` | QACleanupRegistry for test data teardown |
| `gap_detector.py` | BROKEN/HALF_BUILT/HALF_SURFACED/DRIFT/FRICTION classification |
| `ethos_bridge.py` | GapFinding → BridgeDecision (AUTO_FIX/ASK_HUMAN/ESCALATE) |
| `ethos_seed.py` | Seeds 10 starter governance rules |
| `docchain.py` | DocChain delta detection (SHA256 diff of .docs/*.html) |
| `depth_scorer.py` | Journey depth: SMOKE/SURFACE/DEEP/BEHAVIORAL |
| `handoff.py` (475 LOC) | Human-in-the-loop queue (mic, video, CAPTCHA, biometric) |
| `run_filter.py` | Three-reason filter (A: broken+fix, B: docchain, C: new) |
| `invariant_runner.py` | SQL data integrity invariants |
| `contract_runner.py` | Cross-service API contract verification |
| `contract_generator.py` | Contract YAML from INTEGRATION-MAP.html |
| `qa_context_hook.py` | Injects QA findings into GSD planner context |
| `spec_generator.py` | Journey spec generation from USER-SPEC.html |
| `journey_graph.py` | Topological ordering for tree-structured specs |
| `synthetic_customer.py` | Persona templates for multi-persona testing |
| `api_test_runner.py` | API-level (non-browser) test execution |
| `_qa_db.py` | `clean_dsn()` — connection URL normalization |
| `probe.py` | QA probe router (mounted in product backends) |
| `risk_mapper.py` | Maps files → journey IDs via defect history |

### 2.5 Sub-Packages

| Package | Files | Purpose |
|---------|-------|---------|
| `defects/` | 4 | KnownDefect models, DefectVault protocol, PostgresDefectVault + RCARepo + EthosRuleRepo + WikiStore + PatternStore |
| `evidence/` | 3 | EvidenceBundle (SHA256 content-addressed), collect() |
| `reporter/` | 4 | HTML report, Jira sink (PHX project), ComC sink |
| `adapters/` | 9 | ProductTestAdapter ABC + per-product impls (JP, CC, Portal, ComC, Praxis, Website) |
| `resources/` | 5 | Test resource provisioning, verification, manifest |
| `cross_repo/` | 3 | Cross-repository sweep runner |
| `journeys/` | 3 | JourneySpec, Step, from_userspec() |
| `invariants/` | — | YAML invariant definitions per product |
| `payloads/` | — | Test payload generators |

---

## 3. Database Schema (phronex_qa — 26+ tables)

**Host:** DevServer `192.168.1.250:5432` (NEVER EC2)
**User:** `phronex_qa`
**Migrations:** 26 Alembic versions (0001 → 0026)

### Core Tables

| Table | PK | Written By | Key Columns |
|-------|-----|-----------|-------------|
| `qa_known_defects` | defect_id (serial) | gap_detector | product_slug, title, severity, category, journey_name, fixed_at, is_false_positive |
| `qa_defect_rca` | defect_id FK | RCA engine | classified_by, root_cause, confidence, affected_file, pattern_signature |
| `qa_journey_verdicts` | (product_slug, journey_id, run_id) | ValidationAuditor | verdict (PASS_ORACLE/FAIL_ORACLE/NO_ORACLE/PENDING_HUMAN/EXPIRED_HUMAN) |
| `qa_confidence_scores` | (product_slug, journey_id) | confidence_scorer | total_runs, total_passes, confidence_lower, confidence_upper, classification, flaky_streak |
| `qa_evidence` | sha256 | evidence collector | product_slug, captured_at, artifacts_json |
| `qa_wiki_articles` | article_id (serial) | learning consolidation | concept, confidence, defect_class, prevention_rule, product_slugs, test_mutation (JSONB) |
| `qa_patterns` | pattern_id (serial) | pattern promoter | concept, occurrence_count, confidence, summary, products_seen |
| `qa_ethos_rules` | rule_id (UUID) | ethos_seed | category, action, threshold, rationale |
| `qa_journeys` | (product_slug, persona, journey_name) | runner.py | steps_json, source |

### PQIP Tables

| Table | PK | Written By |
|-------|-----|-----------|
| `qa_readiness_reports` | report_id (serial) | readiness_scorer |
| `qa_ux_signals` | signal_id (serial) | UX Observer |
| `qa_proposed_heuristics` | proposal_id (UUID) | FeedbackConsolidator |
| `qa_handoff_queue` | handoff_id (serial) | handoff.py |
| `qa_docchain_snapshots` | product_slug | runner.py finally |
| `qa_test_resources` | resource_id (serial) | resource verify |
| `qa_feature_coverage` | (product_slug, feature_id) | coverage_analyzer |

### Strategist Tables

| Table | PK | Written By |
|-------|-----|-----------|
| `qa_strategy_state` | product_slug | post_run.py |
| `qa_cycle_log` | log_id (serial) | CycleCloseGate |
| `qa_velocity_metrics` | (product_slug, area) | velocity_tracker |
| `qa_prevention_rules` | rule_id (serial) | rule_generator |
| `qa_propagation_alerts` | — | propagation_engine |
| `qa_data_invariant_results` | — | invariant_runner |
| `qa_contract_tests` | — | contract_runner |
| `qa_adversarial_results` | — | api_test_runner |

---

## 4. Pipeline Execution Flow

### 4.1 Block A — Pre-Run (Steps 0–1b)

```
0.  Load .qa.env → PHRONEX_QA_DATABASE_URL_SYNC, credentials, SDK keys
0a. PORTAL_URL substitution + credential injection (sed → TEMP_SPEC)
0.  Pre-run test data cleanup (curl → /admin/test-cleanup/)
0b. DocChain stage gate (verify .docs/ artefacts current)
0c. Resource verification (accounts, infra, credentials)
0d. Depth scorer (SMOKE/SURFACE/DEEP/BEHAVIORAL classification)
1a. Fixture guard (drop journeys with missing fixtures → FILTERED_SPEC)
1a2. Strategist signals (Q1-Q4) + JourneyRecommender.rank()
1b. Wiki mutations (ADD_STEP/SKIP_JOURNEY/etc → MUTATED_SPEC)
```

### 4.2 Block B — Execution (Step 1)

```
1.  RunArbiter spawns cc-test-runner --maxTurns 50
    └── Abort conditions: 3-consecutive-fail / 30min / 5min-per-journey / 50%-net-fail
    └── On abort: writes abort_reason.json
1b. Handoff queue poll (check qa_handoff_queue, wait max 600s for human steps)
```

### 4.3 Block C — Intelligence Pipeline (Steps 2–4)

```
2.  runner.py pipeline:
    ├── Seed ethos rules (first run only)
    ├── Load CTRF + step-outcomes overlay
    ├── Upsert journey registry → qa_journeys
    ├── Collect evidence → qa_evidence
    ├── Detect gaps → qa_known_defects
    │   └── RCA classify each → qa_defect_rca
    ├── Cross-product propagation check
    ├── Ethos bridge decisions
    │   └── PROPOSE_INVARIANT → qa_proposed_heuristics
    ├── Write wiki articles → qa_wiki_articles
    ├── Pattern promotion → qa_patterns
    ├── Phase 82 seam:
    │   ├── ValidationAuditor → qa_journey_verdicts
    │   ├── UX Observer → qa_ux_signals
    │   ├── FeedbackConsolidator → qa_proposed_heuristics
    │   ├── auto_degrade_check
    │   ├── update_strategy_state
    │   └── Invariant runner
    ├── PQIP extensions:
    │   ├── Feature coverage → qa_feature_coverage
    │   ├── Confidence scorer → qa_confidence_scores
    │   ├── Visual regression check
    │   ├── RCA backfill
    │   ├── Propagation scan
    │   ├── Velocity metrics → qa_velocity_metrics
    │   ├── Prevention rules → qa_prevention_rules
    │   └── Readiness score → qa_readiness_reports
    ├── Render QA-REPORT-{product}.html
    └── Store DocChain snapshot → qa_docchain_snapshots
3.  CycleCloseGate (GATE_PASS or GATE_HELD)
3b. Data invariant check (business-rule SQL assertions)
4.  Strategist report (aggregated summary of all signals)
```

---

## 5. Readiness Dimensions (10-dimension PQIP)

| # | Dimension | Weight | Data Source | Scoring |
|---|-----------|--------|-------------|---------|
| 1 | verification | 0.20 | qa_journey_verdicts | Pass rate (FLAKY-excluded) |
| 2 | validation | 0.15 | qa_feature_coverage | Journey-backed features / total features |
| 3 | data_integrity | 0.15 | qa_data_invariant_results | Invariant pass ratio |
| 4 | resilience | 0.10 | qa_adversarial_results | Adversarial test pass rate |
| 5 | cross_product | 0.10 | qa_propagation_alerts | Resolved alerts ratio |
| 6 | ux_quality | 0.10 | qa_ux_signals | Tier average (HEALTHY=1.0, WARNING=0.5, BACK_OFF=0.0) |
| 7 | predictive | 0.05 | qa_velocity_metrics | Inverse risk score |
| 8 | confidence | 0.05 | qa_confidence_scores | Wilson lower bound average |
| 9 | pre_deploy | 0.05 | qa_contract_tests | Contract pass rate |
| 10 | readability | 0.05 | qa_feature_coverage | Binary: feature coverage exists |

**Cold-start (D-02):** Excludes N/A dimensions, renormalizes weights across available only.
**Thresholds:** SHIP ≥ 0.85 | DEMO ≥ 0.70 | DEVELOP ≥ 0.50 | HOLD < 0.50

---

## 6. Key Design Decisions

### G5 Invariant — Zero ORM
All DB access uses raw `psycopg2`. No SQLAlchemy, no asyncpg. Ensures predictable connection lifecycle and zero import-time side effects.

### Fail-Open Architecture
Every post-run component wrapped in independent try/except. A failure in UX Observer never crashes the pipeline or prevents Confidence Scorer from running.

### Deterministic-First RCA
Heuristic classification hierarchy before LLM fallback. In production: 100% heuristic (45 classifications, zero LLM cost). Heuristics match on error patterns, file paths, defect category, and title keywords.

### Wilson Confidence Intervals
Statistically rigorous reliability scoring that accounts for sample size. Key thresholds: STABLE ≥ 0.80 lower bound, BROKEN ≤ 0.30. "Never-failed override" for small-sample conservatism correction.

### Learning Loop (Wiki → Mutations → Future Specs)
JP defect → wiki article with `test_mutation` JSONB → next CC run reads mutation → adds/skips steps. Cross-product intelligence compounds across runs.

### Human-in-the-Loop (PQIP §12)
Steps requiring sensory input queued (not skipped). Budget-capped at 90s operator time. Pipeline polls after cc-test-runner. Expired handoffs = failures in Wilson.

---

## 7. CLI Reference

| Command | Purpose |
|---------|---------|
| `./run-journeyhawk.sh <product> <spec> [results-dir]` | Full pipeline entry point |
| `python -m phronex_common.testing.runner --product {p} --results-dir {d} --spec-file {f}` | Intelligence pipeline only |
| `python -m phronex_common.testing.strategist.report --product {p} --run-id {id}` | Strategist summary report |
| `python -m phronex_common.testing.readiness_scorer --product {p}` | Readiness score (10 dimensions) |
| `python -m phronex_common.testing.confidence_scorer --product {p}` | Wilson confidence per journey |
| `python -m phronex_common.testing.risk_scorer --product {p} --diff HEAD~1` | P(break) from git diff |
| `python -m phronex_common.testing.architecture_feedback --product {p}` | Architecture ROI report |
| `python -m phronex_common.testing.coverage_analyzer --product {p}` | Feature coverage analysis |
| `python -m phronex_common.testing.invariant_runner --product {p}` | Data integrity invariants |
| `python -m phronex_common.testing.handoff serve` | Interactive operator UI for human steps |
| `python -m phronex_common.testing.handoff poll --run-id {id}` | Poll handoff queue |
| `python -m phronex_common.testing.resources verify --product {p}` | Verify test resources |
| `python -m phronex_common.testing.qa_context_hook {product_slug}` | GSD planner QA context |
| `python -m phronex_common.testing.strategist.mutations --spec {f} --product {p}` | Apply wiki mutations |
| `python -m phronex_common.testing.strategist.fixture_guard --spec {f}` | Fixture pre-filter |
| `python -m phronex_common.testing.contract_generator --product {p}` | Generate contracts from INTEGRATION-MAP |

---

## 8. Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PHRONEX_QA_DATABASE_URL_SYNC` | `.qa.env` | PostgreSQL connection to phronex_qa |
| `PHRONEX_CODE_ROOT` | `~/.phronex-machine.env` | Workspace root (resolves .docs/) |
| `PORTAL_URL` | `.qa.env` | Target portal URL (default: https://app.phronex.com) |
| `STRATEGIST_MODE_OVERRIDE` | `--strategist-mode` flag | Force ACTIVE/READ_ONLY/DISABLED |
| `JOURNEYHAWK_RUN_ID` | auto | `{product}-{timestamp}` correlation ID |
| `JOURNEYHAWK_PRODUCT` | auto | Product slug for current run |
| `JP_TEST_CLEANUP_SDK_KEY` | `.qa.env` | JP pre-run cleanup |
| `CC_TEST_CLEANUP_SDK_KEY` | `.qa.env` | CC pre-run cleanup |
| `PHRONEX_QA_JIRA_SINK_ENABLED` | `.qa.env` | Jira ticket creation |
| `PHRONEX_QA_JIRA_PROJECT` | `.qa.env` | Jira project key (PHX) |
| `PHRONEX_QA_PROBE_ENABLED` | product .env | QA probe router in backends |
| `PHRONEX_QA_ALLOWED_HOSTS` | `.qa.env` | Production denylist bypass |
| `PHRONEX_{PRODUCT}_DATABASE_URL` | product .env | Product DB for invariant runner |

---

## 9. Deployment Topology

```
DevServer (192.168.1.250)                     EC2 (43.204.79.39)
┌─────────────────────────────────┐          ┌──────────────────────────┐
│ phronex_qa DB (PostgreSQL)      │          │ Portal (3002)            │
│ phronex-test-runner/            │  ───▶    │ JP (8001), CC (8000)     │
│   run-journeyhawk.sh           │ browser  │ Auth (8002)              │
│   cli/cc-test-runner            │  tests   │ Praxis (8003)            │
│ phronex-common/.venv/           │          └──────────────────────────┘
│   testing/ (89 modules)         │
└─────────────────────────────────┘
```

All QA infra runs on DevServer only. EC2 hosts product code. QA never writes to product DBs.

---

## 10. Strategist Mode Lifecycle

```
COLD_START ──(first run)──▶ WARMING ──(3 clean runs)──▶ ACTIVE
                                                           │
                                              (auto-degrade on failures)
                                                           ▼
                                                      READ_ONLY
                                                           │
                                                  (manual reset)
                                                           ▼
                                                       DISABLED
```

---

## 11. Cross-Product Learning Flow

```
JP defect found → qa_known_defects → wiki article (test_mutation JSONB)
                                                    │
CC next run → mutations applier reads wiki ────────▶ ADD_STEP injected
                                                    │
Portal run → propagation engine ────────────────────▶ ⚠️ CROSS-PRODUCT alert
```

---

## 12. Post-Run Strategist Report (NEW — 2026-05-04)

After every run, `strategist/report.py` aggregates all intelligence pipeline outputs into a visible summary:

```
╔══════════════════════════════════════════════════════════════╗
║          STRATEGIST REPORT — POST-RUN SUMMARY              ║
╠══════════════════════════════════════════════════════════════╣
║  Product: jp                   Run: jp-20260504_091500     ║
╠══════════════════════════════════════════════════════════════╣
║  PRE-RUN SIGNALS (Q1-Q4):                                  ║
║    Q1 coverage_gap=0.300  Q2 yield_trend=0.000            ║
║    Q3 ethos_priority=0.250  Q4 fixture_health=0.700      ║
╠══════════════════════════════════════════════════════════════╣
║  READINESS: ✅ SHIP (composite=0.8700)                   ║
╠══════════════════════════════════════════════════════════════╣
║  CONFIDENCE SCORES (26 journeys):                        ║
║    STABLE=20  FLAKY=1  BROKEN=5  INSUFFICIENT=0          ║
╠══════════════════════════════════════════════════════════════╣
║  DEFECTS THIS RUN (12 total):                            ║
║    BROKEN=5  HALF_BUILT=3  DRIFT=2  FRICTION=2           ║
╠══════════════════════════════════════════════════════════════╣
║  RCA CLASSIFICATIONS (45):                               ║
║    heuristic=45  llm=0                                   ║
║    navigation-broken                      (12x)          ║
║    state-persistence                      (8x)           ║
║    enum-label-mismatch                    (6x)           ║
╠══════════════════════════════════════════════════════════════╣
║  LEARNING INFRASTRUCTURE:                                 ║
║    wiki_articles=92  patterns=15  proposals=3            ║
║    ux_metrics=6                                          ║
╠══════════════════════════════════════════════════════════════╣
║  CYCLE GATE: ✅ PASSED                                   ║
╚══════════════════════════════════════════════════════════════╝
```

---

*This document is the authoritative "as-built" reference. Update after every milestone that modifies the QA infrastructure.*
