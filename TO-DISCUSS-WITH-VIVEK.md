# To Discuss With Vivek — JourneyHawk ComC Run Decisions

> Maintained during the autonomous ComC JourneyHawk run (2026-05-06).
> Items that require fundamental design input, not just a code fix.
> Operator: review before the next session and resolve or defer each item.

---

## D-01: ComC has no QA cleanup endpoint — test data accumulates

**Context:** ComC has no `POST /qa/cleanup` SDK route equivalent to CC/JP. Test data created during journey runs (initiatives, CRM contacts, meetings, vendor subscriptions, etc.) persists in the DevServer ComC database between runs.

**Impact:** Journey steps that say "verify no duplicate exists" or "verify count is 0" will fail on run 2+ because run 1 left data behind.

**Options:**
1. **Add a QA cleanup endpoint to ComC** — mirroring CC's cleanup SDK route. Gated by `PHRONEX_QA_ALLOWED_HOSTS` env var. Cleanest solution; consistent with other products. ~1h work.
2. **Use timestamp-namespaced test data** — journey steps create "JH-Test-{ISO-date}-Initiative" etc. so each run uses unique names. Avoids cleanup need but complicates verification steps. Already partially done in spec.
3. **Wipe test data via DB directly from run-journeyhawk.sh** — add a `psql` cleanup step at start of run that deletes rows with JH-Test prefix. Fragile; bypasses application logic.

**Recommendation:** Option 1. Document as a phase in the next ComC milestone.

**Decision needed by:** Before ComC Run 2.

---

## D-02: ComC portal routes vs backend URL map — needs verification

**Context:** The 45 static journey specs navigate to `/comc/*` portal routes. These are currently untested. The portal's ComC section may have different route paths, tab names, or missing sections compared to what the spec expects.

**Specific uncertainties:**
- Does `/comc/pulse` map to the dashboard? Or is it `/comc/dashboard`?
- Is `/comc/strategy/ip-register` a real portal route? 
- Does `/comc/settings/llm-credentials` exist?
- What happens on `/comc/autoresearch` — is this a portal page or backend-only?

**Impact:** Many journeys will fail on step 1 if routes are wrong. This is expected on a first run — the run will surface the right routes. But we should document them systematically rather than patch one by one.

**Recommendation:** Run the full suite once (accepting failures), then update the spec with correct routes in a single batch. After run 1, add a "Portal Route Map" table to this document.

**Decision needed by:** After Run 1 results are available.

---

## D-03: ComC trunk saves superadmin session — no QA-specific non-admin user provisioned

**Context:** The trunk journey `comc-trunk-superadmin` logs in as the Phronex superadmin (`qa-test-journeyhawk@phronex.com` with full admin access). This is the ONLY account provisioned for ComC. All leaf journeys inherit superadmin state.

**Impact:** We cannot test:
- Regular ComC org-user flows (non-admin access)
- Role-based access control (e.g. is a Sales rep blocked from Strategy features?)
- Org isolation (two orgs shouldn't see each other's initiatives)

**Options:**
1. **Create a non-admin ComC test account** via phronex-auth's admin console — provision a second test user with `command-centre` premium grant but `is_superadmin = false`.
2. **Accept superadmin-only for now** — we're still verifying features exist and render correctly. Role-based testing is a v2 concern.

**Recommendation:** Option 2 for now; create Option 1 account before Run 3 so it's ready when feature correctness is confirmed.

**Decision needed by:** Before Run 3.

---

## D-04: `rate_limit_exempt` flag — should JourneyHawk skill enforce this at provision time?

**Context:** The `phronex-auth.accounts.rate_limit_exempt` column must be `true` for any QA account to avoid login rate-limit failures across runs. Currently this is a manual one-time step.

**Gap:** The JourneyHawk skill's PHASE 1 (Intelligence Load) queries `qa_known_defects` and wiki articles, but does NOT verify QA account provisioning state including `rate_limit_exempt`. A new machine or a new QA account would silently fail on run 1.

