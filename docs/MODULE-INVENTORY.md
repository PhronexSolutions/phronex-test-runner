# Complete Module Inventory (90 modules, ~20,300 LOC)

All modules live in `phronex_common.testing.*` (package path: `$PHRONEX_CODE_ROOT/phronex-common/src/phronex_common/testing/`). The operator never calls these directly — `run-journeyhawk.sh` chains them.

## Core Pipeline Modules

| Module | Purpose | DB reads | DB writes |
|--------|---------|----------|-----------|
| `runner.py` | Master pipeline orchestrator (24 steps). Entry point for Block C intelligence pipeline | qa_known_defects, qa_evidence, qa_journeys | qa_known_defects, qa_evidence, qa_journeys, qa_wiki_articles, qa_patterns, qa_docchain_snapshots |
| `_qa_db.py` | DB connection helper — reads `PHRONEX_QA_DATABASE_URL_SYNC`, provides `clean_dsn()` | — | — |
| `isolation.py` | Production URL denylist guard. `assert_not_production(url)` hard-stops on prod hostnames | — | — |
| `cleanup.py` | `QACleanupRegistry` + `qa_cleanup_session` pytest fixture. Idempotent teardown | — | — |
| `gap_detector.py` | Classifies run outcomes as BROKEN/HALF_BUILT/HALF_SURFACED/DRIFT/FRICTION | — | — (returns GapFinding list) |
| `ethos_bridge.py` | 8-cell decision matrix: maps (severity x ethos_rule_action) to AUTO_FIX/ASK_HUMAN/ESCALATE | qa_ethos_rules | — |
| `ethos_seed.py` | Seeds 10 CEO ethos starter rules. Idempotent — only writes if table is empty | qa_ethos_rules | qa_ethos_rules |
| `run_filter.py` | Three-reason filter (A: broken+fix landed, B: docchain changed, C: new journey) | qa_known_defects, qa_journeys, qa_docchain_snapshots | — |
| `docchain.py` | SHA256 delta detection for `.docs/` artefacts. Determines FULL vs DELTA suite scope | qa_docchain_snapshots | qa_docchain_snapshots |
| `handoff.py` | Human-in-the-loop queue for mic/video/CAPTCHA steps. BATCH_CAP=5, 90s time budget | qa_handoff_queue | qa_handoff_queue |
| `qa_context_hook.py` | Injects QA findings into GSD planner prompts. `get_qa_context(product_slug)` | qa_wiki_articles, qa_patterns, qa_known_defects | — |

## PQIP (Phronex Quality Intelligence Pipeline) Modules

| Module | Purpose | DB reads | DB writes |
|--------|---------|----------|-----------|
| `readiness_scorer.py` | 10-dimension weighted composite score. SHIP>=0.85, DEMO>=0.70, DEVELOP>=0.50, else HOLD | qa_known_defects, qa_confidence_scores, qa_ux_signals, qa_journey_verdicts, qa_velocity_metrics, qa_feature_coverage, qa_propagation_alerts, qa_proposed_heuristics, qa_prevention_rules | qa_readiness_reports |
| `confidence_scorer.py` | Wilson confidence intervals per journey. STABLE>=0.80, BROKEN<=0.30, never-failed override | qa_journey_verdicts | qa_confidence_scores |
| `coverage_analyzer.py` | Parses USER-SPEC.html features, maps to journeys in qa_journey_verdicts | qa_journey_verdicts | qa_feature_coverage |
| `risk_scorer.py` | Maps `git diff` to journey P(break) via affected_file correlation | qa_defect_rca, qa_velocity_metrics | — (stdout) |
| `risk_mapper.py` | Computes per-area risk_multiplier from defect velocity, writes to metrics | qa_defect_rca | qa_velocity_metrics |
| `velocity_tracker.py` | Per-area defect velocity (30-day window), hotspot detection | qa_defect_rca | qa_velocity_metrics |
| `architecture_feedback.py` | Quarterly ROI analysis: defect patterns to architecture recommendations | qa_defect_rca, qa_prevention_rules, qa_velocity_metrics | — (stdout) |
| `invariant_runner.py` | YAML-defined data invariants (business rules). Also generates from TEST-ORACLES.html | Product DBs (read-only queries) | — (stdout/YAML) |
| `prevention_generator.py` | LLM-powered: synthesizes grep patterns from BROKEN defects, drafts prevention rules | qa_defect_rca | qa_prevention_rules |
| `rule_generator.py` | Deterministic: derives prevention rules from defect RCA rows (no LLM). Auto-promotes to `status='active'` when confidence >= 0.60 | qa_defect_rca | qa_prevention_rules |
| `propagation_engine.py` | Greps product repos for defect pattern_signature matches, raises propagation alerts | qa_defect_rca | qa_propagation_alerts |
| `visual_regression.py` | SSIM baseline comparison for screenshot evidence bundles | qa_evidence | qa_visual_baselines |
| `contract_runner.py` | Validates API contracts (YAML-defined) against live endpoints | contracts/ YAML | qa_contract_results |
| `contract_generator.py` | Auto-generates contract YAML from INTEGRATION-MAP.html | — | contracts/ YAML files |
| `api_test_runner.py` | Adversarial payload testing (XSS, SQLi, auth boundary) against product APIs | — | stdout |
| `depth_scorer.py` | Classifies journeys as SMOKE/SURFACE/DEEP/BEHAVIORAL from step text | — | — (returns scores) |
| `spec_generator.py` | LLM-powered: generates DEEP-scored draft journey specs for uncovered features | qa_feature_coverage | — (stdout JSON) |

