# Test Infrastructure Fix Plan — Journey Generation Gap

**Problem:** The automated pipeline produced 10 shallow journeys for ComC when 45+ deep journeys are obvious from reading the codebase. A human found them in 10 minutes.

**Root Cause:** The journey generation system (3 modules) exists in code but is NEVER called from the execution pipeline. The system treats the checked-in JSON spec as the single source of truth with no mechanism to discover or generate missing test scenarios.

---

## Architecture of the Gap

```
CURRENT FLOW (broken):
  run-journeyhawk.sh receives comc-journeys/comc-deep.json (10 static journeys)
      ↓
  Depth scorer warns "1 SMOKE, 2 SURFACE" → but runs them anyway
      ↓
  phronex-test-runner executes exactly those 10
      ↓
  Intelligence pipeline processes results (post-run only)

DESIRED FLOW (after fix):
  run-journeyhawk.sh invoked with product slug
      ↓
  [NEW] Route discovery: scan portal pages + backend endpoints → feature list
      ↓
  [NEW] Coverage gap analysis: features without journeys identified
      ↓
  [NEW] Spec generation: produce DEEP journeys for uncovered features
      ↓
  [NEW] Merge with existing specs (existing take precedence)
      ↓
  Depth enforcement: reject SMOKE, deepen SURFACE → minimum DEEP
      ↓
  phronex-test-runner executes full merged suite
      ↓
  Intelligence pipeline processes results
```

---

## Module Fix 1: Wire `spec_generator` into Pre-Run Pipeline

**File:** `phronex-common/src/phronex_common/testing/strategist/run_arbiter.py`  
**Also:** `phronex-test-runner/run-journeyhawk.sh` (step 0e)

**Current state:** `run-journeyhawk.sh` at step 0e only applies the run filter to the STATIC spec file. No generation occurs.

**Fix:** After the DocChain gate (step 0b) and before the run filter (step 0e), add a new step `0e-gen`:

```bash
[0e-gen/3] Journey generation (coverage gap fill)...
"${PYTHON}" -m phronex_common.testing.strategist.journey_generator \
  --product "${PRODUCT}" \
  --docs-dir "${_DOCS_DIR}" \
  --existing-spec "${SPEC_FILE}" \
  --output "/tmp/jh-generated-${PRODUCT}.json" \
  --max-journeys 50 \
  --min-depth DEEP
```

**New module:** `phronex_common/testing/strategist/journey_generator.py`  
**Responsibility:** Orchestrate the generation pipeline:
1. Call `coverage_analyzer.analyze_coverage()` with USER-SPEC.html
2. Call `route_discovery.discover_routes()` with portal + backend paths
3. Identify features WITHOUT journey coverage
4. Call `spec_generator.generate_specs()` for uncovered features
5. Merge generated specs with existing spec file
6. Write merged output to temp file

**Effort:** 8 hours  
**Dependencies:** Module Fixes 2, 3

---

## Module Fix 2: Route Discovery (NEW MODULE)

**File:** `phronex-common/src/phronex_common/testing/strategist/route_discovery.py`

**Purpose:** Automatically discover all testable surfaces by scanning actual code — not relying on documentation.

**Implementation:**

```python
def discover_routes(product_slug: str) -> list[DiscoveredRoute]:
    """Scan portal pages + backend endpoints to build a feature inventory."""
    
    portal_pages = _scan_portal_pages(product_slug)  # glob page.tsx files
    backend_endpoints = _scan_backend_routes(product_slug)  # parse route decorators
    
    return _correlate(portal_pages, backend_endpoints)

def _scan_portal_pages(product_slug: str) -> list[PortalPage]:
    """Find all page.tsx files under src/app/(dashboard)/{product}/"""
    # For ComC: glob phronex-portal/src/app/(dashboard)/command-centre/**/page.tsx
    # Extract: route path, component name, fetch() calls, form elements
    # Return: list of PortalPage(path, has_form, api_calls, buttons)

def _scan_backend_routes(product_slug: str) -> list[BackendEndpoint]:
    """Parse FastAPI route decorators from backend source."""
    # For ComC: parse all files in phronex-command-centre/src/command_centre/routes/
    # Extract: @router.get/post/patch/delete decorators, path, auth requirement
    # Return: list of BackendEndpoint(method, path, auth_type, request_model)

def _correlate(pages, endpoints) -> list[DiscoveredRoute]:
    """Match portal pages to their backend endpoints, flag orphans."""
    # Portal page with no matching backend = potential dead UI
    # Backend endpoint with no portal page = dark feature
    # Both present = testable feature → needs journey
```

