# Block A — `/gsd:quick` brief: P1 RunArbiter + P2 Fixture Guard

> **What this is:** A self-contained `/gsd:quick` task spec for the StrategistLayer Block A spike. Read this entire document into the `/gsd:quick` invocation; everything needed is captured here.
>
> **Why a spike, not a phase:** Validates two architectural claims (abort gate works, fixture guard catches FPs) before committing to the 230h Phase 80 + 81 + 82 build. Total expected effort: **18h** (range 14–26h).
>
> **Prerequisites validated:** ✅ phronex_qa connectivity (62 defects exported), ✅ runner.py public API surveyed, ✅ run-journeyhawk.sh entry point understood, ✅ existing fixture-text patterns in journey specs (see `portal-deep.json` step 1 "BROWSER RESET FIRST").
>
> **Out of scope:** anything beyond P1 + P2. Do NOT touch RCAEngine (P4), CrossRepoSweep (P5), WikiStore mutations (P7), DocChain skills (P9), FeedbackConsolidator (P12), or the Portal panel (P13). Block A is a hedge, not a foundation.

---

## Source spec

- Architecture: `~/code/phronex-test-runner/STRATEGIST-ARCHITECTURE.md` §6 (RunArbiter), §6 (component map)
- Plan: `~/code/phronex-test-runner/STRATEGIST-IMPLEMENTATION-PLAN.md` §3 Block A (P1 + P2 detail)
- Heuristics seed (read-only reference): `~/code/phronex-test-runner/strategist-prep/qa_known_defects_seed.json`

---

## P1 — RunArbiter (in-run abort gate)

### What it does

Streams cc-test-runner stdout in real-time. When configured abort conditions are met, **stops the run cleanly** rather than letting it continue burning OAuth time and producing low-signal results.

### Abort conditions (configurable via env, defaults below)

| Condition | Default | Why |
|---|---|---|
| **Consecutive journey failures** | 3 | After 3 in a row, the next one is overwhelmingly likely to fail too — wasted OAuth time. |
| **Total OAuth time exceeded** | 30 min | Hard cap; if a single run exceeds 30 minutes the spec is too broad. |
| **Per-journey time exceeded** | 5 min | Single journey hung; LLM is stuck in a loop. |
| **Network failure rate** | >50% of last 4 journeys had ≥1 502 | Backend is down — keep running journeys is testing nothing. |

All four are env-overridable: `STRATEGIST_ABORT_CONSECUTIVE_FAILS`, `STRATEGIST_ABORT_MAX_RUNTIME_SEC`, `STRATEGIST_ABORT_PER_JOURNEY_SEC`, `STRATEGIST_ABORT_NETWORK_FAIL_RATE`.

**Master kill-switch (R15):** `STRATEGIST_MODE=DISABLED` → arbiter is bypassed entirely (legacy behaviour). `STRATEGIST_MODE=READ_ONLY` → arbiter logs decisions but does not abort. `STRATEGIST_MODE=ACTIVE` (default) → arbiter aborts on triggered conditions.

### Where it lives

**New module:** `phronex_common/src/phronex_common/testing/strategist/__init__.py` + `phronex_common/src/phronex_common/testing/strategist/run_arbiter.py`

```
phronex_common/testing/
├── strategist/                       # NEW package
│   ├── __init__.py                   # exports RunArbiter, AbortReason
│   ├── run_arbiter.py                # RunArbiter class (streams stdout, decides)
│   └── abort_reasons.py              # AbortReason enum (CONSECUTIVE_FAILS, MAX_RUNTIME, etc.)
```

### How it integrates with run-journeyhawk.sh

Today the shell script invokes `cc-test-runner` directly (line ~120 of `run-journeyhawk.sh`). After P1, the invocation is wrapped:

```bash
# BEFORE (current):
cc-test-runner run --spec "${TEMP_SPEC}" --output "${RESULTS_DIR}"

# AFTER (P1):
${PYTHON} -m phronex_common.testing.strategist.run_arbiter \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec "${TEMP_SPEC}" \
  -- \
  cc-test-runner run --spec "${TEMP_SPEC}" --output "${RESULTS_DIR}"
```

