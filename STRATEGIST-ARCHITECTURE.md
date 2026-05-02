# JourneyHawk StrategistLayer — Consolidated Architecture

> **Source:** Multi-turn discussion with Vivek, 2026-05-01.
> **Inputs:** `Test Improvements.txt` (`/home/ouroborous/Ouroborous-inbox/`) + JourneyHawk session retrospective + Phronex_Internal_Product_DocChain skill scope.
> **Status:** Architecture spec (not yet implemented). Implementation order in §10.
> **Owner:** phronex-common (`phronex_common.testing.strategist` + adjacent modules) and Phronex_Internal_Product_DocChain child skills.

---

## 1. Why this exists — the gap statement

The current JourneyHawk pipeline is a **historian**: it records what happened (defects, FPs, runs, evidence) extremely well in `phronex_qa.*` tables. What it does not have is a **strategist** — a layer that reads that history and changes what the next run does. The result is a system that gets smarter in storage but stays dumb in behaviour.

Concretely, the v2.4 portal QA session demonstrated four specific failure modes that no amount of additional storage would fix:

1. **No abort logic** — when journey 3 hits a blocking infra failure, journeys 4–25 still run and all fail.
2. **No fixture awareness** — ComC/Praxis mutation journeys FP'd because the QA account had no test data; the system had no concept of "this journey requires preconditions that aren't met."
3. **Spec drift went undetected until runtime** — `?tab=billing-config` was wrong but nothing in the corpus told the spec writer the canonical value.
4. **One defect, one fix** — defect #86 (Auth.js `updateSession`) was fixed in portal but no sweep ran across other repos that also call `updateSession` patterns.

This spec describes the **closed-loop** version of the system: every artefact from every run feeds a store that the next run reads as **directives**, not just context, and feedback flows back into the engineering knowledge base (CODING-PATTERNS, DocChain skills, CLAUDE.md) so improvements compound.

---

## 2. The Quality Ladder — what "better" means

Every cycle is graded across **four dimensions**. Mixing them was the conceptual confusion in the previous design.

| Dimension | Question it answers | Owned by |
|---|---|---|
| **VERIFICATION** | Does the code do what it was written to do? | GapDetector (existing) |
| **VALIDATION** | Was the *right thing* built? Does it match USER-SPEC + ROADMAP-NARRATIVE? | ValidationAuditor (new) |
| **UX QUALITY** | Is the experience smooth? Where is friction? | UXObserver (new) |
| **SYSTEM LEARNING** | Are we getting smarter run over run? | FeedbackConsolidator (new) |

A run that finds zero defects but covers 32% of USER-SPEC is **VERIFICATION: A, VALIDATION: D**. The cycle assessment must surface both honestly.

---

## 3. DocChain Corpus — explicit stage mapping

`/Phronex_Internal_Product_DocChain` produces (or should produce) the corpus below. Each artefact has a defined role at a defined test-planning stage. The current "DocChain Gate" loads only USER-SPEC + ROADMAP + ARCHITECTURE; this is incomplete.

### 3.1 Corpus inventory (current + proposed)

```
DOCCHAIN CORPUS
├── USER-SPEC.html           ← Current  | What was promised to users
├── ROADMAP-NARRATIVE.html   ← Current  | Why things were built (CEO vision)
├── ARCHITECTURE.html        ← Current  | How the system is structured
├── REQUIREMENTS.html        ← Current  | What each phase committed to deliver
├── PLAN.html(s)             ← Current  | How each phase was implemented
├── VERIFICATION.html(s)     ← Current  | Whether each phase was verified
├── CONTEXT.html(s)          ← Current  | Decisions made during planning
├── RESEARCH.html(s)         ← Current  | Technical choices and tradeoffs
├── PATTERNS.html            ← Current  | Established coding patterns
├── MILESTONES/              ← Current  | Historical shipped versions
├── INTEGRATION-MAP.html     ← NEW      | Route registry, API contracts, integration boundaries
├── TEST-ORACLES.html        ← NEW      | How to verify correctness — preconditions, expected states, failure modes
└── QUALITY-STANDARDS.html   ← NEW      | Performance, UX, data integrity thresholds for this product
```

### 3.2 Stage → Document mapping (enforced gates)

| Test planning stage | Document(s) loaded | What it gives the tester | Failure mode if skipped |
|---|---|---|---|
| **Journey generation** | `USER-SPEC.html`, `ROADMAP-NARRATIVE.html`, `TEST-ORACLES.html` | Each USER-SPEC section / TEST-ORACLE entry → ≥1 journey | Tests "does code work" instead of "right thing built" |
| **Verification scope** | `REQUIREMENTS.html`, `PLAN.html(s)` | Cross-check: every PLAN task covered by ≥1 journey step | Coverage gaps in features that were planned but never tested |
| **Architecture-aware probing** | `ARCHITECTURE.html`, `INTEGRATION-MAP.html` | Where contract drift / proxy / auth boundaries live | Only happy paths tested; missing proxy + contract drift |
| **Defect classification** | `PATTERNS.html`, `CONTEXT.html(s)` | Pattern violation vs novel bug | Every defect treated as one-off; "family" signal lost |
| **Historical regression** | `MILESTONES/`, `VERIFICATION.html(s)` | Regression anchors — "was this working before?" | Run journeys without anchor; cannot distinguish regression from absent feature |
| **RCA propagation** | `ARCHITECTURE.html`, `INTEGRATION-MAP.html`, `RESEARCH.html(s)` | Who else touches the same pattern | Fix one 404, leave the same class elsewhere |

### 3.3 Enforcement

The current `PHASE 0 — DocChain Gate` in the JourneyHawk skill is replaced by **6 sub-gates**, one per stage above. Each sub-gate produces a **stage-specific context bundle**. If a required artefact for that stage is missing/empty/<5KB, the gate **HALTS** and invokes the corresponding DocChain child skill in **backward reconciliation mode** to produce or refresh the artefact.

Implementation: `phronex_common.testing.docchain.stage_gates.StageGateRunner` — runs the 6 gates in order, each emitting a `StageContextBundle` consumed by the matching downstream component (journey generator, verification mapper, RCA classifier, etc.).

### 3.4 DocChain child skills — required enhancements

These are **prescriptive feedback issues** to file against `Phronex_Internal_Product_DocChain` (one issue per child skill). Each is justified by a real failure observed in this session.

| Child skill | Current artefact gap | Required addition | Triggering defect |
|---|---|---|---|
| `docchain-user-spec` | Features as prose; no preconditions, expected states, or test priority | Per feature: `preconditions[]`, `success_criteria[]`, `failure_modes[]`, `test_priority` (P0–P3) | ComC/Praxis empty-state FPs |
| `docchain-architecture` | Component tree only; no canonical IDs, no contracts | New "Route & Tab Registry" section: tab IDs, route prefixes, API endpoint paths, slug constants — regenerated on routing-file change | `?tab=billing-config` FP |
| `docchain-test-oracles` *(NEW skill)* | n/a — does not exist | Produce `TEST-ORACLES.html`: per feature, the full test recipe (procedure + expected state + access prereqs + data prereqs + known failure modes) | All inferred-precondition FPs |
| `docchain-integration-map` *(NEW skill)* | n/a — does not exist | Produce `INTEGRATION-MAP.html`: proxy routes, API contracts, auth boundaries, failure boundaries per service edge | Missing cross-service contract probes |
| `docchain-quality-standards` *(NEW skill)* | n/a — does not exist | Produce `QUALITY-STANDARDS.html`: latency budgets, UX thresholds, data integrity invariants per product | UX signals collected but no thresholds to grade against |

---

## 4. WikiStore as the strategic brain (not a log)

`qa_wiki_articles` exists today as cross-product context. It is **read** at session start but never **applied** as directives. Four new fields turn it into an active strategy engine.

### 4.1 Schema additions to `qa_wiki_articles`

