# QA Database Schema Reference

All tables live in the `phronex_qa` database on DevServer (192.168.1.250:5432). Never on EC2.

## Core Tables

| Table | What it stores | Written by | Read by |
|-------|---------------|-----------|---------|
| `qa_known_defects` | Every defect found: title, severity, category, product_slug, journey_name, fixed_at, is_false_positive | `runner.py` gap detector | Session start query, regression anchor selection, cross-product propagation check |
| `qa_wiki_articles` | Cross-product lessons: concept, summary, confidence, defect_class, prevention_rule, product_slugs, test_mutation (JSONB for spec directives) | `runner.py` learning consolidation | `qa_context_hook.py`, mutations applier, strategist Q3 |
| `qa_patterns` | Promoted patterns (seen 2+): concept, occurrence_count, confidence, summary | `runner.py` learning consolidation | `qa_context_hook.py`, session start |
| `qa_evidence` | SHA256-keyed evidence bundles: screenshots, DOM traces, step outcomes per journey | `runner.py` evidence collector | HTML report renderer |
| `qa_ethos_rules` | Governance rules for auto-fix vs escalate decisions | `ethos_seed.seed_starter_rules()` (auto on first run) | `ethos_bridge.decide()` on every finding |
| `qa_docchain_snapshots` | Last seen SHA256 of each product's `.docs/*.html` artefacts | `runner.py` finally block (every run) | DocChain delta check (determines full vs delta suite scope) |
| `qa_journeys` | Journey spec archive: product_slug, persona, journey_name, steps_json, source | `runner.py` | Historical reporting |
| `qa_defect_rca` | Root cause classification per defect: classified_by (heuristic/llm), root_cause, confidence, affected_file, pattern_signature | `runner.py` RCA engine | architecture_feedback, risk_scorer |
| `qa_journey_verdicts` | Per-journey per-run verdict: PASS_ORACLE/FAIL_ORACLE/NO_ORACLE/PENDING_HUMAN/EXPIRED_HUMAN | `runner.py` ValidationAuditor | confidence_scorer (Wilson intervals) |
| `qa_confidence_scores` | Wilson confidence intervals: total_runs, passes, fails, lower/upper bound, classification (STABLE/FLAKY/BROKEN/INSUFFICIENT_DATA) | `confidence_scorer.py` | readiness_scorer dimension 5, run filter |
| `qa_ux_signals` | 6 UX fatigue metrics: journey_avg_duration, retry_rate, defect_dwell_time_p50, cycle_pass_streak, false_positive_rate, operator_approval_rate | `runner.py` UX Observer | readiness_scorer dimension 4 |
| `qa_proposed_heuristics` | Proposed invariants/coding-patterns from FeedbackConsolidator: sink, summary, diff, status (pending_apply/approved/rejected). Spec-failure noise filtered before INSERT (Phase 93 guard). | `runner.py` FeedbackConsolidator | Operator review, PQIP audit, `approved_heuristics.py` consumer |
| `qa_journey_depth_log` | Per-run depth classification audit trail: product_slug, journey_id, run_id, depth_classification (SMOKE/SURFACE/DEEP/BEHAVIORAL), action_taken (kept/dropped) | `run-journeyhawk.sh` Step 0d/3 | Depth quality analytics, strategist Q5 |
| `qa_readiness_reports` | 8-dimension composite readiness score per product per run. Composite ≥ 0.85 = SHIP | `readiness_scorer.py` | Post-run verification, portal QA dashboard |
| `qa_handoff_queue` | Human-in-the-loop step queue: run_id, journey_id, step_id, reason, instruction, status (pending/served/completed/skipped/expired) | `handoff.py` insert | pipeline Step 1b poll, operator CLI |
| `qa_strategist_llm_costs` | Per-run LLM call costs for the strategist's quality assessor: product_slug, run_id, model_id, input/output tokens, cost_usd, call_purpose. Budget cap: $0.50/run, max 10 calls | `llm_assessor.py` | Portal Strategist tab cost audit, budget reporting |
| `entity_memory.*` | Tester EntityBrain: `PastDecision` rows per tester (per-product memory, NOT cross-product) | `PostgresMemoryStore` | Tester context injection |

## EntityBrain vs WikiStore

**EntityBrain (`PostgresMemoryStore`):** Per-tester, per-product memory. Stores `PastDecision` rows — what JourneyHawk decided to do about a specific defect in a specific run. Scoped to one product. Use it to avoid re-proposing the same fix the operator already rejected.

**WikiStore (`PostgresWikiStore`):** Cross-product knowledge. Stores `WikiArticle` rows — generalised lessons with confidence scores. NOT scoped to one product. This is the mechanism that makes a JP finding visible in CC planning. Confidence grows with each confirmation across products.

**Key distinction:** EntityBrain remembers what decisions were made. WikiStore learns what truths have been established. Both live in `phronex_qa`.
