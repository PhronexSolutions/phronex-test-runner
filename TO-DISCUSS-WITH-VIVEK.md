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

## D-05: `flow_extractor.py` and `business_journey_generator.py` — planned modules not yet built

**Context:** The active plan (`proud-waddling-goblet.md`) describes two new modules:
- `flow_extractor.py` — extracts structured user flows from DocChain artefacts (oracle tables, explicit flows, data-step flows, inferred flows)
- `business_journey_generator.py` — LLM-driven E2E cross-feature + security journey generation

These are NOT yet implemented. The current pipeline generates 39 surface-level journeys from route discovery; it does NOT generate business-logic or security journeys.

**Impact on ComC Run 1:** 45 static + 39 LLM-enriched surface = 84 total. The plan target of "76 + 29 LLM enriched" was based on a pre-`--code-root` count. With `--code-root` fixed, the actual count is ~84.

The 44 oracle tables in ComC's `TEST-ORACLES.html` are NOT yet being used to drive journey steps. This is the most significant gap in current QA depth.

**Recommendation:** Implement `flow_extractor.py` and `business_journey_generator.py` after Run 1 establishes a surface-level baseline. Run 1 findings will inform which features need deep business-logic journeys first.

**Decision needed by:** After Run 1. Scope into next phronex-common milestone.

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

*Last updated: 2026-05-06 (Run 1 pre-flight)*