```python
@dataclass
class WikiArticle:
    # Existing fields ──────────────────────────────────────
    concept: str
    confidence: float
    defect_class: str
    prevention_rule: str
    product_slugs: list[str]
    is_contradicted: bool

    # NEW — these four make the article strategic ──────────
    test_mutation: WikiTestMutation | None
    rca_chain: list[str]                # symptom → cause → root cause
    breadth_scope: BreadthScope
    strategy_signal: StrategySignal
```

### 4.2 New types

```python
@dataclass
class WikiTestMutation:
    action: Literal['ADD_STEP', 'ADD_JOURNEY', 'SKIP_JOURNEY',
                    'REQUIRE_FIXTURE', 'ABORT_ON', 'DEEPEN',
                    'ADD_CROSS_PRODUCT_CHECK']
    target: str                  # journey ID, step description, or pattern signature
    rationale: str               # why this mutation was triggered
    source_defect_id: int        # defect that created this mutation
    confidence_threshold: float  # only apply if article.confidence >= this
    expires_after_runs: int      # auto-disable after N clean runs (prevents drift)

@dataclass
class BreadthScope:
    affected_repos: list[str]
    affected_patterns: list[str]
    affected_components: list[str]
    sweep_required: bool
    last_swept_at: datetime | None

@dataclass
class StrategySignal:
    signal: Literal['EXPAND', 'FOCUS', 'AVOID', 'REQUIRE', 'ABORT_ON', 'MAINTAIN']
    scope: str                   # which journeys/surfaces this applies to
    reason: str                  # human-readable
    expires_after_runs: int      # how many clean runs before signal expires
    raised_at_run_id: str        # for traceability
```

### 4.3 Application — when WikiArticles become behaviour

| Event | Component | Reads from WikiStore | Effect |
|---|---|---|---|
| Pre-run | `StrategistLayer.pre_run()` | All articles `confidence >= 0.60` AND `not is_contradicted` AND `not expired` | `test_mutation` directives applied to journey spec; `strategy_signal` informs run filter; `breadth_scope` queues sweeps |
| In-run | `RunArbiter.after_journey()` | Articles with `strategy_signal.signal == 'ABORT_ON'` matching current failure | Aborts run with structured reason |
| Post-run | `RCAEngine.classify()` | All articles in defect's class | Increments confidence (cap 0.95), updates `breadth_scope` with new affected repo |

---

## 5. RCA as a first-class citizen + Cross-Repo Sweep

### 5.1 The current chain

```
defect found → qa_known_defects row → ethos decision → fix or defer → done
```

### 5.2 The required chain

```
defect found
  → RCAEngine classifies → writes qa_defect_rca with pattern_signature
  → CrossRepoSweepOrchestrator runs grep/AST sweep across ALL_REPOS
  → SweepFindings written as RISK rows in qa_known_defects (other products)
  → WikiStore upserts article with breadth_scope + test_mutation
  → Next run for affected products picks up sweep verification journeys automatically
```

### 5.3 New table — `qa_defect_rca`

```sql
CREATE TABLE qa_defect_rca (
    rca_id            SERIAL PRIMARY KEY,
    defect_id         INT REFERENCES qa_known_defects(defect_id),

    -- Causal chain (3 levels — all NOT NULL to enforce real RCA, not summary)
    symptom           TEXT NOT NULL,
    cause             TEXT NOT NULL,
    root_cause        TEXT NOT NULL,

    -- Defect class — links to WikiStore via wiki_article_id
    defect_class      TEXT NOT NULL,
    wiki_article_id   INT REFERENCES qa_wiki_articles(article_id),

    -- Pattern fingerprint for sweeps
    pattern_signature TEXT NOT NULL,        -- e.g. 'HAND_CODED_TAB_ID'
    sweep_query       TEXT NOT NULL,        -- shell command or SQL the sweep runs

    -- Breadth scope
    affected_repos    TEXT[] NOT NULL,
    affected_files    TEXT[],

    -- Cross-product propagation outcome
    propagated_to     TEXT[],               -- product_slugs where sweep found instances
    sweep_run_at      TIMESTAMP,
    sweep_findings_count INT DEFAULT 0,

    -- Audit
    classified_by     TEXT NOT NULL,        -- 'gap_detector' | 'human' | 'llm_assisted'
    confidence        FLOAT NOT NULL,       -- RCA classifier confidence
    created_at        TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_rca_pattern ON qa_defect_rca(pattern_signature);
CREATE INDEX idx_rca_class   ON qa_defect_rca(defect_class);
```

### 5.4 RCAEngine — classification pipeline

The RCA classifier is **deterministic-first, LLM-fallback** to avoid burning budget on every defect:

1. **Deterministic match** against a small set of heuristics (regex/AST patterns) — covers the top ~20 defect classes (URL drift, missing-resilience, contract drift, fixture gap, RBAC leak, etc.).
2. If no deterministic class matches, **escalate to LLM** with the defect title + evidence + nearest 3 wiki articles by embedding similarity. LLM emits `(defect_class, root_cause, pattern_signature, sweep_query)`.
3. Result is written with `classified_by='gap_detector'` or `'llm_assisted'`. Human override is `'human'`.

### 5.5 CrossRepoSweepOrchestrator — bounded sweeps

To prevent one defect from filing dozens of low-quality RISK rows (write amplification), sweeps are **bounded**:

- **Sweep budget** per RCA: max 3 RISK rows filed per affected repo. Excess goes to `qa_sweep_overflow` for human review.
- **Sweep cooldown**: same `pattern_signature` cannot trigger another sweep for 30 days unless an article's confidence delta > 0.2.
- **Confidence-gated**: sweeps only run for RCAs with classifier confidence ≥ 0.7 OR human-confirmed.

### 5.6 Concrete worked example — the `billing-config` 404

```
Defect filed:    Portal /admin?tab=billing-config returns "Unknown tab"
RCA written:
  symptom:    Tab ID in journey spec doesn't match adminTabs.ts
  cause:      Spec hand-coded tab ID without reading source
  root_cause: Tab IDs have no exported constants — nothing forces specs to use canonical values
  pattern_signature: HAND_CODED_TAB_ID

Sweep query:
  grep -rn "?tab=" portal-journeys/ contentcompanion/tests/ jobportal/tests/ \
    | grep -v 'from .*adminTabs'

Sweep findings (capped at 3/repo):
  - phronex-test-runner/portal-journeys/portal-deep.json:42  (already known — fixed)
  - phronex-test-runner/jp-journeys/admin-flows.json:18      (NEW RISK)
  - contentcompanion/tests/e2e/admin.spec.ts:7              (NEW RISK)

Wiki article upserted:
  concept: "Hard-coded route/tab IDs drift from source constants"
  confidence: 0.85
  breadth_scope.affected_repos: [portal, jp, cc]
  test_mutation: ADD_STEP "Verify ?tab= value is in product's tab registry before navigating"
  strategy_signal: REQUIRE — applies to "any journey using URL parameters derived from source constants"
```

Next run for JP and CC automatically picks up the verification step. `gsd-audit-milestone` now also flags any new spec adding a hand-coded tab ID.

---

## 6. The StrategistLayer — closed-loop control

### 6.1 Component map

```
phronex_common.testing.strategist/
├── strategist.py           # StrategistLayer — orchestrator
├── pre_run.py              # 4 questions: yield trend, coverage, ethos, fixtures
├── arbiter.py              # RunArbiter — in-flight abort decisions
├── post_run.py             # Self-assessment writer (to DB, not files)
├── validation_auditor.py   # USER-SPEC vs run-results drift
├── ux_observer.py          # FRICTION / ONBOARDING_GAP / PERF signals
└── feedback_consolidator.py # Closes loop to CODING-PATTERNS, DocChain skills, CLAUDE.md
```

### 6.2 Pre-run assessment — the 4 questions

