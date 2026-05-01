---
project: phronex-test-runner
type: internal-tooling
created: 2026-05-01
status: external-roadmap
external_roadmap: /home/ouroborous/code/phronex-common/.planning/ROADMAP.md
---

# Roadmap — phronex-test-runner

## This repo has no internal roadmap

Roadmap ownership lives in **phronex-common**. See:

- **`/home/ouroborous/code/phronex-common/.planning/ROADMAP.md`** — Phase 80/81/82 (v18.0 Strategist Layer)
- **`/home/ouroborous/code/phronex-common/.planning/REQUIREMENTS.md`** — STRAT-01..18 with acceptance criteria
- **`/home/ouroborous/code/phronex-common/.planning/MILESTONE-CONTEXT.md`** — full v18.0 milestone context

## Why?

phronex-test-runner is a **service repository** to phronex-common. Its evolution is driven by what the Strategist Layer needs from the runner side (RunArbiter, Fixture Guard, intelligence-pipeline contracts). Maintaining a parallel roadmap here would create a dual source of truth — and the only legitimate source is the milestone owning the work.

## Active Work — Block A (phronex-common v18.0)

**Brief:** `strategist-prep/BLOCK-A-QUICK-BRIEF.md` (in this repo, not committed yet)
**Estimated effort:** 18h
**Run via:** `/gsd:quick BLOCK-A-QUICK-BRIEF.md`
**Status:** Not started — awaiting GSD scaffold sign-off

### Deliverables

- [ ] **P1 RunArbiter** — central decision module that decides which journeys execute per run
  - Replaces ad-hoc filter logic currently scattered in `runner.py:484` (`_cross_product_propagation_check`)
  - Inputs: `qa_known_defects`, last-run results, DocChain delta, git activity since `first_seen_at`
  - Outputs: filtered journey list + skip reasons (the same three-reason table the skill already enforces)
  - Tests: deterministic, unit-tested, no DB writes

- [ ] **P2 Fixture Guard** — validate `qa_test_fixtures` table state before any run
  - Refuses to run if pollution detected (e.g. orphan `e2e-*` records, leaked test users in production identity DB)
  - Hooks into PHASE 1 of the JourneyHawk skill (intelligence load) as a pre-condition
  - Surfaces failures as a HARD HALT, not a warning

## Future Work

**There is none defined here.** Future v18.x phases (81 — Closed-Loop Learning, 82 — Strategist GA) may add runner-side deliverables. When they do, they will be planned in phronex-common and executed here via `/gsd:quick` or `/gsd:plan-phase`.

If a future deliverable is large enough to warrant its own phase numbering, we will reconsider whether this repo should adopt its own roadmap. For now: minimal scaffold, external roadmap.

## Phase Numbering Convention

If `/gsd:plan-phase N` is ever invoked here, **N must match the phronex-common phase number** that owns the work. Example: a Phase 81 deliverable in this repo gets `.planning/phases/81-{slug}/PLAN.md` here, mirroring the phase number in phronex-common. This keeps cross-repo traceability explicit.

---
*Last updated: 2026-05-01 — scaffold-only init, no internal phases planned*
