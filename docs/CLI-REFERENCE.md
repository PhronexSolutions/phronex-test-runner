# CLI Reference (All Entry Points)

Every command below runs on DevServer only. All require `PHRONEX_QA_DATABASE_URL_SYNC` in environment (already set in `~/.qa.env`). All use raw psycopg2 (G5 invariant: zero ORM).

## Primary: Pipeline Wrapper (ALWAYS USE THIS)

```bash
./run-journeyhawk.sh <product-slug> <spec-file> [results-dir]
# Runs the complete 3-block pipeline. Never call sub-commands separately.
```

## Post-Run Verification (JourneyHawk must run after every pipeline execution)

```bash
# Strategist report (aggregates ALL pipeline data into single summary)
python -m phronex_common.testing.strategist.report --product jp --run-id jp-20260503_111302

# Readiness score (composite from 10 dimensions: target SHIP >= 0.85)
python -m phronex_common.testing.readiness_scorer --product jp

# Confidence scores (Wilson intervals per journey: shows STABLE/FLAKY/BROKEN/INSUFFICIENT)
python -m phronex_common.testing.confidence_scorer --product jp

# Coverage analysis (which USER-SPEC features have journey coverage)
python -m phronex_common.testing.coverage_analyzer --product jp --user-spec ~/code/jobportal/.docs/USER-SPEC.html

# Velocity metrics (defect hotspot tracking per code area)
python -m phronex_common.testing.velocity_tracker --product jp
```

## Diagnostic and Analysis (run ad-hoc when investigating)

```bash
# Risk scorer (which journeys are most likely to break given recent code changes)
python -m phronex_common.testing.risk_scorer --product jp --diff HEAD~1

# Architecture feedback (quarterly ROI report on systemic defect patterns)
python -m phronex_common.testing.architecture_feedback --product jp

# Invariant runner (validate business rules against live DB)
python -m phronex_common.testing.invariant_runner --product jp

# Invariant generator (extract invariants from TEST-ORACLES.html)
python -m phronex_common.testing.invariant_runner generate --product jp --oracles ~/code/jobportal/.docs/TEST-ORACLES.html

# Propagation engine (check if defect patterns exist in other product repos)
python -m phronex_common.testing.propagation_engine --product jp

# Prevention rule generator (LLM-powered: synthesizes grep patterns from defects)
python -m phronex_common.testing.prevention_generator --product jp

# Contract runner (validate API contracts)
python -m phronex_common.testing.contract_runner --product jp

# Contract generator (auto-generate contracts from INTEGRATION-MAP.html)
python -m phronex_common.testing.contract_generator --product jp --integration-map ~/code/jobportal/.docs/INTEGRATION-MAP.html

# API adversarial tester (XSS, SQLi, auth boundary probes)
python -m phronex_common.testing.api_test_runner --product jp --target http://43.204.79.39:8001
```

## Handoff Queue (human-in-the-loop management)

```bash
# Serve pending items (shows what needs human interaction)
python -m phronex_common.testing.handoff serve --run-id jp-20260503_111302

# Insert a handoff item (rarely called manually: pipeline inserts automatically)
python -m phronex_common.testing.handoff insert --run-id <id> --product-slug jp --journey-id jp-J10 --step-id 3
```

## Resource Management

```bash
# Verify test resources exist for a product
python -m phronex_common.testing.resources verify --product jp

# Seed test accounts (provision QA accounts in phronex-auth)
python -m phronex_common.testing.resources seed --product jp
```

## GSD Integration (called automatically by GSD planners)

```bash
# QA context hook (injected into planning prompts)
python -m phronex_common.testing.qa_context_hook jp
```