```python
class StrategistLayer:
    def pre_run(self, product_slug: str) -> StrategyDecision:
        # Q1 — yield trend
        trend = compute_defect_yield_trend(product_slug, last_n=5)
        signal = (
            'EXPAND'   if trend.clean_runs >= 3 else
            'FOCUS'    if trend.yield_pct > 0.30 else
            'MAINTAIN'
        )

        # Q2 — spec coverage (validation dimension)
        coverage = compute_spec_coverage(
            product_slug,
            user_spec=load_artefact('USER-SPEC.html'),
            test_oracles=load_artefact('TEST-ORACLES.html'),
            run_archive=load_run_archive(product_slug),
        )

        # Q3 — ethos priorities
        ethos = get_ethos_priorities(product_slug)

        # Q4 — fixture gaps (PRECONDITION GUARD — this alone eliminates 40% of FPs)
        fixture_gaps = verify_test_fixtures(
            product_slug,
            journeys_to_run=candidate_journeys,
            preconditions_source=load_artefact('TEST-ORACLES.html'),
        )

        return StrategyDecision(
            signal=signal,
            uncovered_spec_sections=coverage.gaps,
            priority_order=ethos,
            fixture_gaps=fixture_gaps,
            mutations=load_active_wiki_mutations(product_slug),
        )
```

### 6.3 In-run abort — RunArbiter

```python
class RunArbiter:
    def after_journey(self, result: JourneyResult, run_state: RunState) -> ArbiterDecision:
        if result.failure_type == 'AUTH_RATE_LIMIT':
            return ArbiterDecision.ABORT('Rate limit hit — restart phronex-auth and rerun')

        if run_state.consecutive_failures >= 3 and run_state.failure_pattern == 'INFRA':
            return ArbiterDecision.ABORT('3 consecutive infra failures — backend down')

        if result.failure_type == 'BLOCKING_BUG' and result.severity == 'critical':
            return ArbiterDecision.PAUSE_SURFACE(result.affected_surface)

        # Wiki-driven aborts
        for article in active_abort_articles(run_state.product_slug):
            if article.matches(result):
                return ArbiterDecision.ABORT(f'Wiki article {article.id} signals abort: {article.strategy_signal.reason}')

        return ArbiterDecision.CONTINUE
```

### 6.4 Post-run self-assessment — to DB, not file

`STRATEGY-ASSESSMENT.md` is **not** written. Everything in it becomes DB rows:

| Concept | Table | Reason |
|---|---|---|
| Yield trend + signal | `qa_strategy_state` | Read by next pre-run |
| Spec coverage gaps | `qa_wiki_articles` (`defect_class='COVERAGE_GAP'`) | Becomes test_mutation directives next run |
| Fixture gaps | `qa_fixture_requirements` | Pre-run filter input |
| UX observations | `qa_ux_signals` | Accumulates for monthly product review |
| Cycle grade | `qa_cycle_assessment` | Surfaced in portal Audit tab |

### 6.5 New tables required

```sql
CREATE TABLE qa_strategy_state (
    state_id                SERIAL PRIMARY KEY,
    product_slug            TEXT NOT NULL,
    run_id                  UUID NOT NULL,
    yield_pct               FLOAT NOT NULL,
    signal                  TEXT NOT NULL,         -- EXPAND/FOCUS/MAINTAIN/COLD_START
    consecutive_clean_runs  INT NOT NULL DEFAULT 0,
    consecutive_fp_runs     INT NOT NULL DEFAULT 0,
    dominant_fp_class       TEXT,
    cold_start              BOOLEAN NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_strategy_product_time ON qa_strategy_state(product_slug, created_at DESC);

CREATE TABLE qa_fixture_requirements (
    fixture_id    SERIAL PRIMARY KEY,
    product_slug  TEXT NOT NULL,
    journey_id    TEXT NOT NULL,
    fixture_type  TEXT NOT NULL,    -- TEST_DATA / QA_ACCOUNT_GRANT / BACKEND_HEALTH
    description   TEXT NOT NULL,
    status        TEXT NOT NULL,    -- MISSING / SEEDED / VERIFIED / EXPIRED
    seeded_at     TIMESTAMP,
    last_checked_at TIMESTAMP,
    UNIQUE (product_slug, journey_id, fixture_type)
);

CREATE TABLE qa_ux_signals (
    signal_id        SERIAL PRIMARY KEY,
    product_slug     TEXT NOT NULL,
    surface          TEXT NOT NULL,   -- URL or component
    observation_type TEXT NOT NULL,   -- FRICTION / ONBOARDING_GAP / PERF / MISSING_FEATURE
    description      TEXT NOT NULL,
    occurrence_count INT NOT NULL DEFAULT 1,
    confidence       FLOAT NOT NULL,
    threshold_source TEXT,            -- which QUALITY-STANDARDS.html threshold this violates
    first_seen_at    TIMESTAMP DEFAULT NOW(),
    last_seen_at     TIMESTAMP DEFAULT NOW(),
    UNIQUE (product_slug, surface, observation_type)
);

CREATE TABLE qa_cycle_assessment (
    cycle_id              SERIAL PRIMARY KEY,
    product_slug          TEXT NOT NULL,
    run_id                UUID NOT NULL,
    verification_grade    CHAR(2) NOT NULL,   -- A+ A A- B+ B B- C+ C C- D F
    validation_grade      CHAR(2) NOT NULL,
    ux_grade              CHAR(2) NOT NULL,
    learning_grade        CHAR(2) NOT NULL,
    overall_grade         CHAR(2) NOT NULL,
    previous_overall      CHAR(2),
    trend                 TEXT NOT NULL,      -- IMPROVING / STABLE / DEGRADING
    summary_md            TEXT NOT NULL,
    created_at            TIMESTAMP DEFAULT NOW()
);

CREATE TABLE qa_sweep_overflow (
    overflow_id     SERIAL PRIMARY KEY,
    rca_id          INT REFERENCES qa_defect_rca(rca_id),
    repo            TEXT NOT NULL,
    file_path       TEXT NOT NULL,
    line            INT,
    evidence        TEXT,
    created_at      TIMESTAMP DEFAULT NOW()
);
```

---

## 7. The FeedbackConsolidator — closing the outer loop

After **one complete run cycle** (run → defects found → RCA → fixes deployed → verify-run passes), the FeedbackConsolidator emits artefacts back into the engineering knowledge base. **This is the layer that makes improvements compound across runs and across products.**

### 7.1 Cycle definition

A "complete cycle" is unambiguous: from `qa_journeys` row written, through every defect in that run reaching `fixed_at IS NOT NULL` OR being re-classified as `WONTFIX`, plus a verify-run that passes. Only then does the consolidator fire — partial cycles don't produce noise.

### 7.2 Output destinations

| Destination | Path | What gets written | Consumer |
|---|---|---|---|
| Coding standards | `phronex-common/config/CODING-PATTERNS.md` | New rule + detection grep + cross-product scope | All engineers, all GSD subagents |
| DocChain feedback | `phronex-common/skills/Phronex_Internal_Product_DocChain/FEEDBACK.md` | Structured issue: which child skill, what gap, required improvement | DocChain maintainer (skill-builder pass) |
| Project CLAUDE.md | `<product>/CLAUDE.md` "Common Pitfalls" | Proposed addition with source defect link | Every session in that product |
| WikiStore | `qa_wiki_articles` | Article promoted to confidence ≥ 0.85 with full BreadthScope | Next StrategistLayer pre-run |
| TEST-ORACLES | Per-product `.docs/TEST-ORACLES.html` | New oracle entry for the verified-fixed feature | Next journey generation |

### 7.3 Write-rate guards (prevent noise)

- **CODING-PATTERNS.md** — max 1 addition per cycle per pattern_signature; duplicates merged.
- **CLAUDE.md proposals** — written to a `PROPOSED-INVARIANTS.md` queue, **not directly into CLAUDE.md**. A weekly human review promotes accepted ones. (Direct writes would balloon the file in months.)
- **DocChain FEEDBACK.md** — append-only log; SkillBuilder reviews queue when running `/Phronex_Builder_Dev_SkillBuilder` over DocChain skills.
- **WikiStore** — confidence promotion is bounded: +0.10 per fresh confirmation, capped at 0.95. Contradiction sets `is_contradicted=TRUE` and confidence is frozen.

