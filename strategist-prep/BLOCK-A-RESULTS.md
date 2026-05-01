# Block A Spike — Measurement Results

> **Status:** Template (populated post-spike via 8 measurement runs).
>
> **Purpose:** Compare baseline (`STRATEGIST_MODE=DISABLED`) vs strategist
> (`STRATEGIST_MODE=ACTIVE`) across 3 runs each plus a broken-backend pair, to
> validate the spike's strategic claim that *abort gate + fixture guard
> together eliminate ~50% of current QA waste*.
>
> **Decision input:** This file is the input to the Phase 80 effort
> re-estimation. If pass criteria fail, **do NOT proceed to Phase 80**;
> document failure in the analysis section and re-evaluate the architecture.

## Spec under test

- Primary spec: `portal-journeys/portal-settings-verify.json`
- Broken-backend spec: any praxis-touching journey (Run 7 stops `praxis-backend` first)

## Measurement protocol

Operator runbook (run from DevServer, NOT EC2):

1. **Baseline (Runs 1-3):** Three back-to-back runs with strategist disabled.
   ```bash
   cd /home/ouroborous/code/phronex-test-runner
   for i in 1 2 3; do
     STRATEGIST_MODE=DISABLED ./run-journeyhawk.sh portal portal-journeys/portal-settings-verify.json \
       portal-journeys/results-baseline-${i}-$(date +%Y%m%d-%H%M%S)
   done
   ```

2. **Strategist healthy (Runs 4-6):** Same spec, default mode (ACTIVE).
   ```bash
   for i in 4 5 6; do
     ./run-journeyhawk.sh portal portal-journeys/portal-settings-verify.json \
       portal-journeys/results-strategist-${i}-$(date +%Y%m%d-%H%M%S)
   done
   ```

3. **Strategist broken-backend (Runs 7-8):** Stop one product backend, run
   strategist (must abort within 2 min) and disabled (must run >8 min) once
   each.
   ```bash
   sudo systemctl stop praxis-backend
   ./run-journeyhawk.sh praxis praxis-journeys/<praxis-spec>.json \
     praxis-journeys/results-broken-active-$(date +%Y%m%d-%H%M%S)
   STRATEGIST_MODE=DISABLED ./run-journeyhawk.sh praxis praxis-journeys/<praxis-spec>.json \
     praxis-journeys/results-broken-disabled-$(date +%Y%m%d-%H%M%S)
   sudo systemctl start praxis-backend
   ```

4. **Per-run data capture:** From each `${RESULTS_DIR}/`, extract:
   - **Total OAuth seconds** — sum the `duration` ms in `ctrf-report.json` results.tests
   - **Journeys completed** — len(results.tests)
   - **Journeys dropped (P2)** — len(`fixture-decisions.json`.dropped)
   - **Abort fired (P1)** — `abort_reason.json` exists yes/no + reason
   - **FP count** — `phronex_qa.qa_known_defects` rows for this run with `category='friction'` (manual review of the run's defect rows)
   - **Real defects** — `qa_known_defects` rows NOT classified as friction/false-positive

## Run matrix — primary spec

| Run | Mode     | Total OAuth (s) | Journeys completed | Journeys dropped (P2) | Abort fired (P1)?  | FP count | Real defects |
| --- | -------- | --------------- | ------------------ | --------------------- | ------------------ | -------- | ------------ |
| 1   | DISABLED | TBD             | TBD                | 0 (n/a)               | n/a                | TBD      | TBD          |
| 2   | DISABLED | TBD             | TBD                | 0 (n/a)               | n/a                | TBD      | TBD          |
| 3   | DISABLED | TBD             | TBD                | 0 (n/a)               | n/a                | TBD      | TBD          |
| 4   | ACTIVE   | TBD             | TBD                | TBD                   | yes/no — reason    | TBD      | TBD          |
| 5   | ACTIVE   | TBD             | TBD                | TBD                   | yes/no — reason    | TBD      | TBD          |
| 6   | ACTIVE   | TBD             | TBD                | TBD                   | yes/no — reason    | TBD      | TBD          |

## Run matrix — broken-backend test

| Run | Mode     | Total OAuth (s) | Abort fired? | Reason | Time-to-abort           |
| --- | -------- | --------------- | ------------ | ------ | ----------------------- |
| 7   | ACTIVE   | TBD             | yes/no       | TBD    | TBD (target ≤ 2 min)    |
| 8   | DISABLED | TBD             | n/a          | n/a    | TBD (expect ≥ 8 min)    |

## Computed deltas

Fill in after the 8 runs above:

- **OAuth-time savings (avg ACTIVE vs avg DISABLED, primary spec):** TBD seconds (TBD %)
- **FP suppression (avg FP delta):** TBD
- **Broken-backend abort time delta (Run 7 vs Run 8):** TBD min vs TBD min

## Pass / fail per criterion

Sign-off — operator fills in YES/NO + evidence reference (run number / file path):

- [ ] **ACTIVE mode does not produce more FPs than DISABLED mode (regression check)**
  - Evidence: avg FP count Runs 4-6 ≤ avg FP count Runs 1-3
  - Result: TBD

- [ ] **Broken-backend test: ACTIVE aborts within 2 minutes; DISABLED runs >8 minutes**
  - Evidence: Run 7 time-to-abort ≤ 120s AND Run 8 total time ≥ 480s
  - Result: TBD

- [ ] **Fixture guard drops at least one journey when an env credential is unset**
  - Evidence: any of Runs 4-6 `fixture-decisions.json` dropped[] non-empty when an expected credential is unset (operator may unset `QA_OWNER_PASSWORD` deliberately for one run to prove this)
  - Result: TBD

- [ ] **`qa_journeys` row written for every run, including aborted runs**
  - Evidence: 8 rows in `phronex_qa.qa_journeys` matching the 8 result dirs above; aborted runs have `suite_scope LIKE '%:aborted'`
  - SQL: `SELECT suite_scope, started_at, journeys_run FROM qa_journeys WHERE started_at >= NOW() - INTERVAL '24 hours' ORDER BY started_at;`
  - Result: TBD

## Decision

- [ ] **PROCEED to Phase 80** — all four pass criteria green; spike validated. Use measured deltas to refine Phase 80 effort estimate.
- [ ] **HOLD** — re-evaluate architecture; one or more pass criteria failed. Document below before any further work on STRAT-* requirements.

### If HOLD: failure analysis

Operator fills in:

- Which criterion failed?
- Root cause hypothesis (which strategist module / which product / which env)?
- Proposed remediation (revise heuristic / add detector / change default mode)?
- Re-run plan?

## How to re-run after fixes

Each fix produces a new round of Runs 1-8 above. Append a new section
`## Round N (YYYY-MM-DD)` rather than overwriting Round 1; the historical
record matters for the Phase 80 spec.

## Out of scope for this spike (do NOT measure here)

- RCAEngine output quality — Phase 80
- WikiStore mutations — Phase 81
- Portal panel surfacing — Phase 82
- Backfilling historical `qa_known_defects` with abort/fixture reasons — explicit non-goal per CONTEXT.md
