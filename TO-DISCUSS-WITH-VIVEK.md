# To Discuss With Vivek — JourneyHawk ComC Run Decisions

> Maintained during the autonomous ComC JourneyHawk run (2026-05-06).
> Items that require fundamental design input, not just a code fix.
> Operator: review before the next session and resolve or defer each item.

---

## D-01: ComC has no QA cleanup endpoint — RESOLVED (2026-05-06)

**Status:** RESOLVED — `POST /api/admin/test-cleanup/{resource}` implemented in ComC.

**Solution:** Option 1 implemented. Endpoint mirrors CC's pattern exactly:
- Auth: `X-SDK-Key` (reuses existing `qa_sink_sdk_key`)
- Production hostname guard: `comc.phronex.com`
- 4 resources: `initiatives`, `contacts` (cascades to interactions), `meetings`, `vendor-subscriptions`
- Safety filters: `name/title LIKE 'JH-%'` + 24h window (where `created_at` available)

**No decision needed.**

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

*Last updated: 2026-05-11 (JP Run 7 overnight autonomous session added)*

---

## CC-06: CC cleanup endpoint 403 — production hostname guard blocks EC2 cleanup (2026-05-11)

**What:** `POST /api/admin/test-cleanup/{resource}` returns HTTP 403 because the endpoint's Gate 2 (production hostname guard) fires when the request arrives at `cc.phronex.com` via the public URL. The guard is intentional — it prevents accidental deletion on production. But CC has no DevServer instance, so there's no bypass URL available.

**Root cause:** `run-journeyhawk.sh` sends cleanup requests to `CC_CLEANUP_URL=https://cc.phronex.com` (EC2). Nginx proxies the request preserving `Host: cc.phronex.com`. The route handler checks `request.headers.get("host")` and matches `_PRODUCTION_HOST = "cc.phronex.com"` → raises 403.

**Options:**
- A) Add `PHRONEX_CC_TEST_CLEANUP_BYPASS_HOST` env var — runner passes `X-Forwarded-Host: qa-internal` header; route checks that instead. Risk: header injection — must validate the bypass header against a secret.
- B) Run CC locally on DevServer (port 8000) for cleanup-only calls. Cleaner but adds infra complexity.
- C) Remove the hostname guard from CC entirely — it was a defence-in-depth measure for when EC2 production and a test instance coexist. Since CC only runs on EC2 (no DevServer instance), the guard achieves nothing and only blocks QA cleanup.
- D) Accept the 403 as a warning — cleanup is not critical for test correctness, only for DB hygiene. The 24h window filter already prevents data leakage between runs.

**Recommendation:** Option C (remove the guard) or Option D (accept). The guard was designed for a DevServer/EC2 dual-environment setup that doesn't exist for CC. CC is EC2-only so the guard provides zero protection.

**Decision needed:** Before next CC cleanup-reliant run.

---

## CC-01: EC2 deploy needed for IDOR fix + portal users filter (2026-05-11)

**What:** Two commits need an EC2 deploy to go live:
1. CC `38617a1` — IDOR fix on `/api/v1/config/usage` (security)
2. Portal `8e35075` — source filter in CC users panel + anonymous users now visible

**Action needed:** Run EC2 deploy for `contentcompanion` and `phronex-portal` at next opportunity.
No Alembic migrations required — API-only change.

---

## CC-02: cc-data-* journeys evicted as Class 5 garbage (2026-05-11)

**What:** 5 `cc-data-*` journeys (DB foreign key checks) were automatically evicted by the
static spec garbage scanner as "no navigable URL in any step". These ARE legitimate tests
but require direct PostgreSQL access, not a browser.

**Options:**
- A) Add `"runner": "db"` field — pre-flight filter skips them silently without eviction
- B) Move to `cc-db-checks.json` separate spec for a future non-browser runner
- C) Accept eviction — they were always SKIP journeys anyway (marked with "SKIP" in description)

**Recommendation:** Option A is lowest effort. Modify `_is_garbage_journey()` to skip Class 5
check when `journey.get('runner') == 'db'`. No cost.

---

## CC-03: ComC journey IDs appearing in CC Run 6 spec mutation — RESOLVED (2026-05-11)

**What:** Run 6 log shows `comc-*` journey IDs in the CC-scoped mutated spec
(`/tmp/jh-spec-mutated-*.json`). The strategist spec mutator is not filtering by product.
These journeys all failed (CC app ≠ ComC), inflating failure stats.

**Fixed:** Added product-slug prefix guard to `run_filter.py` — any journey ID that doesn't
start with `{product_slug}-` is dropped with reason_code `PRODUCT_MISMATCH`. isSharedRoot
trunks are exempt. Commit: `52381568` in phronex-common. Tests: 14 run_filter tests pass.