### 7.4 Quality Ladder report

Every cycle, the consolidator writes a `qa_cycle_assessment` row with the four grades and an overall trend. The report is surfaced in the portal Audit tab under a new `TESTING_QUALITY` category — Vivek sees at a glance whether the test infrastructure is improving or stagnating.

---

## 8. The system loop — end to end

```
Run N completes
    ↓
GapDetector writes qa_known_defects
    ↓
RCAEngine classifies each defect → writes qa_defect_rca
    ↓
CrossRepoSweepOrchestrator runs sweeps for new RCAs (bounded) → RISK entries in other products
    ↓
WikiStore updater: confidence updates / new articles with test_mutations + breadth_scope
    ↓
StrategyState updated: yield%, signal, FP class analysis
    ↓
FixtureRequirements updated: gaps found this run
    ↓
ValidationAuditor: spec drift findings → COVERAGE_GAP wiki articles
    ↓
UXObserver: signals → qa_ux_signals
    ↓
*** WAIT for cycle close (all defects resolved + verify-run passes) ***
    ↓
FeedbackConsolidator:
  → CODING-PATTERNS.md
  → DocChain FEEDBACK.md
  → PROPOSED-INVARIANTS.md (queued for CLAUDE.md)
  → WikiStore promotion
  → TEST-ORACLES.html append
  → qa_cycle_assessment grade

--- time passes, fixes land ---

Run N+1 starts
    ↓
StageGateRunner: 6 sub-gates load DocChain corpus per stage
    ↓
Intelligence Load: WikiStore (confidence ≥ 0.6, not expired) → test_mutations as standing directives
                   StrategyState → signal (EXPAND/FOCUS/MAINTAIN/COLD_START)
                   FixtureRequirements → which journeys to skip
                   qa_defect_rca → which patterns to sweep for
    ↓
StrategistLayer.pre_run():
    - Apply test_mutations to journey specs
    - Generate spec-gap journeys from uncovered USER-SPEC sections
    - Apply fixture guard (drop doomed journeys)
    - Determine abort conditions from ethos rules + past FP patterns
    ↓
RunFilter builds the actual run set (already exists; now consumes Strategist output)
    ↓
RunArbiter monitors in-flight → aborts on infra failure / blocking bug / wiki abort signal
    ↓
Run executes
    ↓
(repeat)
```

---

## 9. Resolved design tensions

The original discussion glossed over five non-obvious tensions. Each is resolved here:

| Tension | Resolution |
|---|---|
| Who classifies defects into `defect_class`? LLM is expensive; deterministic is rigid. | **Deterministic-first, LLM-fallback** (§5.4). ~80% of defects match a known pattern; only the long tail hits LLM. Tracked via `classified_by` for cost monitoring. |
| Cross-repo sweeps could file hundreds of low-confidence RISK rows (write amplification). | **Bounded sweeps** (§5.5): max 3 RISK/repo per RCA, 30-day cooldown, confidence-gated, overflow goes to `qa_sweep_overflow` for review. |
| StrategistLayer cold-start: no `qa_strategy_state` history → no signal. | New signal value `COLD_START` (§6.5 schema). Pre-run defaults to `MAINTAIN` for first 3 runs while baseline yield is established. |
| WikiArticle confidence inflation — confidence creeps to 1.0 over time, articles never expire. | **Bounded promotion** (§7.3): +0.10 per confirmation, cap 0.95. **Mutation expiry** via `expires_after_runs` (§4.2). Contradicted articles freeze confidence and are excluded. |
| CLAUDE.md write amplification — every cycle adds invariants until the file is unreadable. | **Queue, don't auto-write** (§7.3): proposals land in `PROPOSED-INVARIANTS.md`; weekly human promotion. Maintains the global CLAUDE.md "≤200 line" discipline. |

---

## 10. Implementation order — phased rollout

Order chosen for **highest ROI per implementation week**, deferring the components with high engineering cost until cheaper wins compound:

| Phase | Week | Component | Why first |
|---|---|---|---|
| **P1** | 1 | `RunArbiter` (§6.3) — in-run abort gate | Single gate would have saved 10 doomed journeys in last extended run. ~1 day to ship. |
| **P2** | 1 | `qa_fixture_requirements` table + `preflight_fixtures.py` (§6.2 Q4) | Eliminates ~40% of current FPs. No DB migration risk — new table, no FK churn. |
| **P3** | 2 | Post-run self-assessment writes to DB (`qa_strategy_state`, `qa_cycle_assessment`) | Creates visible record; no behaviour change yet (read-only side effect). Builds the dataset the StrategistLayer will need. |
| **P4** | 3 | `RCAEngine` deterministic classifier + `qa_defect_rca` table | First-class RCA without LLM cost; defect history becomes searchable by pattern_signature. |
| **P5** | 3 | `CrossRepoSweepOrchestrator` (bounded) | Multiplier effect — one fix → N sweeps → cross-product RISK filings. |
| **P6** | 4 | `StrategistLayer.pre_run()` — full 4-question implementation | Now has data (P3) + RCA history (P4) to make meaningful EXPAND/FOCUS decisions. |
| **P7** | 4 | `WikiTestMutation` directives applied at journey-spec time | Behaviour-changing wiki: articles direct the next run. |
| **P8** | 5 | DocChain stage gates split (§3.3) | Need TEST-ORACLES from P9 to fully realise; can land scaffolding first. |
| **P9** | 6–7 | New DocChain child skills: `docchain-test-oracles`, `docchain-integration-map`, `docchain-quality-standards` | Largest engineering effort; deferred so prior phases can prove the architecture before investing here. |
| **P10** | 8 | `ValidationAuditor` (USER-SPEC drift detection) | Requires reliable TEST-ORACLES from P9. |
| **P11** | 8 | `UXObserver` + `qa_ux_signals` | Accumulates over time; only meaningful after several runs. |
| **P12** | 9 | `FeedbackConsolidator` end-to-end (CODING-PATTERNS, FEEDBACK.md, PROPOSED-INVARIANTS.md, TEST-ORACLES append) | Closes the outer loop; needs all prior pieces operational. |
| **P13** | 10 | Portal Audit tab `TESTING_QUALITY` category surfaces `qa_cycle_assessment` | Visible feedback to Vivek; builds trust in the system. |

Total: **~10 weeks** to full closed-loop. P1+P2 alone (week 1) eliminate ~50% of current waste.

---

## 11. Files & touchpoints — implementation map

| Where | What |
|---|---|
| `phronex-common/src/phronex_common/testing/strategist/` | All new strategist modules (§6.1 component map) |
| `phronex-common/src/phronex_common/testing/docchain/stage_gates.py` | StageGateRunner — replaces single DocChain Gate |
| `phronex-common/src/phronex_common/testing/rca/` | RCAEngine + CrossRepoSweepOrchestrator |
| `phronex-common/alembic/versions/` | Migrations for `qa_defect_rca`, `qa_strategy_state`, `qa_fixture_requirements`, `qa_ux_signals`, `qa_cycle_assessment`, `qa_sweep_overflow`; `qa_wiki_articles` ALTER for new fields |
| `phronex-common/skills/Phronex_Internal_Product_DocChain/FEEDBACK.md` | New file — append-only feedback queue |
| `phronex-common/skills/Phronex_Internal_Product_DocChain/children/docchain-test-oracles/` | New child skill |
| `phronex-common/skills/Phronex_Internal_Product_DocChain/children/docchain-integration-map/` | New child skill |
| `phronex-common/skills/Phronex_Internal_Product_DocChain/children/docchain-quality-standards/` | New child skill |
| `phronex-test-runner/runner.py` | Wire RunArbiter into run loop; wire FeedbackConsolidator at cycle close |
| `~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md` | Replace PHASE 0 monolithic gate with 6 staged sub-gates |
| `phronex-portal/src/app/(dashboard)/admin/AuditDashboardPanel.tsx` | New `TESTING_QUALITY` category surfacing `qa_cycle_assessment` |
| `phronex-common/config/CODING-PATTERNS.md` | Receives FeedbackConsolidator additions |
| `<each product>/PROPOSED-INVARIANTS.md` | New file — CLAUDE.md addition queue |

