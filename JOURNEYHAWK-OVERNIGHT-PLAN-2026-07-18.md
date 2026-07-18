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

## Overnight results so far (sprints 3–11 + verify-growth-loop) — honest assessment

**Confirmed working:** curator's monotonic invariant (coverage never
shrinks, `70->70` held all night), CrossRepoSweep signal detection (5-6
high-confidence signals per sprint once data existed), `should_generate()`
MAINTAIN-mode gating (sensible defect_rate values 0.33-0.71).

**PROVEN 2026-07-18 ~11:11 UTC — the full growth loop works end-to-end for
the first time.** After merging both fixes (OAuth `auth_token=` #88, trunk
synthesis #89) into phronex-common main, a full `run-journeyhawk.sh cc
cc-journeys/cc-deep.json` run with `JOURNEYHAWK_SKIP_GENERATION=0`
completed: 65 journeys generated (36 after sanitize/merge, 10 existing +
26 new), `cc-trunk-superadmin` synthesized cleanly (no abort), dependency
graph validated (36 journeys, 1 trunk, 25 with dependsOn — all resolved),
**19 journeys actually executed** (11 passed, 8 failed on real product
bugs), 8 defects written, 10 patterns promoted, and **curator coverage
moved 69→82** — the first movement off a flat number all night.
`CycleCloseGate: PASSED`, pipeline exit 0. This closes out the original
Phase 1 validation goal — do not re-litigate whether the loop works, only
whether the *next* run keeps working.

**New residual finding (not blocking, not yet fixed):** during that same
run, `business_journey_generator.py`'s cross-feature/deep-feature LLM calls
(the semantic "business logic journey" generation modes) still failed with
`401 invalid x-api-key` even with the OAuth fix merged — while
`journey_generator.py`'s enrichment step and the template-based surface
generation succeeded in the same run using the same OAuth token. Net
effect was small (0 business-logic journeys generated, but 52 surface
journeys covered the gap instead, so the run still succeeded), but the
auth fix isn't 100% propagated to every LLM call site. Root cause not yet
investigated — likely a different client construction path in
`business_journey_generator.py`'s `_run_generation`/`GenerateJourneys`
task vs. the `AnthropicProvider` path that got fixed. Logged for a future
pass, not urgent since it degrades gracefully to surface-only generation.

**Distinction to keep in mind:** JourneyHawk finding real CC defects
(instance-selector crash, widget outage, billing-mode auth, etc.) is the
tool working as intended — that's the point of it. Test infrastructure
breaking 5+ separate ways in one night (path resolution × 3 sites, missing
binary, missing cron, broken OAuth fallback) is NOT working as intended —
almost every infra bug only manifested when run from a nested-worktree
background-job context, not normal interactive repo-root usage.

## Plan of action (current priority order)

**Phase 1 — infra self-verification before more breadth work:**
1. ✅ DONE — cheap preflight added to `run-journeyhawk.sh` (psycopg2
   import, `.qa.env`/DB reachability, one real LLM call) before spending
   10+ minutes on a full journey suite (commit a69551c).
2. ✅ DONE — `cc-trunk-superadmin` dependency mismatch fixed by
   synthesizing the missing trunk journey instead of aborting the run
   (phronex-common PR #89, merged to main). Verified live 2026-07-18
   ~11:11 UTC: graph validated cleanly, 19 journeys executed, coverage
   69→82. See "PROVEN" note above.
3. ⏳ IN PROGRESS — regression test for the path-resolution bug class
   (nested-worktree-safe QA_ENV/VENV/DOCS_SLICES resolution). Being added
   via `/gsd:quick` — see `.planning/quick/260718-fk2-*`.

**Phase 2 — close the two deferred product findings properly:**
4. CC billing-mode auth mismatch (`billing_mode.py` sends a shared secret
   to a phronex-auth route that only accepts JWT) — needs real design
   review (shared-secret extension to phronex-auth vs. service-account JWT
   flow), not an improvised fix. See `DISCUSS-WITH-USER.md`.
5. Content-source ingestion timestamps (`cc-J03`) — needs new backend
   instrumentation at ingestion time, not just exposing existing data.

**Phase 3 — now unblocked, Phase 1 proved the growth loop works once:**
6. Resume "broader and deeper every run." The growth loop (generate →
   tree_optimize → merge → curator PROMOTE → coverage increase) has now
   been observed to work once (69→82, 2026-07-18 ~11:11 UTC). Safe to
   resume broader/deeper sprints — but watch for regressions, since this
   is still only one successful lap, not a proven steady-state.

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
