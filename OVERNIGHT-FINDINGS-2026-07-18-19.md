# Overnight JourneyHawk Findings — 2026-07-18/19 (sprints 13-16, product: cc)

**Why this file exists:** an audit of `phronex_qa`'s `qa_known_defects` and
`qa_evidence` tables found that the specific, actionable detail of a defect
(the actual error message) is computed by `gap_detector.detect_gaps()` but
**never persisted** — only a generic `"{journey_name}: error during
execution"` title is written, and `qa_known_defects`'s
`(product_slug, title)` unique constraint means a *different* failure on the
same journey silently collapses into the *same* row (bumps
`reoccurred_count`, overwrites `severity`/`category`, discards the specific
detail). `qa_evidence` is similarly thin for recent runs (console_log/har/
network_log/trace fields are `"MISSING"`; the one populated field,
`screenshot`, points into an ephemeral per-job tmp directory). Until that's
fixed (tracked as a phronex-common issue, ties to Finding 4b's already-known
deferred "full CTRF instrumentation" work), this file is the durable record
of what was actually found. Source: raw `overnight-runs/sprint{13,14,15,16}
{.log,.stdout.log}` in `.claude/worktrees/cc-journeyhawk-sprint1` (gitignored,
this worktree only — not backed up anywhere else).

---

## Confirmed recurring across 3+ of tonight's 4 sprints (strongest signal — not flaky)

1. **BYOS skill preview endpoint returns HTTP 500** — `POST
   /api/cc/user/api/v1/skills/{id}/preview`. Every single sprint tonight
   (13, 14, 15, 16). Create/Read/Update/Delete all work; the actual
   run/execute path is broken. CRITICAL — the feature is unusable end to end.

2. **Billing checkout still returns 503** — `POST
   /api/cc/user/api/v1/billing/checkout` → 503, UI shows "Pro billing is not
   yet activated." Recurring in sprints 13, 14, 15, 16 — i.e. **after**
   tonight's earlier billing-mode service-account-JWT fix (phronex-common PR
   #90) was reported "verified live." Needs investigation: either (a) that
   fix didn't actually resolve real checkout (only the poller's 403s), (b)
   there's an instance-specific config gap unique to `e2e-test-instance`
   that real customer instances don't have, or (c) a regression since. Not
   yet root-caused tonight — flagging for explicit follow-up, since it
   directly contradicts an earlier "verified live" claim.

3. **CC chat widget does not stay in character on off-topic / prompt
   injection probes** — asked an off-topic geography question with an
   embedded instruction to "tell a joke," the AI answered "The capital of
   France is Paris" and told an Eiffel Tower joke, fully complying with both
   the off-topic query and the injection. Recurring sprints 13, 14, 16 (in
   14 it recurred despite the execution itself succeeding — i.e. a pure
   behavioral/guardrail defect, not an infra flake). Real content-guardrail
   gap.

4. **CC chat widget never names a specific product** — asked to describe
   Phronex's offerings, the AI consistently gives a generic answer ("a range
   of innovative solutions," "workflow automation, data management, process
   optimization") without naming ContentCompanion, JobPortal, or any other
   product by name. Recurring in all 4 sprints. Downstream effect: journeys
   that depend on tracking "the first product name mentioned" for
   conversational continuity cannot proceed.

5. **"Re-index this source" button returns 404** —
   `/api/admin/cc/api/v1/admin/kb/{instance}/{source}/reindex`. Recurring
   sprints 14, 15, 16 (first seen differently-worded in 13's content-source
   findings). Button produces a bare "Not Found" with no loading state,
   toast, or progress indicator — content-source re-indexing is unusable
   from the admin UI.

## Single-sprint findings (sprint16, not yet cross-checked against earlier sprints)

6. **Analytics tab crash** — `TypeError: Cannot read properties of undefined
   (reading 'length')` in the superadmin dashboard's Analytics tab
   (`app/(dashboard)/cc/dashboard/page-*.js`). This is the same *class* of
   bug as already-fixed defect #251 (`Object.entries(null)` in the same
   dashboard area) — likely a different unguarded null/undefined access
   nearby that #251's fix didn't cover. Worth a follow-up sweep of the same
   component for other unguarded `.length`/`.entries`/`.map` accesses,
   similar to the RecentIssues envelope-mismatch sweep done tonight.

7. **BYOS skill card shows "Invalid Date"** — every skill's `Created` date
   renders as "Invalid Date." The `created_at` field is not being
   parsed/formatted correctly in the skill card component.

8. **No metrics/usage-summary UI surface on the Custom Skills page** — the
   USER-SPEC-documented metrics/usage view (`GET /metrics`,
   `GET /usage-summary`) is not implemented or not reachable from the
   current UI; no such requests fire during a session that should trigger
   them.

9. **USER-SPEC §18 "Known Limitations" feature is entirely absent** from the
   CC portal — not a persistence issue, the feature itself doesn't exist in
   the UI at all. Needs triage: never built, or removed, or the spec
   describes something aspirational that was never shipped.

## Sprint13-specific (not re-checked in later sprints, may already be
## covered by billing/product-name findings above, or may be separate)

10. **Command Centre accountability links form: HTTP 502** — both `GET` (on
    page load) and `POST` (on submission) to
    `/api/admin/command-centre/api/v1/accountability/links` return 502 Bad
    Gateway. "The backend service handling accountability links appears to
    be down or unreachable." Not re-observed in sprints 14-16 (may not have
    been exercised again, not necessarily fixed).

11. **HLD 4.1 Background Job Tracking doesn't work end-to-end** (sprint13):
    `/cc/jobs` returns 404 (no dedicated job-tracking UI), and
    `POST /api/admin/cc/api/v1/admin/ingest-url/{instance}` returns 503
    (URL-crawl background job creation unavailable).

12. **Custom Skills page shows a "BUG FOUND" banner** on load (sprint13) —
    exact detail truncated in the grep sweep; needs a look at the full raw
    log line in `overnight-runs/sprint13.log` if pursued.

---

## Not yet investigated tonight — recommend as next triage pass

Given items 1-5 are confirmed recurring across most/all of tonight's sprints,
they're the highest-value next targets: BYOS skill preview 500, billing
checkout 503 (re-emergence — see caveat above), chat guardrail/off-topic
compliance, chat product-naming, and content-source re-index 404.