---

## 12. Success metrics — how we know it's working

After P1–P5 land (week 3):
- FP rate per run drops by **≥40%** (fixture guard + abort gate).
- Average wasted journey count per blocking-infra run drops from ~12 to **≤3**.

After P6–P9 land (week 7):
- USER-SPEC coverage per product (validation dimension) tracked in `qa_cycle_assessment`; baseline 50% → target **75%** by week 10.
- Cross-repo sweep findings produce **≥1 confirmed real defect per month** (validates the multiplier hypothesis).

After P10–P13 land (week 10):
- Cycle grade trend visible in portal Audit tab; consistent **`IMPROVING`** trend month-over-month is the system working.
- Engineer self-report: "I noticed the new pattern in CODING-PATTERNS.md before I introduced the bug" — anecdotal but the canonical evidence of compounding learning.

### 12.1 — The compounding curve (what each cycle should produce)

The "exponential improvement" claim is operationalised here. Each cycle should deliver measurably more than the previous, across four mechanisms:

| Cycle | What changes vs the previous cycle |
|---|---|
| **Run 1 → Run 2** | FP rate drops because fixture requirements from Run 1 are now `SEEDED`. New journeys cover USER-SPEC sections that were uncovered in Run 1. |
| **Run 2 → Run 3** | Wiki articles from Run 1 RCAs have directed cross-repo sweeps. Cross-repo defects surface in other products. CODING-PATTERNS.md addition prevents the same defect class from being introduced in new code. |
| **Run 3 → Run 5** | DocChain child skills have been improved based on FEEDBACK.md issues. TEST-ORACLES.html now exists per product, making journey generation deterministic instead of inferential. Tab-ID drift is impossible because ARCHITECTURE.html has the route registry. |
| **Run 5 → Run 10** | WikiStore has high-confidence articles across all products. StrategistLayer has enough yield-trend data to make EXPAND/FOCUS decisions accurately (cold-start exited). UX signals have accumulated enough to surface a genuine product improvement backlog reviewable monthly. |

**The exponential property:** each cycle improvement is permanent and cumulative. A CODING-PATTERNS.md addition prevents the defect class **forever**, not just in the next run. A DocChain skill improvement produces better artefacts for **every** future product and milestone, not just the one that triggered the feedback.

The system is not a better test runner — it is a **quality flywheel where each turn makes the next turn faster and more effective**. This is the load-bearing claim. If after Run 10 the slope of improvement is flat, something in the FeedbackConsolidator (§7) or WikiStore directives (§4.3) is broken — not the test infrastructure itself.

---

## 12.bis Definition of Done — what "shipped" means at every level

> §12 above lists **outcomes**. This section defines **completion** — when each phase, the system as a whole, and the architecture itself can be declared done. Without per-phase DoD, "we shipped P1" can mean anything from "code exists in the repo" to "wired, tested, observable, rollback-able, documented." We pin it down here.

### 12.bis.1 — Universal DoD checklist (applies to EVERY phase P1–P13)

Every phase, regardless of size, must satisfy ALL of the following before being marked complete in `qa_journeys` / git history. No exceptions, no "we'll come back to it":

| # | Criterion | How to verify |
|---|---|---|
| **U1** | **Code lands in `main`** with conventional-commit message tagging the phase ID | `git log --grep="P{N}:" --oneline` returns the merge commit |
| **U2** | **Migration applied** on DevServer + EC2 phronex_qa DB; `alembic heads` returns 1 line | `alembic current` on both hosts shows the new revision |
| **U3** | **Unit tests** with ≥80% line coverage for new modules; **integration test** that exercises the wiring through `phronex_qa` | `pytest --cov=phronex_common.testing.{module}` reports ≥80% |
| **U4** | **Kill-switch documented and tested** — every new component respects `STRATEGIST_MODE={ACTIVE,READ_ONLY,DISABLED}` (R15). A test asserts `READ_ONLY` mode does not write to any table. | Test `test_strategist_mode_read_only.py` passes |
| **U5** | **Observability hook in place** — every new component logs structured events to `qa_strategist_events` table (event_type, phase_id, payload_jsonb). The portal `TESTING_QUALITY` panel can render the events. | `SELECT COUNT(*) FROM qa_strategist_events WHERE phase_id='P{N}'` > 0 after first run |
| **U6** | **Rollback procedure** documented in `phronex-test-runner/STRATEGIST-RUNBOOK.md` — how to disable this specific phase without disabling the whole strategist | Runbook section exists and was dry-run-tested |
| **U7** | **JOURNEYHAWK-LEARNINGS.md updated** with the new behaviour — operators reading the file know what changed | `git diff JOURNEYHAWK-LEARNINGS.md` shows additions in the phase's commit range |
| **U8** | **DoD self-check** — phase author runs `python phronex-common/scripts/strategist_dod_check.py P{N}` which validates U1–U7 mechanically. Exit 0 = pass. | Script returns 0 with all checks green |

If U8 ever returns non-zero, the phase is **NOT DONE**, no matter what `git log` says.

### 12.bis.2 — Per-phase DoD (specific acceptance criteria)

Each phase has DoD on top of U1–U8. These are the *contract* — the phase has shipped when these are demonstrably true, not when the code merges.

#### P1 — RunArbiter (Week 1)
1. ✅ `runner.py` calls `RunArbiter.after_journey()` after every journey result; decision is logged
2. ✅ Three abort conditions wired and unit-tested: `AUTH_RATE_LIMIT`, `3-consecutive-INFRA-failures`, `BLOCKING_BUG-critical`
3. ✅ Wiki-driven aborts work: a test article with `strategy_signal=ABORT_ON` triggers abort
4. ✅ Abort produces a `qa_journeys.abort_reason` row, not silent termination
5. ✅ Re-running the same suite after fixing the abort condition completes without re-tripping
6. ✅ **Acceptance demo**: induce a deliberate auth rate-limit on staging, confirm run aborts at journey 4, not journey 25

#### P2 — Fixture Guard (Week 1)
1. ✅ `qa_fixture_requirements` table populated with seed data for known fixture-needing journeys (ComC pipeline, Praxis people, etc.)
2. ✅ `preflight_fixtures.py` runs before each run and DROPS journeys with `status=MISSING` from the run set
3. ✅ Dropped journeys are reported with reason ("test data missing for ComC pipeline") in the run summary
4. ✅ Fixture provenance fields populated (R5): `seeded_by`, `seed_command`, `expires_at`
5. ✅ Nightly cron `reseed_expired_fixtures.sh` exists and is in `crontab -l`
6. ✅ **Acceptance demo**: run extended portal suite — the 4 known-doomed ComC/Praxis journeys are skipped with explicit messages, not run-and-failed

#### P3 — Self-Assessment to DB + Baseline (Week 2)
1. ✅ Every run writes a `qa_strategy_state` row (yield, signal=COLD_START initially, consecutive counts)
2. ✅ Every run writes a `qa_cycle_assessment` row with all 4 grades + overall + trend
3. ✅ `qa_baseline_run` row written ONCE for each product (per R14 / §14.4) — the FP rate, defect yield, USER-SPEC coverage at week 2
4. ✅ Grades calibrated against versioned `qa_grade_rubrics` table (R10) — `rubric_version='v1'`
5. ✅ Cycle-close gate (R1) implemented: `cycle_closed_at` only set when verify-run passes first-attempt OR twice OR ethos-approved
6. ✅ **Acceptance demo**: trigger a flaky verify-run (passes 3-of-5) — cycle stays open; trigger a clean first-attempt pass — cycle closes

