# Discuss With User

Items surfaced during autonomous overnight JourneyHawk sprints that need your
judgment before any fix — per the skill's autonomous-mode boundaries
(auth/billing changes, or anything an AuthorityMatrix classification would
flag as ESCALATE).

---

## 2026-07-18 — CC's billing-mode poller has never actually authenticated against phronex-auth

**Context:** Overnight Sprint 3 (salvage run), `cc-J10` (billing tier/upgrade journey) failed.

**Issue:** `contentcompanion/src/contentcompanion/lifespan.py` starts a background
poller (`start_billing_mode_refresh`, every 5 minutes) that calls
`GET {PHRONEX_AUTH_URL}/admin/billing-mode` with an `X-Admin-Secret` header
(shared-secret auth pattern). But the actual route in
`phronex-auth/src/phronex_auth/api/routes_admin_system.py` is gated by
`Depends(require_superadmin)`, which requires a real JWT
(`Authorization: Bearer <token>`) via `get_current_account` — there is no
shared-secret / `X-Admin-Secret` escape hatch on this route at all.

Confirmed live on EC2: this poller has been failing every single 5-minute
cycle with `403 Forbidden` (checked `journalctl -u contentcompanion`, see
repeated `_refresh_loop` tracebacks). Also confirmed `AUTH_ADMIN_SECRET` isn't
even set in CC's `.env` on EC2 (empty string default) — so even setting it
wouldn't fix this, since the route doesn't accept that auth mechanism at all.

**Likely consequence:** CC's billing_mode has probably never successfully
refreshed since this poller was added. `POST /api/v1/billing/checkout`
returned `503 Service Unavailable` in tonight's run (confirmed in EC2 logs,
same timestamp as the `cc-J10` failure) — very likely because billing_mode
can't determine a valid state and fails closed. This is a **safe failure
mode** (refuses checkout rather than risk wrong billing behavior), so no
customers were incorrectly charged — but real checkout may be broken for
real customers right now, which is the opposite problem: revenue-blocking,
not overcharging.

**Options (I'm not picking one — this is your call):**
1. Add a shared-secret auth path to phronex-auth's `/admin/billing-mode`
   route alongside `require_superadmin`, matching what CC's client already
   sends (`X-Admin-Secret`). Smallest change, but widens phronex-auth's
   admin surface with a second auth mechanism.
2. Change CC's `billing_mode_client.py` to obtain and use a real superadmin
   JWT (e.g., a dedicated service account, or reuse whatever mechanism CC's
   other admin-to-admin calls already use) instead of a shared secret.
   Larger change, but keeps phronex-auth's auth surface uniform.
3. Investigate whether this poller is even necessary — if CC's billing_mode
   rarely changes, maybe drop the 5-minute poll entirely in favor of an
   on-demand check or a longer interval, reducing the blast radius either way.

**Not touched:** I did not modify either repo's auth code. `AUTH_ADMIN_SECRET`
staying unset on EC2 is also unchanged — setting it wouldn't fix anything
given the route doesn't accept that mechanism, so I didn't want to leave a
red herring in the `.env`.

---

## 2026-07-18 — journey_generator LLM calls fail with 401 "invalid x-api-key" (OAuth token in wrong auth slot)

**Context:** Sprint 4, launched with `JOURNEYHAWK_SKIP_GENERATION=0` to grow journey breadth per tonight's goal.

**Issue:** `run-journeyhawk.sh` extracts the Claude Max OAuth access token from
`~/.claude/.credentials.json` (format `sk-ant-oat01-...`) and exports it as
`ANTHROPIC_API_KEY` before calling `journey_generator.py`, so
`phronex_common.llm` picks it up. But every LLM call failed with
`401 invalid x-api-key` (both STANDARD and CHEAP tiers, all retries) — the
whole generation step produced zero journeys, and the run reported
"Journeys run: 0" overall (nothing executed at all, not even the existing
10).

**Likely root cause:** OAuth access tokens and real Anthropic API keys are
different auth schemes. Real keys go in the `x-api-key` header; OAuth tokens
need `Authorization: Bearer <token>` instead. If `phronex_common.llm`'s
client always sends whatever's in `ANTHROPIC_API_KEY` via `x-api-key`
(standard `anthropic` Python SDK default), an OAuth token in that slot will
always be rejected — this may explain why the whole generation step
appears to have never worked with OAuth. `cc-test-runner` (the Claude Code
subprocess wrapper) can consume this correctly because Claude Code's own
SDK understands OAuth tokens; a raw `phronex_common.llm` → `anthropic`
SDK call likely doesn't.

**Not fixed:** this touches the shared, vendor-neutral LLM factory used by
every product (`phronex_common.llm`) — not something to change without full
context/review given it's genuinely shared infrastructure. Worked around by
running remaining sprints with `JOURNEYHAWK_SKIP_GENERATION=1` (regression
mode against the existing 10 journeys) so the loop keeps making progress on
real product bugs rather than repeatedly failing here. Journey breadth growth
is blocked until this is fixed.
