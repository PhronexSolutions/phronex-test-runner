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

## D-02: ComC portal routes vs backend URL map — RESOLVED (2026-05-06)

**Status:** RESOLVED — all 4 questioned routes exist in the portal (51 ComC pages confirmed). URL prefix was `/command-centre/`, not `/comc/`. Fixed in commit `be7acc96`.

| Spec assumed | Actual portal route | Exists? |
|---|---|---|
| `/comc/pulse` | `/command-centre/dashboard` | Yes |
| `/comc/strategy/ip-register` | `/command-centre/strategy/ip-register` | Yes |
| `/comc/settings/llm-credentials` | `/command-centre/settings/llm-credentials` | Yes |
| `/comc/autoresearch` | `/command-centre/autoresearch` | Yes |

**No decision needed.**

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

## D-04: `rate_limit_exempt` flag — RESOLVED (2026-05-06)

**Status:** RESOLVED — Step 1e (QA Account Provisioning Check) added to JourneyHawk SKILL.md PHASE 1.

The new step queries phronex-auth admin API (`GET /admin/accounts?email={email}`) to verify:
1. Account exists
2. `rate_limit_exempt = true`

Implemented as a WARNING gate (not HALT) — surfaces clear diagnostic messages when
the account is missing or rate-limit-exempt is false. Integrated into Step 1d summary
display. Uses the auth token from the login pre-check already performed by `run-journeyhawk.sh`.

**No decision needed.**

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

## D-07: Generated business journeys not persisted — RESOLVED (2026-05-06)

**Status:** RESOLVED — spec persistence + forensic trail implemented (commits `e4dfb907`, `e2874f2d` in phronex-common; `06b33da` in phronex-test-runner).

**Solution shipped:**
- `phronex_common/testing/spec_persistence.py` — new module with:
  - SHA256-based cache: `comc-deep.json` → `comc-deep.generated.json` alongside static spec
  - `qa_journey_spec_provenance` table (migration 0034): stores per-run doc SHA256s + journey IDs
  - `load_cached_spec()`: on cache hit (all docs unchanged), skips entire LLM pipeline (~0 min vs ~24 min)
  - `save_spec_with_provenance()`: writes cache + forensic provenance row after each generation
  - `assess_doc_quality()`: LLM-based document adequacy check (replaces the 5KB size threshold in SKILL.md PHASE 0)
- `journey_generator.py`: wired in cache check at Step 1b (before any route discovery), provenance save at Step 6b
- `run-journeyhawk.sh`: passes `--base-spec SPEC_FILE` + `--db-url` to generator

**Run 15 will write the first provenance row.** Run 16+ will get cache hits when ComC `.docs/` is unchanged — generation completes in ~0 seconds. When DocChain produces a new doc version (different SHA256), only the changed document's affected journeys are regenerated.

**No decision needed.**

---

*Last updated: 2026-05-06 (D-02 + D-04 resolved; D-07 added during Run 15 and resolved same session)*