#### P4 — RCAEngine + qa_defect_rca (Week 3)
1. ✅ Heuristics live in `phronex_common/testing/rca/heuristics.yaml` (R7), not Python
2. ✅ Deterministic classifier covers ≥10 defect classes seen in last 90 days of `qa_known_defects`
3. ✅ LLM fallback writes proposed heuristics to `qa_proposed_heuristics` (R7)
4. ✅ LLM cost cap enforced via `RCA_LLM_BUDGET_USD` env (default $2/day); exceeded → `defect_class='UNCLASSIFIED_BUDGET_HIT'`
5. ✅ `pattern_signature` is a structured tuple `(layer, antipattern, evidence_hash_prefix)` (R2)
6. ✅ Backfill script `backfill_rca_history.py` exists, opt-in, scoped to last 90 days
7. ✅ **Acceptance demo**: file 5 different defect classes manually, all classified; one new class triggers LLM; LLM proposal lands in `qa_proposed_heuristics`

#### P5 — CrossRepoSweepOrchestrator (Week 3)
1. ✅ Sweeps run on cron 02:00 IST DevServer (R6), NEVER inline at run-time
2. ✅ Bounded sweep budget enforced: max 3 RISK rows/repo per RCA (R11)
3. ✅ Excess findings land in `qa_sweep_overflow` with `BREADTH_HIGH` summary
4. ✅ Sweep cooldown: same `pattern_signature` cannot re-sweep within 30 days unless confidence delta > 0.2
5. ✅ Sweep emits a `qa_strategist_events` row per sweep run (count of matches, repos scanned, time taken)
6. ✅ **Acceptance demo**: file the `billing-config` RCA from §5.6, observe sweep finds the JP + CC instances overnight, RISK rows appear in `qa_known_defects`

#### P5.5 — Hand-authored TEST-ORACLES.html for portal (Week 4) [inserted per §14.4]
1. ✅ `phronex-portal/.docs/TEST-ORACLES.html` exists with ≥10 hand-written oracle entries
2. ✅ Format proven by generating ≥3 journeys directly from the oracles (manual conversion)
3. ✅ Lessons captured as requirements in `phronex-common/skills/Phronex_Internal_Product_DocChain/children/docchain-test-oracles/REQUIREMENTS.md` for the future auto-generator
4. ✅ **Acceptance demo**: a 4th journey is generated from an oracle by a different person — format is unambiguous enough to follow

#### P6 — StrategistLayer.pre_run() (Week 4)
1. ✅ All 4 questions (yield trend, coverage, ethos, fixtures) implemented and reading from real DB tables
2. ✅ Signal hysteresis (R4) — flip requires 2 consecutive runs of opposing condition
3. ✅ Cold-start exit criterion (R12) — exits at 3 runs OR 30 days, whichever first
4. ✅ Strategist emits `StrategyDecision` JSON; `runner.py` consumes it as the run filter input (replacing existing `RunFilter`)
5. ✅ Console output shows what mutations were applied, what journeys were dropped, what was added — operator can audit
6. ✅ **Acceptance demo**: run portal twice in a row clean; observe signal flips MAINTAIN→EXPAND on run 3, with explanatory log lines

#### P7 — WikiTestMutation directives (Week 4)
1. ✅ `qa_wiki_articles` ALTER landed: 4 new fields (`test_mutation`, `rca_chain`, `breadth_scope`, `strategy_signal`) as JSONB
2. ✅ Contradiction is `contradicted_in: TEXT[]` not bool (R3)
3. ✅ Confidence promotion bounded (+0.10 per confirmation, cap 0.95)
4. ✅ Mutation expiry (`expires_after_runs`) auto-disables stale directives
5. ✅ Pre-run reads active mutations and applies them to journey specs in-memory before passing to runner
6. ✅ **Acceptance demo**: file the `HAND_CODED_TAB_ID` article with `ADD_STEP` mutation, run portal — every admin journey now has the verification step prepended

#### P8 — DocChain stage gates split (Week 5)
1. ✅ `StageGateRunner` exists with all 6 stages (journey gen, verification scope, architecture probe, defect class, regression, RCA propagation)
2. ✅ Each stage halts cleanly if its required artefact is missing — invokes the matching child skill
3. ✅ Bootstrap mode (R9) handles cold-start: produces STUB.html with `confidence=LOW`, run continues with `BOOTSTRAP` signal
4. ✅ Existing PHASE 0 in `Phronex_Internal_QA_JourneyHawk/SKILL.md` deleted; new staged version in place
5. ✅ **Acceptance demo**: rename `phronex-portal/.docs/USER-SPEC.html` temporarily — gate halts and invokes DocChain backward-reconciliation; restore it — gate proceeds

#### P9 — New DocChain child skills (Week 6–7)
1. ✅ `docchain-test-oracles` produces `TEST-ORACLES.html` matching the format proven in P5.5
2. ✅ `docchain-integration-map` produces `INTEGRATION-MAP.html` with route registry, API contracts, integration boundaries
3. ✅ `docchain-quality-standards` produces `QUALITY-STANDARDS.html` with thresholds (latency, UX, data integrity)
4. ✅ All 3 skills run successfully against ≥4 products (portal, JP, CC, praxis) without manual intervention
5. ✅ Generated artefacts are diff-checked against the hand-authored P5.5 baseline — drift is ≤20% on schema fields (the generator is not regressing the format)
6. ✅ **Acceptance demo**: run all 3 skills against ComC; produce all 3 HTML files; JourneyHawk consumes them in next ComC run

#### P10 — ValidationAuditor (Week 8)
1. ✅ Compares USER-SPEC sections against `qa_journeys` + `qa_known_defects` to compute coverage
2. ✅ Detects three drift types: UNCOVERED, BUILT_BUT_EMPTY, DRIFT
3. ✅ Writes findings as `qa_wiki_articles` with `defect_class='COVERAGE_GAP'` (becomes mutations next run)
4. ✅ `qa_cycle_assessment.validation_grade` calibrated against rubric
5. ✅ **Acceptance demo**: deliberately add a USER-SPEC section with no journey — auditor flags it within one cycle

#### P11 — UXObserver + qa_ux_signals (Week 8)
1. ✅ Per-step observation hooks in cc-test-runner emit FRICTION / ONBOARDING_GAP / PERF / MISSING_FEATURE signals
2. ✅ Per-run cap of 20 NEW signals (R13); excess deduped via fuzzy match → increments `occurrence_count`
3. ✅ Signals reference `QUALITY-STANDARDS.html` thresholds in `threshold_source` field
4. ✅ Monthly review query exists: `SELECT * FROM qa_ux_signals WHERE last_seen_at > NOW() - INTERVAL '30 days' ORDER BY occurrence_count DESC, confidence DESC LIMIT 20`
5. ✅ **Acceptance demo**: run portal — at least 1 PERF signal logged for any page > 2s load

#### P12 — FeedbackConsolidator end-to-end (Week 9)
1. ✅ Triggered ONLY after `cycle_closed_at` set (R1)
2. ✅ Writes to all 5 destinations (CODING-PATTERNS.md, DocChain FEEDBACK.md, PROPOSED-INVARIANTS.md, WikiStore promotion, TEST-ORACLES.html append)
3. ✅ Write-rate guards enforced (1 per cycle per pattern; queue not direct CLAUDE.md writes)
4. ✅ `gsd-housekeeping` Tier 2 weekly check (R8) blocks if PROPOSED-INVARIANTS.md has > 10 unresolved entries > 14 days old
5. ✅ Every write is reversible via `feedback_consolidator_undo.py CYCLE_ID`
6. ✅ **Acceptance demo**: close one cycle with 2 fixed defects of known classes — observe one CODING-PATTERNS.md addition + 1 PROPOSED-INVARIANTS.md entry + 2 WikiStore confidence bumps

