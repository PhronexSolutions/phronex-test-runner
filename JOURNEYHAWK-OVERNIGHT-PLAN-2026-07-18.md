# JourneyHawk Overnight Sprint — Standing Instructions

Single source of truth for the ongoing overnight autonomous JourneyHawk work
against ContentCompanion. Read this file at the start of any session
continuing this work.

---

## Original goal (set 2026-07-17, verbatim intent)

1. Launch JourneyHawk sprints against ContentCompanion **continuously
   overnight** — not stopping after Sprint 2. Each sprint ~20 minutes: run
   journeys, then fix both **test infrastructure bugs** and **real product
   bugs** found.
2. After each sprint's fixes are committed, **launch the next sprint
   automatically** — don't wait for confirmation.
3. Each successive run should get **broader and deeper** coverage — using
   the 5 wiring-phase infrastructure (curator promotion, journey_merger,
   tree_optimizer, CrossRepoSweep, `should_generate()` auto-policy) so the
   journey spec actually grows run over run instead of staying static.
4. Standing authority to **merge and deploy** any PR raised on
   ContentCompanion and test-infra repos (phronex-common,
   phronex-test-runner) — pending or future — without asking each time.
5. Hard limits on that authority:
   - **No action with direct third-party cost impact** (no paid API spend,
     no AWS spend beyond normal operation).
   - **Never reduce a feature or piece of functionality** — only add
     coverage, fix real bugs, grow completeness.
   - Judgment standard: **what's right for the product and customer, not
     what's easiest.**
6. Billing/Razorpay checkout-completion boundary stays absolute — no
   journey ever completes a real charge.
7. Correction (2026-07-18): a context-usage warning is not a signal to stop
   the authorized loop — it means narrow what *new* investigation gets
   started, not halt the loop itself. Keep the core loop running; only
   pause for a genuine blocker or a decision only the operator can make
   (see the two deferred items below).

## Overnight results so far (sprints 3–11) — honest assessment

**Confirmed working:** curator's monotonic invariant (coverage never
shrinks, `70->70` held all night), CrossRepoSweep signal detection (5-6
high-confidence signals per sprint once data existed), `should_generate()`
MAINTAIN-mode gating (sensible defect_rate values 0.33-0.71).

**Not yet proven:** the full growth loop (generate → tree_optimize → merge
→ curator PROMOTE → coverage increase) has **never completed successfully,
0 for 2 attempts**. First blocked by the OAuth auth bug (fixed), then by a
newly-discovered `dependsOn: 'cc-trunk-superadmin'` mismatch (not yet
fixed — see Phase 1 below).

**Distinction to keep in mind:** JourneyHawk finding real CC defects
(instance-selector crash, widget outage, billing-mode auth, etc.) is the
tool working as intended — that's the point of it. Test infrastructure
breaking 5+ separate ways in one night (path resolution × 3 sites, missing
binary, missing cron, broken OAuth fallback) is NOT working as intended —
almost every infra bug only manifested when run from a nested-worktree
background-job context, not normal interactive repo-root usage.

## Plan of action (current priority order)

**Phase 1 — infra self-verification before more breadth work (IN PROGRESS):**
1. Add a cheap preflight to `run-journeyhawk.sh`: verify psycopg2 imports,
   `.qa.env` loaded, DB reachable, and one real 1-token LLM call succeeds —
   before spending 10+ minutes on a full journey suite. Tonight's psycopg2
   and OAuth bugs would have surfaced in seconds instead of after full runs
   silently discarded their results.
2. Fix the `cc-trunk-superadmin` dependency mismatch so a bad subset of
   generated journeys degrades gracefully (skip just those) instead of
   aborting the entire run's execution.
3. Add a regression test for the path-resolution bug class specifically —
   run `run-journeyhawk.sh` from a nested-worktree-like directory in CI,
   assert it doesn't fall back to broken relative-path defaults. This exact
   class hit us 3 separate times tonight (QA_ENV, VENV, DOCS_SLICES).

**Phase 2 — close the two deferred product findings properly:**
4. CC billing-mode auth mismatch (`billing_mode.py` sends a shared secret
   to a phronex-auth route that only accepts JWT) — needs real design
   review (shared-secret extension to phronex-auth vs. service-account JWT
   flow), not an improvised fix. See `DISCUSS-WITH-USER.md`.
5. Content-source ingestion timestamps (`cc-J03`) — needs new backend
   instrumentation at ingestion time, not just exposing existing data.

**Phase 3 — only after Phase 1 proves the growth loop works once:**
6. Resume "broader and deeper every run." This loop has never completed a
   single successful lap yet — don't resume claiming growth is happening
   until one full cycle (generate → merge → promote → coverage increase)
   has actually been observed to work.

**Phase 4 — visibility:**
7. The `defect_rate` / `CrossRepoSweep` signal count / curator
   promoted-collapsed-graph_merged numbers are only visible by grepping raw
   sprint logs right now. A one-page summary per run (or a `STATE.md`-style
   row) would make future diagnosis minutes instead of an investigation.

## Where things live

- Sprint run logs + results: `overnight-runs/sprint{N}.log` and
  `overnight-runs/sprint{N}/` (gitignored, this worktree only)
- Deferred/needs-operator-decision items: `DISCUSS-WITH-USER.md`
- This file: read first, update the "results so far" section as sprints
  complete, don't let it go stale
