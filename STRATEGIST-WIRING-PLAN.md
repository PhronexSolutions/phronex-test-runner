# JourneyHawk Strategist Wiring Plan
> Created: 2026-07-17 after Sprint 1 CC run + code archaeology.
> Run this in a fresh parallel session. All components are BUILT — the work is WIRING + POLICY.

---

## What We Discovered (archaeology summary)

All major components exist in `phronex_common/testing/`. The gap is integration:

| Component | File | Status |
|-----------|------|--------|
| Journey merger (SUBTREE_GRAFT + PREFIX_MERGE) | `journey_merger.py` | Built, **NOT wired into post-run** |
| Multi-level DAG graph | `journey_graph.py` | Built, **partially wired** |
| Flat→branch tree restructurer | `tree_optimizer.py` | Built, **NOT called post-generation** |
| CrossRepoSweepOrchestrator | `cross_repo/sweep.py`, `sweep_runner.py` | Built, **NOT called in runner.py** |
| Spec cache + delta detection | `spec_persistence.py` | Built, **wired in generator but not always active** |
| Curator (PROMOTE+COLLAPSE+GRAPH_MERGE+EXTEND+RETIRE) | `spec_curator.py` | Built, **COLLAPSE runs on wrong scope (hits authored journeys)** |
| Step fingerprinter | `step_fingerprinter.py` | Built, used by journey_merger |
| LLM curator tasks | `llm_tasks/curator.py` | Built |

**Root cause of spec shrinkage**: `spec_curator.py` COLLAPSE runs on the FULL spec including authored base journeys. It should only COLLAPSE within the generated/enriched set. Authored journeys (source='spec') are canonical and must be protected.

**CrossRepoSweepOrchestrator**: Fully built with confidence floor (>=0.80), rate limit (max 5 per cycle), 30-day cooldown, Jira integration. Just needs wiring into `runner.py` post-RCA.

---

## Correct Data Flow (target state)

```
BASE SPEC (cc-deep.json)          ← authored canonical, NEVER modified by curator COLLAPSE
       │
       ▼
[Block A - Pre-run]
  spec_persistence.py             ← loads enriched cache if doc SHA unchanged
  journey_generator.py            ← generates NEW journeys for uncovered USER-SPEC sections
                                    (SKIP_GENERATION=0 when: COLD_START, EXPAND, FOCUS,
                                     DocChain delta, or 3 consecutive boring MAINTAIN runs)
  tree_optimizer.py               ← restructures flat generated journeys into branch trees
  journey_merger.py               ← SUBTREE_GRAFT + PREFIX_MERGE: merges generated with base
       │
       ▼
ENRICHED SPEC (cc-deep.enriched.json)   ← ephemeral, git-ignored, rebuilt each run
       │ phronex-test-runner uses this
       ▼
[Block B - Run]
[Block C - Post-run]
  confidence_scorer.py            ← Wilson intervals → STABLE/FLAKY/BROKEN
  spec_curator.py:
    PROMOTE:    STABLE generated journeys → written into cc-deep.json (canonical! additive!)
    COLLAPSE:   ONLY generated journeys (source != 'spec'), NEVER authored base
    GRAPH_MERGE: graft unique tails onto shared prefixes (enriched set only)
    EXTEND:     sub-feature journeys ≤4 steps merged as steps (enriched set only)
    RETIRE:     BROKEN ≥3 runs → retired_journeys.json
  cross_repo/sweep.py             ← defects with confidence>=0.80 sweep other products
  spec_persistence.py             ← save enriched spec as cache with SHA provenance
```

---

## SKIP_GENERATION Policy

**Question from user**: When should SKIP_GENERATION=0 run to keep going deeper/broader?

**Recommended policy** (implement in `strategist/mode.py`):

| Condition | Generation |
|-----------|-----------|
| COLD_START (first run or >30 days stale) | 0 — generate everything |
| MAINTAIN + ≥90% pass + no DocChain delta | 1 — regression only |
| EXPAND (DocChain changed OR <70% pass) | 0 — generate for changed sections |
| FOCUS (specific BROKEN journeys targeted) | 0 — generate targeted coverage |
| 3+ consecutive MAINTAIN runs, zero new defects | 0 — force breadth expansion |
| PROMOTE just ran (new journeys promoted) | 0 — next run discovers what they missed |

**Anti-boring-run rule**: After 3 consecutive MAINTAIN runs with zero new defects and zero new wiki articles, force SKIP_GENERATION=0 regardless of mode. The system should always be getting broader.

---

## Five Work Phases (ordered)

### Phase 1 — Curator Scope Fix (2-3h) ← DO THIS FIRST

**File**: `phronex-common/src/phronex_common/testing/spec_curator.py`

1. Read the full file. Find the COLLAPSE step.
2. Check: does it already filter by `source='spec'`? If not, add the guard.
3. Journey source tagging: authored=`source='spec'`, generated=`source='learned'|'narrative'|'ceo'`. The COLLAPSE guard: `if journey.get('_source') == 'spec': skip`.
4. Check: does PROMOTE correctly write to the base spec file path (not enriched)?
5. Write minimal test: authored journey must survive a curator run unchanged.