#### P13 — Portal TESTING_QUALITY panel (Week 10)
1. ✅ New `TESTING_QUALITY` category in `AuditDashboardPanel.tsx`
2. ✅ Renders: latest cycle grade per product (4 dimensions + overall), trend arrow, days since last cycle close, `STRATEGIST_MODE`, RCA classifier hit-rate, top 5 active wiki mutations, PROPOSED-INVARIANTS.md queue depth
3. ✅ Links to evidence bundles (screenshots, DOM traces) for the latest run per product
4. ✅ Vivek can read the panel and within 30 seconds answer: "is my testing improving or stagnating?"
5. ✅ **Acceptance demo**: with all 7 products having ≥1 cycle assessment, panel renders without errors and grades match `qa_cycle_assessment` table

### 12.bis.3 — System-level acceptance gate ("StrategistLayer is DONE")

The architecture itself is "done" only when ALL of the following hold simultaneously for **30 consecutive days**:

| # | Gate | Measurement |
|---|---|---|
| **S1** | Every product (7 of them) has had ≥3 closed cycles in the period | `SELECT product_slug, COUNT(*) FROM qa_cycle_assessment WHERE created_at > NOW() - 30 days GROUP BY product_slug HAVING COUNT(*) >= 3` returns 7 rows |
| **S2** | Cycle assessment trend is `IMPROVING` or `STABLE` for ≥5 of 7 products | `qa_cycle_assessment.trend` distribution |
| **S3** | Zero `STRATEGIST_MODE=DISABLED` events in the period | `qa_strategist_events WHERE event_type='STRATEGIST_DISABLED'` empty |
| **S4** | RCA classifier hit-rate ≥80% deterministic, ≤15% LLM, ≤5% UNCLASSIFIED | computed over all RCAs in period |
| **S5** | Cross-repo sweeps have produced ≥3 confirmed real defects (not all FPs) | `qa_known_defects` rows with `source='cross_repo_sweep'` AND `severity != 'WONTFIX'` |
| **S6** | `PROPOSED-INVARIANTS.md` queue across all products has been triaged at least twice (no entry > 14 days old) | manual check + housekeeping log |
| **S7** | At least 1 CODING-PATTERNS.md addition has been credited as preventing a bug in code review (anecdotal but real) | engineer self-report logged in `qa_learning_credits` |
| **S8** | Baseline comparison: current cycle FP rate is ≥40% lower than `qa_baseline_run.fp_rate` for portal (the most active product) | computed delta |

When all 8 hold for 30 days, the architecture is declared **GA** in `qa_strategist_events` with `event_type='SYSTEM_GA'`. Until then it remains in `BETA` regardless of how many phases have shipped.

### 12.bis.4 — What "implemented as per the vision" means in one sentence

> **Every defect found in any product makes the next test run for *every* product measurably more likely to find related defects, and that improvement is visible to Vivek without him asking — for 30 days straight, across all 7 products, with no human intervention required to keep the system functioning.**

That single sentence is the north star. If at week 10 we cannot truthfully say it, the architecture has not shipped — only its components have.

### 12.bis.5 — Forcing functions to prevent silent partial-implementation

The biggest risk to this kind of architecture is "we shipped 11 of 13 phases and called it done; the last 2 were too hard." To prevent that:

1. **No phase can be marked complete without U1–U8.** The DoD checker script blocks merge.
2. **`qa_cycle_assessment.learning_grade` cannot be A or A-** until P12 lands. This makes the absence of FeedbackConsolidator visible in every cycle report — the gap is loud, not silent.
3. **Portal `TESTING_QUALITY` panel shows phase completion bar** — "P1 ✅ P2 ✅ P3 ⚠️ in_progress P4 ❌ blocked …" — visible every time Vivek opens admin.
4. **Each phase's acceptance demo is recorded** (Loom or screen capture) and stored in `phronex-test-runner/strategist-acceptance/P{N}-demo.mp4`. No demo, no done.
5. **System-level S1–S8 gates are checked weekly** by an automated cron that posts to portal Audit tab. The day all 8 turn green for the first time is when the GA event fires — Vivek doesn't have to remember to check.

---

## 13. Out-of-scope / explicitly deferred