**No decision needed.**

---

## CC-04: auth/identify accepts malformed emails — #960 (2026-05-11)

**What:** phronex-auth `/auth/identify` accepts any string as email without validation.
Fix: add `email: EmailStr` to request body Pydantic model.

**Risk:** May break callers that pass non-RFC-5322 formats intentionally.
Confirm no such callers exist before applying. Severity: LOW.

---

## CC-05: Sessions tab rows not clickable — #958 (2026-05-11)

**What:** Sessions tab in CC portal shows rows but clicking does nothing. No drill-down
navigation implemented. Needs portal scoping.

**Action needed:** Add to next portal milestone backlog.

---

## JP-01 through JP-NN: Items from overnight JP Run 7 (2026-05-11)

> Items below are added during the autonomous overnight JP JourneyHawk run.
> Only cost implications or human-judgment items are logged here.

---

## JP-01: JP cleanup endpoint 403 — same class as CC-06 (2026-05-11)

**What:** `POST /api/admin/test-cleanup/{resource}` returns HTTP 403 for JP (`jobc.phronex.com`).
Same production hostname guard issue as CC-06. JP has no DevServer instance either.

**Impact:** Non-fatal — pre-run cleanup is skipped, test data accumulates. The `name LIKE 'JH-%'`
filter + 24h window prevents cross-run interference regardless.

**Action needed:** Same resolution as CC-06. Batch both together.

---

## JP-02: `claude -p` returns explanatory prose instead of JSON — FIXED (2026-05-11)

**What:** `ClaudeOAuthSubprocessProvider.extract_structured()` was receiving `★ Insight` blocks
and analysis text instead of JSON because `claude -p` inherits the user's Claude Code "explanatory
output style" setting. Every LLM enrichment call failed with `JSONDecodeError`, causing all 53
generated journeys to fall back to heuristic (unmodified specs = zero enrichment).

**Fix applied:** Commit `9a6da9e4` in phronex-common:
1. Prepend explicit JSON-only directive to system prompt (overrides style settings)
2. Add regex JSON object extraction as recovery for responses that still wrap JSON in prose

**No decision needed — fix shipped and pushed.**

---

## D-13: Trunk login fails when EC2 is down — leaf journeys still pass via saved session

**What happened in run7:** The trunk (`comc-trunk-superadmin`) failed at the login step because `AUTH_API_URL=https://auth.phronex.com` — the portal validates credentials against EC2 phronex-auth, which is currently unreachable. However, all 10+ leaf journeys PASSED by loading the saved session from run6's state file (`comc-trunk-superadmin-state.json`, valid 715 hours).

**This is working as designed.** The saved state file acts as a credential cache. The trunk's single failure does not cascade to leaf journeys because each leaf has "Load saved session OR log in" as its first step.

**However:** The trunk failure IS recorded as a BROKEN verdict in `qa_journey_verdicts`, which will eventually affect the `qa_confidence_scores` for `comc-trunk-superadmin`. After 5+ BROKEN runs, the curator might attempt to retire the trunk (though the `isSharedRoot` guard in `spec_curator.py` now prevents that).

**Architectural question:** Should the trunk's verdict account for EC2 availability? If `auth.phronex.com` is unreachable, the trunk login failure is a test infrastructure issue, not a product bug. Options:
- A) Add EC2 reachability check at trunk start — if unreachable, mark as SKIP rather than FAIL
- B) Add a local phronex-auth fallback URL (e.g., `AUTH_API_URL_LOCAL=http://localhost:8002`) for DevServer-only runs
- C) Accept the current behaviour — EC2 outages are rare, trunk false-fails are self-healing when EC2 recovers

**Current state:** EC2 is down. Run7 trunk failed. Leaf journeys all passing via saved state. No action needed for run7 to complete successfully.

---

## D-08: Canonical URL for spec files — `localhost:3002` vs `app.phronex.com`

**Context:** EC2 portal went down (502) during autonomous run. Switched `PORTAL_URL=http://localhost:3002` in `.qa.env` and manually patched 230 step descriptions in `comc-deep.json` + `comc-deep.generated.json` from `https://app.phronex.com` → `http://localhost:3002`.

**The `run-journeyhawk.sh` sed substitution** only goes one direction: replaces `localhost:3002` → `$PORTAL_URL` at runtime. So if specs have `app.phronex.com` baked in and `PORTAL_URL=http://localhost:3002`, the substitution misses them.

**Current state:** Specs have `localhost:3002` as canonical. This works for DevServer QA. When EC2 recovers, setting `PORTAL_URL=https://app.phronex.com` in `.qa.env` will cause run-journeyhawk.sh to replace `localhost:3002` → `https://app.phronex.com` in the temp merged spec at runtime. Should work without touching the spec files again.