**Key insight:** This is what the human did in 10 minutes — mentally correlated "52 portal pages" with "550 endpoints" and produced test scenarios. The module automates this.

**Effort:** 12 hours  
**Dependencies:** None (reads filesystem only)

---

## Module Fix 3: Coverage-Aware Spec Generation

**File:** `phronex-common/src/phronex_common/testing/spec_generator.py` (EXISTS but needs rewiring)

**Current state:** Has `generate_specs()` and `_deepen_single_spec()` but:
- Only called from `feedback_loop.py` (post-run remediation)
- Budget cap of $0.50/product limits extraction to ~40 sections
- Uses only USER-SPEC.html as input (misses route/page context)

**Fix:**

1. **Raise budget cap to $5.00/product** (line 83 in coverage_analyzer.py)
2. **Accept route_discovery output as additional context:**
   ```python
   def generate_specs(
       product_slug: str,
       uncovered_features: list[Feature],
       discovered_routes: list[DiscoveredRoute],  # NEW
       existing_specs: list[JourneySpec],
       max_journeys: int = 50,
   ) -> list[JourneySpec]:
   ```
3. **Generate journeys per discovered route, not per USER-SPEC paragraph:**
   - Each portal page with a form → CRUD journey
   - Each portal page with a list → list + filter journey
   - Each integration endpoint (Paperclip, ERPNext) → E2E chain journey
4. **Enforce DEEP minimum:**
   - Every generated journey must have ≥3 steps
   - Must include "navigate away + return + verify persistence" pattern
   - Must include specific URLs, field labels, expected values

**Effort:** 6 hours  
**Dependencies:** Module Fix 2 (route discovery)

---

## Module Fix 4: Depth Enforcement Gate (Pre-Run Reject)

**File:** `phronex-test-runner/run-journeyhawk.sh` (step 0d)  
**Also:** `phronex-common/src/phronex_common/testing/strategist/depth_scorer.py`

**Current state:** Depth scorer classifies journeys as SMOKE/SURFACE/DEEP/BEHAVIORAL, but decision D-01 says "warn only, don't reject."

**Fix:** Change D-01 from advisory to enforcing:

```bash
# BEFORE (current):
print(f'  WARNING: {len(smoke)} SMOKE journeys (shallow, should be enriched): {smoke}')

# AFTER (fix):
if smoke and not os.environ.get("JH_ALLOW_SMOKE"):
    # Attempt auto-deepening via LLM
    deepened = await deepen_batch(smoke, product_slug, docs_dir)
    if deepened:
        merged_spec.extend(deepened)
        print(f'  DEEPENED: {len(deepened)} SMOKE → DEEP journeys via auto-enrichment')
    else:
        print(f'  DROPPED: {len(smoke)} SMOKE journeys (could not deepen)')
        # Remove from run list
```

**Gate behavior:**
- SMOKE → attempt auto-deepen → if fails, DROP from run
- SURFACE → attempt auto-deepen → if fails, FLAG but still run
- DEEP/BEHAVIORAL → run as-is

**Override:** `JH_ALLOW_SMOKE=1` env var for legacy/debugging

**Effort:** 4 hours  
**Dependencies:** Module Fix 3 (spec_generator for deepening)

---

## Module Fix 5: DocChain Structured Attributes (Upstream Fix)

**File:** `phronex-command-centre/.docs/USER-SPEC.html`  
**Also:** DocChain generation skill (`Phronex_Internal_Product_DocChain`)

**Current state:** USER-SPEC.html is 670 lines of unstructured prose. The `from_userspec()` parser looks for `<section data-journey="name">` and `<li data-step="action:target">` attributes that DON'T EXIST.

**Fix:** Two options:

**Option A (short-term):** Add `data-journey` attributes to existing USER-SPEC.html manually:
```html
<!-- Before -->
<section id="vendor-subscriptions">
  <h3>Vendor Subscriptions</h3>
  <p>Track recurring SaaS costs...</p>
</section>

<!-- After -->
<section id="vendor-subscriptions" data-journey="comc-vendor-sub-crud" data-pillar="Operations">
  <h3>Vendor Subscriptions</h3>
  <p>Track recurring SaaS costs...</p>
  <ul data-steps>
    <li data-step="navigate:/command-centre/vendor-subscriptions">View subscription list</li>
    <li data-step="click:Add Subscription">Open creation form</li>
    <li data-step="fill:Name,Category,Monthly Cost,Billing Cycle,Renewal Date,Payment Method">Fill all fields</li>
    <li data-step="verify:list contains new entry">Verify creation succeeded</li>
  </ul>
</section>
```

**Option B (medium-term):** Update DocChain skill to auto-generate `data-journey` attributes when running backward reconciliation. The skill already reads the codebase — it should annotate USER-SPEC sections with journey metadata.

**Effort:** Option A = 4 hours (manual), Option B = 16 hours (skill update)  
**Dependencies:** None

---

## Module Fix 6: TEST-ORACLES.html Population

**File:** `phronex-command-centre/.docs/TEST-ORACLES.html`

**Current state:** 125 lines, 8 empty stubs with comments saying "add step-level oracle rows here."

**Fix:** Populate with actual oracle expectations. Each feature section needs:

```html
<section data-journey-id="comc-vendor-sub-crud">
  <h3>Vendor Subscription CRUD</h3>
  <table>
    <thead><tr><th>Step</th><th>Precondition</th><th>Action</th><th>Expected</th><th>Failure Mode</th></tr></thead>
    <tbody>
      <tr>
        <td>1</td>
        <td>Logged in as owner, ComC grant with premium tier</td>
        <td>Navigate to /command-centre/vendor-subscriptions</td>
        <td>Page loads, "Add Subscription" button visible</td>
        <td>403 = missing grant; blank page = JS error</td>
      </tr>
      <tr>
        <td>2</td>
        <td>On vendor-subscriptions page</td>
        <td>Click "Add Subscription", fill all 6 fields, submit</td>
        <td>201 response, entry appears in list with correct values</td>
        <td>422 = field validation; 500 = backend crash</td>
      </tr>
    </tbody>
  </table>
</section>
```

This gives the `spec_generator` precondition context (what auth/data is needed) and failure classification (so the pipeline knows when a 422 is a real bug vs missing test fixture).

**Effort:** 8 hours for full ComC coverage (45 features × ~3 steps each)  
**Dependencies:** None, but most useful when Module Fix 3 is wired

---

## Priority Order

| Priority | Fix | Effort | Impact |
|----------|-----|--------|--------|
| P0 | Fix 1: Wire spec_generator into pipeline | 8h | Enables all other fixes |
| P0 | Fix 2: Route discovery module | 12h | Eliminates "human reads code" step |
| P1 | Fix 4: Depth enforcement gate | 4h | Prevents shallow specs from running |
| P1 | Fix 3: Coverage-aware generation | 6h | Produces DEEP specs automatically |
| P2 | Fix 5: DocChain structured attributes | 4-16h | Improves from_userspec() parser |
| P2 | Fix 6: TEST-ORACLES population | 8h | Adds precondition context |

**Total effort:** 42-54 hours across all fixes  
**Minimum viable fix (P0 only):** 20 hours → gets us from 10 shallow to 40+ deep journeys

---

## Success Criteria

After implementing P0 + P1 fixes:
- Running `run-journeyhawk.sh comc` with NO pre-existing spec file should:
  1. Discover 52 portal pages + 550 backend endpoints
  2. Generate ≥40 DEEP journeys covering all 7 pillars
  3. Reject any SMOKE-level specs
  4. Produce pass/fail results for each
- The system should never again require manual spec authoring for basic feature coverage

---

## Why This Matters Beyond ComC

This same gap exists for ALL products:
- JP has 26 journeys (manually authored) — likely missing 20+
- CC has 15 journeys — likely missing 15+
- Portal has 8 journeys — likely missing 30+

The route discovery module (Fix 2) works for ANY product in the registry. Once implemented, every product gets comprehensive coverage automatically.