These appeared in the discussion but are deferred (not forgotten — listed here so they don't get lost):

- **Per-step LLM-as-judge for granular pass/fail** — current pass/fail at journey level is sufficient until P10.
- **Visual regression diffing** (screenshot-vs-baseline) — separate concern from the strategist; can plug in via UXObserver later.
- **Synthetic user persona library** (different roles, different data shapes) — useful but blocks on TEST-ORACLES + fixture seeding maturity.
- **Cross-product end-to-end journeys** (e.g. JP candidate → CC content brief in one flow) — orthogonal to single-product strategy; needs its own design pass.

---

## 14. Expert Review — making it watertight

> Reviewing the architecture above as if I had never written it, asking: where does this actually break under real-world load, what assumptions are unstated, what failure modes will bite us in production?

### 14.1 Failure modes the architecture as written does NOT handle

| # | Risk | Why the spec misses it | Required fix |
|---|---|---|---|
| **R1** | **The "verify-run passes" cycle-close gate can be gamed.** A flaky verify-run that just-barely passes (3-of-5 retries) closes the cycle and triggers FeedbackConsolidator with low-confidence evidence. | §7.1 says "verify-run passes" but doesn't define quality. | Cycle-close requires verify-run to pass on **first attempt**, OR pass twice in a row, OR have a `qa_ethos_rules` row explicitly approving the close. Otherwise cycle stays open. |
| **R2** | **`pattern_signature` collisions.** Two genuinely different defects can hash to the same signature (e.g. both involve URL construction but in different layers). Sweep then files irrelevant RISK rows. | §5.6 treats signatures as opaque strings. | Signature is a **structured tuple** `(layer, antipattern, evidence_hash_prefix)` — e.g. `(spec, hand_coded_id, a3f1)`. Sweep matches on `(layer, antipattern)` only — `evidence_hash_prefix` is for human disambiguation in `qa_sweep_overflow`. |
| **R3** | **Wiki article contradiction is binary** (`is_contradicted=TRUE`). Reality is messier — an article can be true in product A but false in product B. | §4.1 schema. | Replace `is_contradicted: bool` with `contradicted_in: TEXT[]` (list of product_slugs where the article is now wrong). Article applies only to `product_slugs - contradicted_in`. |
| **R4** | **Strategy signal flapping.** With a small `last_n=5` window, a single flaky run can flip signal from MAINTAIN to FOCUS and back. Each flip churns the run filter. | §6.2 Q1. | Apply **hysteresis**: signal change requires the new condition to hold for **2 consecutive runs**. Implemented as `qa_strategy_state.signal_age_runs` — current signal sticks until the alternative signal would have held twice. |
| **R5** | **Fixture seeding has no provenance.** `qa_fixture_requirements.status='SEEDED'` doesn't say *who* seeded, *when expires*, or how to *reseed deterministically*. Manual seeding rots silently. | §6.5 schema. | Add `seeded_by` (script/path), `seed_command` (shell command to reseed), `expires_at` (TTL), `verified_at`. A nightly cron runs `seed_command` for any `SEEDED` fixture older than `expires_at`. |
| **R6** | **CrossRepoSweep can run during business hours and hammer DBs.** Sweeps over phronex-common's full repo set (8+ repos) with grep + AST parsing is non-trivial CPU. | §5.5. | Sweeps run on DevServer **after-hours queue** (cron 02:00 IST), never inline at run-time. RunArbiter only filings the *intent to sweep*; the sweep itself is async. |
| **R7** | **Deterministic RCA classifier becomes the bottleneck.** Each new defect class needs a code change to add a heuristic. The system stops learning new classes when the team is busy. | §5.4. | Heuristics live in `phronex_common.testing.rca.heuristics.yaml` — config, not code. New patterns added by editing YAML, not deploying. LLM-fallback writes proposed heuristics to `qa_proposed_heuristics` for human promotion. |
| **R8** | **`PROPOSED-INVARIANTS.md` queue review never happens.** Without a forcing function, the queue grows forever. | §7.3. | `gsd-housekeeping` Tier 2 (weekly) **blocks** if `PROPOSED-INVARIANTS.md` has > 10 unresolved entries older than 14 days. Forces human triage. |
| **R9** | **DocChain stage-gate halts can deadlock.** If `INTEGRATION-MAP.html` is missing and `docchain-integration-map` skill itself depends on test results to know what to map → infinite loop. | §3.3. | First-run bootstrap mode: if a skill's required input doesn't exist, the skill produces a **`STUB.html`** marked `confidence=LOW, stub=true`. JourneyHawk runs in `BOOTSTRAP` strategy signal — accepts stubs but flags every defect they may have caused. |
| **R10** | **`qa_cycle_assessment` grades have no calibration.** "B" means what? Without a rubric, grades drift over time as different runs interpret thresholds differently. | §6.5 + §7.4. | Grade rubric is **versioned** (`qa_cycle_assessment.rubric_version`). Rubric stored in `qa_grade_rubrics` table with explicit thresholds per grade. Changing the rubric is an explicit migration, not a silent code change. |
| **R11** | **Bounded sweep budget (`max 3 RISK/repo`) hides real bugs.** If a pattern genuinely affects 12 files in one repo, only 3 are filed; 9 ship with the bug. | §5.5. | Sweep produces **summary** (`N matches found, top 3 filed as RISK`), and the summary itself becomes an issue tagged `BREADTH_HIGH` — forces a pattern-level fix (refactor) instead of N point fixes. |
| **R12** | **Cold-start period has no exit criterion** beyond "first 3 runs". A product with very low activity stays in cold-start indefinitely if runs are sparse. | §9 cold-start row. | Cold-start exits when **either** 3 runs OR 30 days elapse — whichever first. After that, the strategist must commit to a signal even with thin data, and confidence is tagged `LOW_BASELINE` so consumers know. |
| **R13** | **No write-throttle on `qa_ux_signals`.** A noisy UXObserver could file 100 FRICTION signals per run, drowning the monthly review. | §6.5 + §7.4. | `UNIQUE (product_slug, surface, observation_type)` constraint exists. ALSO: per-run cap of 20 NEW signals (deduplication via fuzzy match on `description`). Excess accumulates as `occurrence_count` increment on existing signals — surfaces noise without filing it. |
| **R14** | **The "exponential improvement" claim is unfalsifiable** without a baseline. There's no way to know if cycle 30 is actually better than cycle 5. | §12 metrics are forward-looking. | Add **§12.bis: Baseline Capture** — at week 0, freeze a `qa_baseline_run` row with current FP rate, defect yield, USER-SPEC coverage. Every cycle assessment compares against this baseline AND the rolling 5-cycle average. Two anchors, not one. |
| **R15** | **No kill-switch.** If the StrategistLayer starts misbehaving (e.g. mutation directives are wrong and cause every run to abort), there's no documented way to disable it without code changes. | Spec assumes everything works. | Single env flag `STRATEGIST_MODE` with values: `ACTIVE` (default), `READ_ONLY` (compute decisions but apply none), `DISABLED` (skip Strategist entirely, fall through to legacy run filter). Documented in Phronex_Internal_QA_JourneyHawk runbook. |

### 14.2 Architectural assumptions worth surfacing

These weren't wrong in the spec, but they were implicit. Making them explicit prevents future confusion:

1. **All seven products use the same WikiStore + StrategistLayer.** No per-product divergent strategies. If a product needs custom handling, it goes in `qa_ethos_rules`, not in a code fork.
2. **`qa_known_defects.fixed_at IS NOT NULL` is the SOURCE OF TRUTH for "defect closed".** RCA, FeedbackConsolidator, and Strategist all key off this column. Code that closes defects without setting `fixed_at` will silently break the cycle.
3. **DocChain artefacts are produced from the codebase, not from test results.** A failing test is a *signal* to the DocChain skill that an artefact is wrong, but the skill must regenerate from the canonical source (code + git history), not from the test failure. Otherwise tests become circular references.
4. **Grades in `qa_cycle_assessment` are descriptive, not directive.** A B+ doesn't trigger anything automatically. Vivek (or future automation) interprets the trend. We deliberately do NOT auto-revert deploys based on grades — that requires a separate, deeper conversation.
5. **The system is single-tenant.** All tables live in one `phronex_qa` DB on DevServer. Multi-tenant isolation (e.g. if Phronex ever hosts QA-as-a-service for clients) is out of scope.

### 14.3 Operational concerns the spec under-specifies

| Concern | Resolution |
|---|---|
| **Migrations.** §11 lists 6 new tables + 1 ALTER. With Alembic single-head invariant, this is at least 3 migration revisions. | Phase the migrations: P3 lands `qa_strategy_state` + `qa_cycle_assessment`; P4 lands `qa_defect_rca` + `qa_sweep_overflow`; P11 lands `qa_ux_signals`; P2 lands `qa_fixture_requirements`. Each is a single-revision migration. The ALTER on `qa_wiki_articles` (4 new columns + new types as JSONB) lands in P7. |
| **Backfill.** New `qa_defect_rca` table on a system with 100+ existing defects — do we backfill RCAs for history? | Backfill is **opt-in via a one-shot script**. Default: existing defects get a `rca_id=NULL` and `defect_class='UNCLASSIFIED'`. New defects always classify. Backfill script targets defects fixed in the last 90 days only. |
| **Cost.** LLM-fallback RCA classification could be expensive if defect rate spikes. | Hard daily cap: `RCA_LLM_BUDGET_USD` env var (default $2/day). When exceeded, classification falls back to `defect_class='UNCLASSIFIED_BUDGET_HIT'` and the strategist gets a warning. |
| **Observability.** How do we know the Strategist itself is healthy? | New `/admin/audit?tab=testing-quality` panel shows: last cycle grade, `STRATEGIST_MODE`, days since last `cycle_close`, RCA classifier hit-rate (deterministic vs LLM vs failed), top 5 active wiki mutations. Becomes the strategist's dashboard. |
| **Permissions.** Who can write to `qa_wiki_articles`? Currently anything that imports phronex-common. | Wiki writes go through `phronex_common.testing.wiki.WikiStore.upsert()` which logs `written_by` (env var or hostname). RBAC enforcement deferred until P10. |

### 14.4 Two changes to the implementation order I recommend

| Original | Reason to swap | Revised |
|---|---|---|
| P3 (Week 2): Self-assessment writes to DB | Without this, P4 RCA history can't compare against baseline → swap upstream of P3 not feasible | **Keep at week 2 BUT add §12.bis baseline capture as a P3 prerequisite** |
| P9 (Week 6–7): New DocChain child skills | These are big and risk slipping; the architecture works at reduced effectiveness without them | **Insert P5.5 (Week 4): manually author the FIRST `TEST-ORACLES.html` for portal as a hand-built proof-of-value before building the generator skill in P9.** This validates the format and surfaces requirements for the auto-generator. |

### 14.5 Single biggest watertightness improvement

If I had to pick **one** change to the original architecture that prevents the most pain in the first 6 months: **R1 — define cycle-close rigorously**. Without it, the FeedbackConsolidator runs on noisy data and writes wrong patterns to CODING-PATTERNS.md, wrong articles to WikiStore, wrong invariants to PROPOSED-INVARIANTS.md. Those writes are hard to retract because consumers (engineers, GSD subagents, future runs) have already read them. The single rule "cycle closes when verify-run passes first-attempt OR twice-in-a-row OR ethos-approved" prevents that entire failure mode.

### 14.6 Verdict

The architecture as written in §1–§13 is **structurally sound but operationally fragile**. The 15 risks in §14.1, the 5 unstated assumptions in §14.2, and the 5 operational concerns in §14.3 are the gap between "good design" and "watertight system."

Folding §14 fixes back into §1–§13 turns the spec from a design document into an implementation contract. **My recommendation: treat §14 as required acceptance criteria for each phase in §10**, not as optional polish. The Strategist either ships with R1, R7, R9, R12, R15 from day one, or it doesn't ship — those five are existential.