## Strategist Sub-Package (`strategist/`)

| Module | Purpose | Pipeline block |
|--------|---------|----------------|
| `questions.py` | Q1-Q6 signal computation. Q5 depth_quality, Q6 docchain_freshness (both 0.0=ideal, 1.0=worst) | Block A |
| `recommender.py` | 6-signal strategy-state-weighted journey scoring. Weights: depth_quality 0.25, coverage_gap 0.20, yield_trend 0.15, ethos_priority 0.15, docchain_freshness 0.15, fixture_health 0.10 | Block A |
| `docchain_reader.py` | Parses 4 DocChain artifacts into `DocChainIntelligence` dataclass. Features include feat-* IDs with capability counts | Block A |
| `feedback_loop.py` | `assess_and_remediate()` — detects SMOKE/none coverage gaps, creates handoff entries for unresolvable gaps | Block A/C |
| `llm_assessor.py` | Budget-capped LLM quality assessment for SURFACE journeys. Max 10 calls/$0.50 per run. Adds Reason E to run filter | Block A |
| `mutations.py` | Reads `test_mutation` JSONB from qa_wiki_articles, applies ADD_STEP/ADD_JOURNEY/SKIP_JOURNEY/REQUIRE_FIXTURE/ABORT_ON/DEEPEN | Block A |
| `fixture_guard.py` | Pre-filters journeys whose fixtures are missing/expired before execution | Block A |
| `fixture_detectors.py` | Detector registry: authentication, file upload, payment, SSO fixture validators | Block A |
| `run_arbiter.py` | Wraps cc-test-runner process. Aborts on: 3 consecutive fails / >30 min / >50% network failures | Block B |
| `abort_reasons.py` | Structured abort reason dataclasses for RunArbiter abort events | Block B |
| `rca/engine.py` | Deterministic heuristics-first RCA classification. LLM fallback | Block C |
| `validation_auditor.py` | Reads TEST-ORACLES.html, emits PASS_ORACLE/FAIL_ORACLE/NO_ORACLE per journey | Block C |
| `ux_observer.py` | 6 fatigue metrics: duration, retry_rate, dwell_time, cycle_streak, fp_rate, approval_rate | Block C |
| `feedback_consolidator.py` | Writes to 5 sinks with rate guards. Spec-failure noise guard rejects exec error summaries (Phase 93) | Block C |
| `approved_heuristics.py` | Consumes approved `PROPOSED_INVARIANTS` — appends verification steps to matching journeys. Fail-open | Block A |
| `feedback.py` | FeedbackItem dataclass + sink routing logic | Block C |
| `_feedback_sinks.py` | Concrete sink implementations (CODING_PATTERNS, DOCCHAIN, PROPOSED_INVARIANTS, WIKISTORE, TEST_ORACLES) | Block C |
| `_feedback_rate_guards.py` | Per-sink cooldown windows to prevent feedback flooding | Block C |
| `_feedback_reversibility.py` | Tracks which feedback items can be reverted if contradicted | Block C |
| `cycle_gate.py` | CycleCloseGate: evaluates whether run met thresholds for cycle closure | Block C |
| `report.py` | Post-run strategist summary: aggregates all pipeline outputs into terminal display | Post-pipeline |
| `mode.py` | StrategistMode (DISABLED/READ_ONLY/ACTIVE). DB-backed, 30s poll, auto-degrade on failure | Control |
| `orchestrator.py` | `decision_gate()`: every strategist decision point checks mode before side effects | Control |
| `post_run.py` | Strategy state transitions: COLD_START to EXPAND to STEADY to OPTIMIZE | Control |
| `hysteresis.py` | Signal strength model: +0.10 on confirmation, -0.20 on contradiction, oscillation damper | Control |
| `ga_monitor.py` | System GA evaluation: 8 signals over 28-day window | Control |
| `slug_normaliser.py` | Normalises product slug variants (jp, jobportal, job-portal all map to jp) | Utility |

## Supporting Sub-Packages

| Package | Modules | Purpose |
|---------|---------|---------|
| `evidence/` | `bundle.py`, `collector.py`, `__init__.py` | SHA256-keyed evidence bundles (screenshots, DOM, step outcomes) |
| `defects/` | `models.py`, `protocols.py`, `postgres.py`, `__init__.py` | DefectVault protocol + PostgresDefectVault + EthosRuleRepository |
| `reporter/` | `html.py`, `jira_sink.py`, `comc_sink.py`, `__init__.py` | HTML report renderer, Jira ticket creation, ComC sink |
| `adapters/` | `base.py`, `cc.py`, `jp.py`, `portal.py`, `praxis.py`, `website.py`, `comc.py`, `_cleanup_http.py`, `__init__.py` | Per-product test adapters (base URLs, cleanup endpoints, resource manifests) |
| `journeys/` | `generator.py`, `spec.py`, `__init__.py` | JourneySpec/Step dataclasses + `from_userspec()` + `to_db_row()`/`from_db_row()` |
| `resources/` | `providers.py`, `seed.py`, `verify.py`, `__main__.py`, `__init__.py` | Test resource provisioning (accounts, fixtures, payment keys) |
| `cross_repo/` | `sweep.py`, `sweep_runner.py`, `__init__.py` | Cross-repo pattern sweeps (grep other product repos for same defect) |
| `payloads/` | `__init__.py` | Adversarial test payload generators (XSS, SQLi, format abuse) |
| `invariants/` | `__init__.py` + YAML files | Business rule invariant definitions |