**GSD command**: `/gsd:quick` with brief: "Fix spec_curator.py COLLAPSE to never touch authored journeys (source='spec'). Find COLLAPSE step, add source guard, write one test."

### Phase 2 — Enriched Spec File Boundary (2-3h)

**Files**: `run-journeyhawk.sh`, `runner.py`, `spec_persistence.py`

1. Check if `run-journeyhawk.sh` already produces `*.enriched.json` (grep for "enriched").
2. If not: add logic — if `<spec_base>.enriched.json` exists with matching provenance SHA → use it; else build from base + generate.
3. Ensure `runner.py` calls curator with enriched spec path, NOT base spec path.
4. Add `*.enriched.json` to each product journey dir's `.gitignore`.
5. The spec-restore invariant (`git checkout HEAD -- cc-deep.json`) becomes unnecessary.

### Phase 3 — Wire Generator → TreeOptimizer → Merger (2-3h)

**Files**: `run-journeyhawk.sh` Block A, `journey_generator.py`, `tree_optimizer.py`, `journey_merger.py`

1. Read `journey_generator.py` — confirm it calls `spec_persistence.py` for delta detection.
2. In `run-journeyhawk.sh` Block A (after generation, JOURNEYHAWK_SKIP_GENERATION=0):
   ```bash
   python -m phronex_common.testing.tree_optimizer \
     --product "$PRODUCT" --spec "$ENRICHED_SPEC" --output "$ENRICHED_SPEC"
   python -m phronex_common.testing.journey_merger \
     --base "$BASE_SPEC" --generated "$ENRICHED_SPEC" --output "$ENRICHED_SPEC"
   ```
3. Implement SKIP_GENERATION policy in `strategist/mode.py` — `should_generate(mode, run_history) -> bool`.
4. Update `run-journeyhawk.sh` to call `should_generate()` instead of just reading the env var.

### Phase 4 — Wire CrossRepoSweep (2-3h) ← can parallel Phase 3

**Files**: `cross_repo/sweep.py`, `cross_repo/sweep_runner.py`, `runner.py`

1. Read both files. Check if `sweep_runner.py` has `--dry-run` flag.
2. In `runner.py`, after `FeedbackConsolidator`, call sweep_runner for defects with confidence >= 0.80.
3. Respect `PHRONEX_QA_JIRA_SINK_ENABLED` gate — dry-run first, then enable.
4. Verify: mock a high-confidence defect → sweep proposal appears in `qa_sweep_overflow` table.

### Phase 5 — Verification Sprint 2 (1-2h)

1. Merge CC PRs #16, #17 + portal PR #28 + deploy to EC2.
2. Run: `JOURNEYHAWK_SKIP_GENERATION=0 ./run-journeyhawk.sh contentcompanion cc-journeys/cc-deep.json`
3. Verify: new journeys generated, enriched spec created, curator promotes STABLE ones, COLLAPSE skips authored journeys, cross-repo sweep fires.
4. Expected: J03/J06/J07/J08 pass. J05 (analytics filters) and J09 (Razorpay) remain open gaps.

---

## Files to Read First (before any coding)

```bash
# 1. Curator scope — the key bug
cat phronex-common/src/phronex_common/testing/spec_curator.py

# 2. What runner.py calls post-run
grep -n "curator\|sweep\|enriched\|spec_persistence\|PROMOTE\|COLLAPSE" \
  phronex-common/src/phronex_common/testing/runner.py

# 3. Where run-journeyhawk.sh passes the spec and handles generation
grep -n "SKIP_GENERATION\|journey_generator\|tree_optimizer\|journey_merger\|enriched\|spec" \
  phronex-test-runner/run-journeyhawk.sh | head -50

# 4. CrossRepoSweep — what triggers it
cat phronex-common/src/phronex_common/testing/cross_repo/sweep_runner.py

# 5. How generated journeys are tagged (source field)
grep -n "source\|spec\|generated\|authored\|provenance" \
  phronex-common/src/phronex_common/testing/spec_persistence.py | head -30
```

---

## Success Criteria

- [ ] `cc-deep.json` never modified by curator COLLAPSE (PROMOTE is the only write)
- [ ] `cc-deep.enriched.json` created after each run (ephemeral, git-ignored)
- [ ] On next run: enriched spec loaded if doc SHA unchanged (no redundant LLM generation)
- [ ] STABLE generated journeys appear in `cc-deep.json` after promotion (additive-only)
- [ ] CrossRepoSweep fires for defects with confidence >= 0.80
- [ ] SKIP_GENERATION auto-determined by mode + run history, not manual env var
- [ ] After 3 boring reruns → forced SKIP_GENERATION=0 expands breadth

---

## Note on PARAMETRIC_FOLD

`journey_merger.py` has SUBTREE_GRAFT + PREFIX_MERGE but check for PARAMETRIC_FOLD (journeys identical except data values → folded into one parameterised journey). If absent, it's the one missing merge operation — add it in Phase 3 if needed. Check `step_fingerprinter.py` for whether it already handles parameter variance.