The arbiter spawns the cc-test-runner subprocess, pipes its stdout, parses CTRF events (existing `runner.py:load_ctrf` shape), tracks state, and on abort signal sends `SIGTERM` to the child process, then writes a partial CTRF + `abort_reason.json` to `RESULTS_DIR` so the existing post-run pipeline (`phronex_common.testing.runner.run_pipeline`) handles the partial results gracefully.

### Tasks

| # | Task | Effort | Verification |
|---|---|---|---|
| 1 | Create `phronex_common/testing/strategist/` package | 0.5h | `python -c "from phronex_common.testing.strategist import RunArbiter"` |
| 2 | Implement `AbortReason` enum + `RunArbiter` class | 3h | Unit test: feeds synthetic CTRF events, asserts abort triggers |
| 3 | Wire env-config loader (4 env vars + STRATEGIST_MODE) | 1h | Unit test: `STRATEGIST_MODE=DISABLED` → never aborts |
| 4 | Implement subprocess spawn + stdout streaming with abort signalling | 3h | Integration test: spawn `sleep 60` subprocess, signal abort, verify SIGTERM delivered ≤2s |
| 5 | Wire `--` separator → command pass-through | 0.5h | `python -m … -- echo hello` works |
| 6 | Add `abort_reason.json` write on abort + partial CTRF preservation | 1h | Integration test: abort midway, assert `abort_reason.json` exists with shape `{reason, triggered_at, journeys_completed}` |
| 7 | Modify `run-journeyhawk.sh` to wrap cc-test-runner with arbiter | 0.5h | Run against `portal-settings-verify.json`, verify normal completion still works |
| 8 | Modify `phronex_common.testing.runner.run_pipeline` to detect + log `abort_reason.json` | 1h | Run with simulated abort, verify pipeline writes `aborted=True` to `qa_journeys` row |
| **P1 total** | | **~10h** | |

### Acceptance criteria for P1