**Decision needed:** Confirm that `localhost:3002` is the right canonical for spec files long-term. If yes, no action needed — current state is correct.

---

## D-09: Generated journeys calling backend API directly — false positives

**What happened:** ~33 generated journeys (`comc-deep-*`, `comc-biz-*`, `comc-hld-*`, `comc-architecture-*`, `comc-sec-*`) fail with 401/404 because they try to call `http://localhost:8004/api/v1/...` directly using portal Auth.js cookies. Auth.js JWE cookies are not valid Bearer JWTs for the ComC API.

**Root cause:** The journey generator is given ARCHITECTURE.html and HLD docs as inputs, and generates journeys that test backend API contracts. These are integration tests, not browser E2E tests — they require a phronex-auth Bearer JWT, not a portal session.

**Recommendation:** Modify the journey generator prompt to explicitly prohibit generating steps that call backend URLs (`localhost:8004`) directly. All steps must navigate the portal UI at the portal URL. Backend behaviour is verified indirectly through the portal's proxy calls.

**Decision needed:** Approval to modify journey generator prompt constraints. This will reduce generated journey count by ~30-40 but eliminate the false-positive class entirely.

---

## D-10: Depth gate dropping static-spec journeys due to deepener bug

**What happened:** 19 of 45 static-spec journeys are classified SMOKE and dropped before running. The deepener fails with: `AnthropicProvider.chat() missing 1 required positional argument: 'messages'`. These journeys stay SMOKE → depth gate drops them.

**Affected:** `comc-config-*`, `comc-rbac-*`, `comc-people-*`, `comc-ops-costs-*` — core admin/config flows. They have never been tested in 6 runs.

**Recommendation:** Depth gate should skip SMOKE-drop for static-spec journeys (those in `comc-deep.json` original file, not `.generated.json`). Also fix the `AnthropicProvider.chat()` signature bug.

**Decision needed:** Approval to modify depth gate to always run static-spec journeys regardless of SMOKE classification.

---

## D-11: Heartbeat SQL bug — `entity_memory = :data::jsonb` asyncpg incompatibility — RESOLVED

**Status:** RESOLVED — fix already applied in phronex-common v0.17.3 (`db_store.py` lines 166, 194).

**Fix:** Replaced `:data::jsonb` with `cast(:data as jsonb)` in `PostgresMemoryStore.write_memory()` and `write_brain()`. The `cast()` SQL function avoids asyncpg's colon-collision parser issue entirely. ComC service restarted 2026-05-09 14:30 with the fix live.

**No decision needed.**

---

## D-12: `cc_vendor_subscriptions` table was missing — fixed via new migration

**What happened:** Migration `38de564e35af` (add org_contacts tables) dropped `cc_vendor_subscriptions` in its `upgrade()` function without recreating it. The table had been created by an earlier migration (`996dc8aa8410`) but was accidentally dropped.

**Fixed:** New migration `5048125bf9ba` restores the table. Applied to DevServer DB 2026-05-07. ComC restarted — vendor subscription POST now works.

**Action needed:** When this migration is deployed to production (when ComC goes to EC2), it will apply automatically via `alembic upgrade head`. No special action required. Just noting for awareness.

---

## D-14: CC lead form Export CSV is a dark feature — backend route missing (2026-05-11)

**What:** `LeadFormClient.tsx` (portal) has an "Export CSV" button at lines 227-251 that calls `POST /api/admin/cc/api/v1/lead-form/submissions/export`. This goes through the Next.js proxy to the CC backend. The CC backend has **no such route** in `routes_admin_instances.py` — the lead form section only has field list/create/patch/delete (`/lead-form/fields/*`). There is no submissions storage, no submissions list, and no CSV export endpoint.

**Root cause:** The export button was built into the portal UI without a corresponding backend implementation. Lead form responses in CC are not currently stored in the database at all — they go to... nowhere? The config-backed lead form stores field *definitions* in YAML, but field *submissions* have no persistence layer.

**Impact:** Any CC instance admin clicking Export CSV gets a 404 (surfaced as a network error in the portal). This is a silent failure — no error toast, just a failed download.

**This is a dark feature — NOT implementing autonomously.** Implementing submission storage requires:
1. A new `cc_lead_form_submissions` DB table (Alembic migration)
2. A CC route to receive webhook submissions and store them
3. The export CSV endpoint itself
4. Possibly a submissions list view in the portal

**Decision needed:**
- A) Scope into the next CC milestone — implement submissions storage + export
- B) Disable the Export CSV button in the portal until the backend is ready (1-line change in `LeadFormClient.tsx`)
- C) Accept the dark feature — button exists but is non-functional

**Recommendation:** Option B short-term (remove false affordance), Option A mid-term. The button creating a silent 404 is a UX defect.