**Recommendation:** Add a Phase 1 sub-step to check `rate_limit_exempt` for the configured portal email:
```sql
SELECT rate_limit_exempt FROM accounts WHERE email = '{portal_email}'
```
If `false` → log a WARNING in the Intelligence Load summary and auto-set it (or ask operator to set it).

**Requires:** Update to `Phronex_Internal_QA_JourneyHawk/SKILL.md` via `/Phronex_Builder_Dev_SkillBuilder`. Not implemented here (SkillBuilder gate applies).

**Decision needed by:** Before this becomes a pain point on a new machine.

---

## D-05: `flow_extractor.py` and `business_journey_generator.py` — IMPLEMENTED (2026-05-06)

**Status:** RESOLVED — both modules are now implemented and active.

- `business_journey_generator.py` — LLM-driven cross-feature, deep, and security journey generation is implemented and running in the pipeline (Runs 11-13).
- `flow_extractor.py` — implemented and integrated into `journey_generator.py` pipeline.

**Current known issues (being fixed in Runs 13-14):**
- Business journeys used wrong URL (`comc.phronex.com` vs `app.phronex.com/command-centre`) — fixed in commit `be7acc96`
- State-loading step was ambiguous ("click login OR load state") — fixed in commit `e967454e`
- `dependsOn` key naming conflict (snake_case vs camelCase) — fixed in commit `11484fb0`

**No decision needed — implementation complete, iterating.**

---

## D-06: ComC DevServer-only vs EC2 deployment — journey spec URL assumptions

**Context:** ComC runs exclusively on DevServer (`localhost:8004`). The portal at `localhost:3002` proxies ComC API calls to `localhost:8004`. This means ComC journeys are implicitly tied to DevServer and cannot be run from any other machine.

**Impact:** The JourneyHawk skill currently supports running the portal against `app.phronex.com` (EC2) by setting `PORTAL_URL` in `.qa.env`. For ComC, the portal would need to be the DevServer portal, and the ComC backend would be DevServer-only.

**Questions for Vivek:**
1. When ComC is eventually deployed to EC2/production, will `run-journeyhawk.sh` need a `COMC_URL` override similar to `PHRONEX_COMC_TEST_URL=http://localhost:8004`?
2. Should ComC journeys use `PORTAL_URL=http://localhost:3002` hardcoded (never EC2), or should it respect the global `PORTAL_URL` setting?

**Current state:** `PHRONEX_COMC_TEST_URL=http://localhost:8004` is set in `.qa.env`. The portal at `localhost:3002` proxies to this. Works correctly today. Will break when ComC moves to EC2.

**Decision needed by:** When ComC moves to production EC2.

---

## D-07: Generated business journeys not persisted — regenerated fresh every run

**Context:** The business journey generator produces 21 cross-feature E2E + 20 deep feature + N security journeys via LLM calls during the pre-flight `[0b-gen/3]` phase. These are **not** written back to `comc-deep.json`. Every run starts from the 45 static journeys and regenerates all business journeys from scratch.

**Impact:** 
1. **Pre-flight cost:** 41 LLM calls per run × 35s inter-call sleep = ~24 min minimum generation time when calls succeed. When rate-limited (5 attempts × 30s each), worst case is ~100 min of generation before cc-test-runner starts executing journeys.
2. **Wasted compute:** Runs 13-15 each re-generated the same 37 business journeys identically. 
3. **Rate limit amplification:** Sustained runs in the same day exhaust OAuth token quota during generation, not during testing.

**Proposed fix:** At the end of each `[0b-gen/3]` phase, write the merged spec (static + generated) back to `comc-deep.json` (or a `comc-deep-generated.json` alongside it). On the next run, the generator sees 82 existing journeys, skips LLM generation for already-covered IDs, and starts cc-test-runner immediately.

**Trade-off:** Generated journeys become "sticky" — the generator would need logic to replace stale business journeys when DocChain changes. A simple approach: regenerate only if `delta.user_spec_changed` (already computed in the DocChain delta step).

**Decision needed by:** Before Run 16 if rate limits continue to be a problem.

---

*Last updated: 2026-05-06 (Run 15 pre-flight — sustained rate limiting during business journey generation)*