- [ ] `STRATEGIST_MODE=DISABLED` → JourneyHawk runs identically to today (zero behaviour change)
- [ ] `STRATEGIST_MODE=READ_ONLY` → JourneyHawk runs to completion BUT arbiter logs every abort *would-have-fired* event to stderr
- [ ] `STRATEGIST_MODE=ACTIVE` + 3 consecutive failures → run aborts within 5s of third failure
- [ ] Aborted run writes `abort_reason.json` AND partial CTRF, both readable by existing `run_pipeline`
- [ ] `qa_journeys` row for aborted run has `suite_scope` suffixed `:aborted` (or new `aborted` column — implementer's call, document choice)
- [ ] Unit test coverage ≥85% on `run_arbiter.py`
- [ ] Integration test: run against deliberately-broken portal spec (point at unreachable host) — verify abort fires within 2 minutes vs current 8+ minute hang

---

## P2 — Fixture Guard (drop journeys with unsatisfiable preconditions)

### What it does

Before cc-test-runner ever sees the spec, parses each journey for **fixture requirements** (login state, test accounts, seed data, browser state) and drops journeys whose fixtures aren't satisfied — with a logged reason — instead of letting them run and inevitably FP.

### Where today's fixture text lives

Existing journey specs encode fixture requirements as **step 1 prose**:

```json
{
  "id": 1,
  "description": "BROWSER RESET FIRST: Use browser_tabs to list all open tabs. Close every tab except the current one. Clear localStorage for app.phronex.com."
}
```

Plus credentials injected at runtime by `run-journeyhawk.sh` sed substitution (`QA_SUPERADMIN_PASSWORD`, `QA_OWNER_EMAIL`, etc.). P2 formalises this — extracts a structured fixture inventory **per journey**, checks satisfiability before run start.

### Fixture types to detect (from existing spec corpus)

| Fixture | Detection signal | Satisfiability check |
|---|---|---|
| `superadmin_login` | Step text contains `qa-test-journeyhawk@phronex.com` or sentinel `QA_SUPERADMIN_PASSWORD` | `PHRONEX_PORTAL_TEST_PASSWORD` env is set AND non-empty |
| `owner_login` | Step text contains `QA_OWNER_EMAIL` | `QA_OWNER_PASSWORD` env is set AND non-empty |
| `user_login` | Step text contains `QA_USER_EMAIL` | `QA_USER_PASSWORD` env is set AND non-empty |
| `seed_test_account` | Step text contains `e2e-test-` prefix | DB query confirms ≥1 row exists in `accounts` matching prefix |
| `browser_clean_state` | Step text contains `BROWSER RESET FIRST` | Always satisfied (cc-test-runner handles) |
| `backend_reachable` | Step text contains a URL like `https://app.phronex.com` | TCP connect to host:443 succeeds within 5s |

Detection is **regex over step text** initially (deterministic). Future versions can add explicit `fixtures: [...]` block in spec JSON; not required for P2.

### Where it lives

**Same package as P1:** `phronex_common/src/phronex_common/testing/strategist/fixture_guard.py`

```
phronex_common/testing/strategist/
├── ...
├── fixture_guard.py                  # FixtureInventory + FixtureGuard
└── fixture_detectors.py              # individual detector functions per fixture type
```

### How it integrates with run-journeyhawk.sh

Runs **before** the cc-test-runner invocation, takes the spec, returns a filtered spec:

```bash
# AFTER P1+P2 (full Block A):
FILTERED_SPEC=$(${PYTHON} -m phronex_common.testing.strategist.fixture_guard \
  --spec "${TEMP_SPEC}" \
  --report "${RESULTS_DIR}/fixture-decisions.json")

${PYTHON} -m phronex_common.testing.strategist.run_arbiter \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec "${FILTERED_SPEC}" \
  -- \
  cc-test-runner run --spec "${FILTERED_SPEC}" --output "${RESULTS_DIR}"
```

`fixture-decisions.json` written to results dir documents what was kept, what was dropped, and why — consumed later by the post-run pipeline + the future Strategist UI panel (P13).

### Tasks

| # | Task | Effort | Verification |
|---|---|---|---|
| 1 | `FixtureInventory` dataclass — fields per fixture type | 0.5h | mypy check passes |
| 2 | Per-fixture detector functions (6 detectors above) | 2h | Unit test: each detector against synthetic step text + env |
| 3 | `FixtureGuard.evaluate(spec)` → returns kept/dropped split | 1.5h | Unit test: spec with 3 satisfiable + 2 unsatisfiable → 3 kept, 2 dropped |
| 4 | `FixtureGuard.write_decision_report(path)` → JSON output | 0.5h | Unit test: round-trip JSON shape |
| 5 | CLI entry point `python -m phronex_common.testing.strategist.fixture_guard` | 0.5h | `--spec foo.json --report bar.json` exits 0 |
| 6 | Filtered spec output (preserves journey ID order, removes dropped) | 1h | Unit test: 5-journey spec → 3-journey filtered spec |
| 7 | `STRATEGIST_MODE` honour: DISABLED → return spec unchanged; READ_ONLY → log decisions but return original; ACTIVE → drop | 0.5h | Unit test per mode |
| 8 | Backend reachability detector with 5s timeout | 1h | Unit test: socket mock; integration test against `127.0.0.1:1` (refused) |
| 9 | Modify `run-journeyhawk.sh` to chain fixture_guard → arbiter | 0.5h | End-to-end: run portal-settings-verify.json with PHRONEX_PORTAL_TEST_PASSWORD unset → all login journeys dropped, fixture-decisions.json written |
| **P2 total** | | **~8h** | |

### Acceptance criteria for P2

- [ ] `STRATEGIST_MODE=DISABLED` → fixture_guard is a passthrough (zero behaviour change)
- [ ] Run with `PHRONEX_PORTAL_TEST_PASSWORD=""` → all journeys requiring superadmin_login are dropped with reason `"superadmin_login fixture unsatisfied: PHRONEX_PORTAL_TEST_PASSWORD env unset"`
- [ ] Run against unreachable host → all journeys requiring `backend_reachable` are dropped within 5s
- [ ] `fixture-decisions.json` shape: `{kept: [...], dropped: [{journey_id, fixture, reason}]}`
- [ ] No journey is dropped silently — every drop has a reason string
- [ ] False positive prevention test: take 5 known-FP journeys from past runs (look up in `qa_known_defects WHERE category='friction' AND title LIKE '%fixture%'` — there are 3 in the seed corpus), confirm fixture_guard would have dropped each one before run-time

---

## Combined Block A acceptance criteria

These verify the spike's strategic claim: *"abort gate + fixture guard together eliminate ~50% of current QA waste."*

- [ ] **Baseline measurement:** Run JourneyHawk 3 times against current portal-settings-verify.json with `STRATEGIST_MODE=DISABLED`. Record: total OAuth seconds, total journeys, FP count.
- [ ] **Strategist measurement:** Run same spec 3 times with `STRATEGIST_MODE=ACTIVE`. Record same metrics.
- [ ] **Strategist measurement (broken backend):** Stop one product backend (e.g. `sudo systemctl stop praxis-backend`), run JourneyHawk 3 times with `STRATEGIST_MODE=ACTIVE` against a praxis-touching spec.
- [ ] Document the deltas in `~/code/phronex-test-runner/strategist-prep/BLOCK-A-RESULTS.md`. Required fields per measurement: total OAuth seconds, journeys completed, journeys dropped (P2), abort fired (P1, yes/no + reason), FP count, real defects found.

**Pass criteria for the spike (architecture validation):**
- ACTIVE mode does not produce **more** FPs than DISABLED mode (regression check)
- Broken-backend test: ACTIVE mode aborts within 2 minutes; DISABLED runs to completion (>8 minutes)
- Fixture guard drops at least **one** journey when an env credential is unset (proves detection works against real specs)
- `qa_journeys` row written for every run, including aborted runs

If any pass criterion fails: **DO NOT** proceed to Phase 80. Surface the failure in `BLOCK-A-RESULTS.md` and re-evaluate the architecture.

---

## Files this spike will create / modify

| File | Action | Repo |
|---|---|---|
| `src/phronex_common/testing/strategist/__init__.py` | CREATE | phronex-common |
| `src/phronex_common/testing/strategist/run_arbiter.py` | CREATE | phronex-common |
| `src/phronex_common/testing/strategist/abort_reasons.py` | CREATE | phronex-common |
| `src/phronex_common/testing/strategist/fixture_guard.py` | CREATE | phronex-common |
| `src/phronex_common/testing/strategist/fixture_detectors.py` | CREATE | phronex-common |
| `tests/testing/strategist/test_run_arbiter.py` | CREATE | phronex-common |
| `tests/testing/strategist/test_fixture_guard.py` | CREATE | phronex-common |
| `src/phronex_common/testing/runner.py` | MODIFY (small — detect abort_reason.json, log to qa_journeys) | phronex-common |
| `run-journeyhawk.sh` | MODIFY (wrap cc-test-runner with strategist chain) | phronex-test-runner |
| `strategist-prep/BLOCK-A-RESULTS.md` | CREATE | phronex-test-runner |

**No DB migrations.** Block A uses existing `qa_journeys` table; if a new column for `aborted` is preferred over `:aborted` suffix, that's a Phase 80 migration (defer).

**No new env vars in `.qa.env` required to start.** Defaults work; overrides are optional.

---

## Why this brief is safe to fire as `/gsd:quick`

- All work is **additive** — no existing module is rewritten
- `STRATEGIST_MODE=DISABLED` default makes the spike **zero-risk to skip** if validation fails
- 18h is small enough that the standard `/gsd:quick` workflow (no full PLAN.md ceremony) is appropriate
- All tests are unit + integration; no UI, no migrations, no deploys, no deprecations
- Verification metrics are quantitative — no judgment call required to declare pass/fail
- Output (`BLOCK-A-RESULTS.md`) is the input to the Phase 80 effort re-estimation

---

## Out of scope reminders (do NOT do these in Block A)

- ❌ Don't build RCAEngine — that's P4, Phase 80
- ❌ Don't extend WikiStore schema — that's P7, Phase 81
- ❌ Don't write any DocChain skills — that's P9, Phase 81
- ❌ Don't add the Portal panel — that's P13, Phase 82
- ❌ Don't backfill historical `qa_known_defects` with abort/fixture reasons — explicitly out per CONTEXT.md scope
- ❌ Don't refactor `runner.py` beyond the small abort_reason.json detection hook — saving the larger refactor for Phase 80
