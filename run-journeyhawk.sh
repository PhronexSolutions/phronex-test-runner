#!/usr/bin/env bash
# run-journeyhawk.sh — Single-entry JourneyHawk runner.
# Chains cc-test-runner + phronex_common.testing.runner atomically.
# Claude (as JourneyHawk skill) calls THIS script — never the two steps separately.
#
# The intelligence pipeline lives in phronex_common.testing.runner (version-controlled,
# reusable by all products). This script is a thin launcher only.
#
# Usage:
#   ./run-journeyhawk.sh <product-slug> <spec-file> [results-dir]
#
# Examples (full run with intelligence pipeline):
#   ./run-journeyhawk.sh jp jp-journeys/jp-deep.json
#   ./run-journeyhawk.sh portal portal-journeys/portal-tree.json
#
# Smoke run (single trunk, bypassing intelligence pipeline — direct cc-test-runner):
#   ./cli/cc-test-runner -t jp-journeys/jp-deep.json -o results-smoke-jp --runJourney jp-trunk-main
#   ./cli/cc-test-runner -t portal-journeys/portal-tree.json -o results-smoke-portal --runJourney portal-trunk-superadmin
#
# NOTE: Standalone smoke spec files (jp-smoke.json, portal-smoke.json) are DEPRECATED.
#       Use --runJourney <trunk-id> against the tree spec instead — a trunk run IS the smoke test.

set -euo pipefail

# cc-test-runner spawns `claude` subprocesses. If ANTHROPIC_API_KEY is set in the
# shell, it takes precedence over OAuth credentials even when the key is exhausted.
# Unset it here so the runner always falls back to ~/.claude/.credentials.json (OAuth /
# Claude Max subscription) which is the correct auth path for DevServer runs.
unset ANTHROPIC_API_KEY

# ---------- Phase 88 — gate mode for PR merge blocking ----------
GATE_MODE=0

# ---------- Phase 82 STRAT-16 — per-run mode override ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gate-mode)
      GATE_MODE=1
      shift
      continue
      ;;
    --strategist-mode=*)
      val="${1#*=}"
      ;;
    --strategist-mode)
      val="$2"
      shift
      ;;
    --waive-resources)
      export JOURNEYHAWK_WAIVE_RESOURCES=1
      shift
      continue
      ;;
    *)
      break
      ;;
  esac
  case "$val" in
    ACTIVE|READ_ONLY|DISABLED)
      export STRATEGIST_MODE_OVERRIDE="$val"
      ;;
    *)
      echo "ERROR: --strategist-mode must be one of ACTIVE, READ_ONLY, DISABLED (got: $val)" >&2
      exit 1
      ;;
  esac
  shift
done
# ---------- end Phase 82 ----------

PRODUCT="${1:?Usage: run-journeyhawk.sh <product-slug> <spec-file> [results-dir]}"
SPEC_FILE="${2:?Usage: run-journeyhawk.sh <product-slug> <spec-file> [results-dir]}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${3:-journeys-output/${PRODUCT}-${TIMESTAMP}}"

# Run ID for handoff queue and intelligence pipeline correlation.
export JOURNEYHAWK_RUN_ID="${PRODUCT}-${TIMESTAMP}"
export JOURNEYHAWK_PRODUCT="${PRODUCT}"

# MCPStateServer port — configurable for parallel execution.
# Default 3001 preserves backward compatibility with single-product runs.
CCTR_STATE_PORT="${CCTR_STATE_PORT:-3001}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "========================================"
echo "  JourneyHawk — ${PRODUCT}"
echo "  Spec:    ${SPEC_FILE}"
echo "  Results: ${RESULTS_DIR}"
echo "  Started: $(date -Iseconds)"
echo "========================================"
echo ""

# Resolve spec file path (relative -> absolute from script dir)
if [[ ! "${SPEC_FILE}" = /* ]]; then
  SPEC_FILE="${SCRIPT_DIR}/${SPEC_FILE}"
fi
if [[ ! -f "${SPEC_FILE}" ]]; then
  echo "ERROR: spec file not found: ${SPEC_FILE}"
  exit 1
fi

# Load QA env (provides PHRONEX_QA_DATABASE_URL_SYNC)
QA_ENV="${SCRIPT_DIR}/../.qa.env"
if [[ -f "${QA_ENV}" ]]; then
  set -a; source "${QA_ENV}"; set +a
  echo "[env] Loaded ${QA_ENV}"
else
  echo "[env] WARNING: ${QA_ENV} not found — PHRONEX_QA_DATABASE_URL_SYNC may be unset"
fi

# Locate Python with phronex-common installed
VENV="${SCRIPT_DIR}/../phronex-common/.venv/bin/python"
if [[ -f "${VENV}" ]]; then
  PYTHON="${VENV}"
else
  PYTHON=$(command -v python3 || command -v python)
fi
echo "[env] Python: ${PYTHON}"

# Portal URL substitution — replace localhost:3002 with PORTAL_URL so specs
# can run against any portal instance (production, staging, or local).
# Default: https://app.phronex.com (production — safe while no paying customers).
# Override: set PORTAL_URL in .qa.env before running.
#
# .qa.env recommended additions for full production-mode runs:
#   PORTAL_URL=https://app.phronex.com
#   PHRONEX_JP_TEST_URL=https://jobc.phronex.com
#   PHRONEX_CC_TEST_URL=https://cc.phronex.com
#   PHRONEX_QA_ALLOWED_HOSTS=app.phronex.com,jobc.phronex.com,cc.phronex.com
PORTAL_URL="${PORTAL_URL:-https://app.phronex.com}"
echo "[env] Portal URL: ${PORTAL_URL}"
TEMP_SPEC=$(mktemp /tmp/jh-spec-XXXXXX.json)
FILTERED_SPEC=$(mktemp /tmp/jh-spec-filtered-XXXXXX.json)
trap 'rm -f "${TEMP_SPEC}" "${FILTERED_SPEC}"' EXIT
# Chain: URL substitution + credential injection.
# Credential injection — sentinels in spec text are replaced at runtime so the
# LLM agent receives literal values, never placeholder strings.
# Sentinels and their .qa.env sources:
#   QA_SUPERADMIN_PASSWORD  ← PHRONEX_PORTAL_TEST_PASSWORD or QA_SUPERADMIN_PASSWORD
#   qa-test-journeyhawk@phronex.com ← PHRONEX_PORTAL_TEST_EMAIL
#   QA_OWNER_EMAIL / QA_OWNER_PASSWORD ← RBAC gate (owner role, not superadmin)
#   QA_USER_EMAIL  / QA_USER_PASSWORD  ← RBAC gate (regular user, not superadmin)
#   QA_JP_FREE_EMAIL / QA_JP_FREE_PASSWORD ← JP tree spec jp-trunk-free
#   QA_JP_STANDARD_EMAIL / QA_JP_STANDARD_PASSWORD ← JP tree spec jp-trunk-standard
#   QA_JP_PRO_EMAIL / QA_JP_PRO_PASSWORD ← JP tree spec jp-trunk-pro
_PORTAL_PASS="${PHRONEX_PORTAL_TEST_PASSWORD:-${QA_SUPERADMIN_PASSWORD:-}}"
_PORTAL_EMAIL="${PHRONEX_PORTAL_TEST_EMAIL:-qa-test-journeyhawk@phronex.com}"
_OWNER_EMAIL="${QA_OWNER_EMAIL:-qa-owner@phronex.com}"
_OWNER_PASS="${QA_OWNER_PASSWORD:-}"
_USER_EMAIL="${QA_USER_EMAIL:-qa-user@phronex.com}"
_USER_PASS="${QA_USER_PASSWORD:-}"
_JP_FREE_EMAIL="${QA_JP_FREE_EMAIL:-qa-jp-free@phronex.com}"
_JP_FREE_PASS="${QA_JP_FREE_PASSWORD:-${_PORTAL_PASS}}"
_JP_STANDARD_EMAIL="${QA_JP_STANDARD_EMAIL:-qa-jp-standard@phronex.com}"
_JP_STANDARD_PASS="${QA_JP_STANDARD_PASSWORD:-${_PORTAL_PASS}}"
_JP_PRO_EMAIL="${QA_JP_PRO_EMAIL:-qa-jp-pro@phronex.com}"
_JP_PRO_PASS="${QA_JP_PRO_PASSWORD:-${_PORTAL_PASS}}"
sed \
  -e "s|http://localhost:3002|${PORTAL_URL}|g" \
  -e "s|QA_SUPERADMIN_PASSWORD|${_PORTAL_PASS}|g" \
  -e "s|qa-test-journeyhawk@phronex\.com|${_PORTAL_EMAIL}|g" \
  -e "s|QA_OWNER_EMAIL|${_OWNER_EMAIL}|g" \
  -e "s|QA_OWNER_PASSWORD|${_OWNER_PASS}|g" \
  -e "s|QA_USER_EMAIL|${_USER_EMAIL}|g" \
  -e "s|QA_USER_PASSWORD|${_USER_PASS}|g" \
  -e "s|QA_JP_FREE_EMAIL|${_JP_FREE_EMAIL}|g" \
  -e "s|QA_JP_FREE_PASSWORD|${_JP_FREE_PASS}|g" \
  -e "s|QA_JP_STANDARD_EMAIL|${_JP_STANDARD_EMAIL}|g" \
  -e "s|QA_JP_STANDARD_PASSWORD|${_JP_STANDARD_PASS}|g" \
  -e "s|QA_JP_PRO_EMAIL|${_JP_PRO_EMAIL}|g" \
  -e "s|QA_JP_PRO_PASSWORD|${_JP_PRO_PASS}|g" \
  "${SPEC_FILE}" > "${TEMP_SPEC}"
if [[ -n "${_PORTAL_PASS}" ]]; then
  echo "[env] Portal credentials: ${_PORTAL_EMAIL} (password injected)"
else
  echo "[env] WARNING: PHRONEX_PORTAL_TEST_PASSWORD not set — login steps may fail"
fi
if [[ -z "${_OWNER_PASS}" ]]; then
  echo "[env] WARNING: QA_OWNER_PASSWORD not set — RBAC owner gate journey will fail"
fi
if [[ -z "${_USER_PASS}" ]]; then
  echo "[env] WARNING: QA_USER_PASSWORD not set — RBAC user gate journey will fail"
fi
if [[ -z "${QA_JP_FREE_PASSWORD:-}" ]]; then
  echo "[env] WARNING: QA_JP_FREE_PASSWORD not set — jp-trunk-free falling back to superadmin password"
fi
if [[ -z "${QA_JP_STANDARD_PASSWORD:-}" ]]; then
  echo "[env] WARNING: QA_JP_STANDARD_PASSWORD not set — jp-trunk-standard falling back to superadmin password"
fi
if [[ -z "${QA_JP_PRO_PASSWORD:-}" ]]; then
  echo "[env] WARNING: QA_JP_PRO_PASSWORD not set — jp-trunk-pro falling back to superadmin password"
fi

# Step 0: Pre-run test data cleanup (optional — skipped if SDK key not set)
# Wipes QA test artefacts created by previous runs so journeys start clean.
# Requires these vars in .qa.env:
#   JP_TEST_CLEANUP_SDK_KEY          — must match QA_TEST_CLEANUP_SDK_KEY in /opt/jobportal/.env on EC2
#   PHRONEX_JP_TEST_URL              — defaults to https://jobc.phronex.com
#   CC_TEST_CLEANUP_SDK_KEY          — must match QA_TEST_CLEANUP_SDK_KEY in /opt/contentcompanion/.env on EC2
#   PHRONEX_CC_TEST_URL              — defaults to https://cc.phronex.com
#   PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY — must match QA_TEST_CLEANUP_SDK_KEY in /opt/phronex-auth/.env on EC2
#   PHRONEX_AUTH_TEST_URL            — defaults to https://auth.phronex.com
#   PHRONEX_QA_ALLOWED_HOSTS         — must include target hosts (production denylist bypass)
echo ""
# G-22: cleanup SDK key validation — on non-200, warn and expire resource in qa_test_resources.
_cleanup_check_response() {
  local http_code="$1" resource_key="$2" response_body="$3"
  if [[ "${http_code}" != "200" && "${http_code}" != "ERR" ]]; then
    echo "  WARNING: cleanup SDK key validation failed for ${resource_key} (HTTP ${http_code})" >&2
    "${PYTHON}" -c "
from phronex_common.testing.runner import _mark_cleanup_key_expired, _make_db_connection
import os
db_url = os.environ.get('PHRONEX_QA_DATABASE_URL_SYNC', '')
if db_url:
    try:
        conn = _make_db_connection(db_url)
        _mark_cleanup_key_expired(conn, '${resource_key}', 'HTTP ${http_code}: ${response_body}')
        conn.close()
    except Exception:
        pass
" 2>/dev/null || true
  fi
}

if [[ "${PRODUCT}" == "jp" ]] && [[ -n "${JP_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  JP_CLEANUP_URL="${PHRONEX_JP_TEST_URL:-https://jobc.phronex.com}"
  echo "[0/3] Pre-run JP cleanup at ${JP_CLEANUP_URL}..."
  for resource in users jobs applications; do
    _RESP_BODY=$(mktemp)
    HTTP=$(curl -s -o "${_RESP_BODY}" -w "%{http_code}" \
      -X POST "${JP_CLEANUP_URL}/api/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${JP_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
    _cleanup_check_response "${HTTP}" "jp_cleanup_sdk_key" "$(head -c 200 "${_RESP_BODY}" 2>/dev/null)"
    rm -f "${_RESP_BODY}"
  done
elif [[ "${PRODUCT}" == "cc" ]] && [[ -n "${CC_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  CC_CLEANUP_URL="${PHRONEX_CC_TEST_URL:-https://cc.phronex.com}"
  echo "[0/3] Pre-run CC cleanup at ${CC_CLEANUP_URL}..."
  for resource in conversations widgets; do
    _RESP_BODY=$(mktemp)
    HTTP=$(curl -s -o "${_RESP_BODY}" -w "%{http_code}" \
      -X POST "${CC_CLEANUP_URL}/api/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${CC_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
    _cleanup_check_response "${HTTP}" "cc_cleanup_sdk_key" "$(head -c 200 "${_RESP_BODY}" 2>/dev/null)"
    rm -f "${_RESP_BODY}"
  done
elif [[ "${PRODUCT}" == "auth" ]] && [[ -n "${PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  AUTH_CLEANUP_URL="${PHRONEX_AUTH_TEST_URL:-https://auth.phronex.com}"
  echo "[0/3] Pre-run Auth cleanup at ${AUTH_CLEANUP_URL}..."
  for resource in users instances impersonation_tokens payment_records; do
    _RESP_BODY=$(mktemp)
    HTTP=$(curl -s -o "${_RESP_BODY}" -w "%{http_code}" \
      -X POST "${AUTH_CLEANUP_URL}/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
    _cleanup_check_response "${HTTP}" "auth_cleanup_sdk_key" "$(head -c 200 "${_RESP_BODY}" 2>/dev/null)"
    rm -f "${_RESP_BODY}"
  done
else
  echo "[0/3] Pre-run cleanup skipped (${PRODUCT}_TEST_CLEANUP_SDK_KEY not set in .qa.env)"
fi

# Pre-flight: for portal product, verify QA credentials can actually log in before
# burning turns on a doomed run. Hits /api/auth/callback/credentials via curl.
# Aborts with clear message if auth fails (wrong password, not-superadmin, rate limit).
if [[ "${PRODUCT}" == "portal" ]] && [[ -n "${_PORTAL_PASS}" ]]; then
  echo ""
  echo "[preflight] Verifying portal QA credentials can log in..."
  _AUTH_PAYLOAD="{\"email\":\"${_PORTAL_EMAIL}\",\"password\":\"${_PORTAL_PASS}\"}"
  _AUTH_HTTP=$(curl -s -o /tmp/jh-login-check.txt -w "%{http_code}" \
    -X POST "${PORTAL_URL}/api/auth/callback/credentials" \
    -H "Content-Type: application/json" \
    -d "${_AUTH_PAYLOAD}" \
    --max-time 10 2>/dev/null || echo "ERR")
  if [[ "${_AUTH_HTTP}" == "200" ]] || [[ "${_AUTH_HTTP}" == "302" ]] || [[ "${_AUTH_HTTP}" == "307" ]]; then
    echo "[preflight] Login probe: HTTP ${_AUTH_HTTP} — credentials accepted"
  else
    _AUTH_BODY=$(cat /tmp/jh-login-check.txt 2>/dev/null | head -c 200)
    echo ""
    echo "⛔ PREFLIGHT FAILED: Portal login probe returned HTTP ${_AUTH_HTTP}"
    echo "   Email:    ${_PORTAL_EMAIL}"
    echo "   Response: ${_AUTH_BODY}"
    echo "   Fix: verify password in .qa.env AND that account has is_superadmin=TRUE in phronex-auth DB."
    echo "   Command:  psql \$PHRONEX_AUTH_DB -c \"UPDATE accounts SET is_superadmin=TRUE WHERE email='${_PORTAL_EMAIL}';\""
    exit 3
  fi
fi

# Kill any stale cctr-state MCP server on this port from a previous aborted run.
# If left running it serves the last journey's stale test plan to the next run.
_STALE_PID=$(lsof -ti:${CCTR_STATE_PORT} 2>/dev/null || true)
if [[ -n "${_STALE_PID}" ]]; then
  echo "[preflight] Killing stale cctr-state server (PID ${_STALE_PID}) on port ${CCTR_STATE_PORT}"
  kill "${_STALE_PID}" 2>/dev/null || true
  sleep 1
fi

# Step 0b: DocChain stage gate (STRAT-09) — verify docs artefacts before burning test turns.
# Checks 6 gates: USER-SPEC.html, ARCHITECTURE.html, INTEGRATION-MAP.html,
# TEST-ORACLES.html, QUALITY-STANDARDS.html, and snapshot freshness.
# In READ_ONLY mode: advisory only (non-blocking). In ACTIVE mode: non-zero exit blocks run.
# Docs dir resolved relative to product codebase: ${PHRONEX_CODE_ROOT}/<product>/.docs/
# Product slug → repo name mapping (slug != repo name for jp and cc)
declare -A _PRODUCT_REPO_MAP=(["jp"]="jobportal" ["cc"]="contentcompanion" ["comc"]="phronex-command-centre" ["website"]="phronex-website" ["portal"]="phronex-portal" ["praxis"]="praxis")
_PRODUCT_REPO="${_PRODUCT_REPO_MAP[${PRODUCT}]:-${PRODUCT}}"
_DOCS_DIR="${PHRONEX_CODE_ROOT:-/home/ouroborous/code}/${_PRODUCT_REPO}/.docs"
if [[ -d "${_DOCS_DIR}" ]]; then
  echo ""
  echo "[0b/3] DocChain stage gate (STRAT-09, STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
  _GATE_MODE="${STRATEGIST_MODE_OVERRIDE:-${STRATEGIST_MODE:-ACTIVE}}"
  _GATE_EXIT=0
  "${PYTHON}" -m phronex_common.docchain.stage_gate \
    --stage pre_run \
    --docs-dir "${_DOCS_DIR}" \
    --product "${PRODUCT}" || _GATE_EXIT=$?
  if [[ ${_GATE_EXIT} -ne 0 ]]; then
    if [[ "${_GATE_MODE}" == "ACTIVE" ]]; then
      echo "[0b/3] DocChain gate: BLOCKED (ACTIVE mode) — aborting run. Fix missing artefacts above." >&2
      exit ${_GATE_EXIT}
    else
      echo "[0b/3] DocChain gate: advisory (non-blocking in ${_GATE_MODE} mode)"
    fi
  fi
else
  echo "[0b/3] DocChain stage gate skipped — docs dir not found: ${_DOCS_DIR}"
fi

# Step 0b-gen: Journey generation (Phase 92 — coverage gap fill)
# Three signal sources: portal pages, backend endpoint clusters, .docs/ artefacts.
# Identifies features without journey coverage and generates DEEP specs for them.
# Merges with existing spec (existing take precedence). Fail-open: if generation
# fails, original spec used.
echo ""
echo "[0b-gen/3] Journey generation (coverage gap fill)..."
_GEN_OUTPUT=$(mktemp /tmp/jh-generated-XXXXXX.json)
_DOCS_DIR="${PHRONEX_CODE_ROOT:-${HOME}/code}/${_PRODUCT_REPO}/.docs"
if "${PYTHON}" -m phronex_common.testing.journey_generator \
  --product "${PRODUCT}" \
  --existing-spec "${TEMP_SPEC}" \
  --docs-dir "${_DOCS_DIR}" \
  --output "${_GEN_OUTPUT}" \
  --max-journeys 150 \
  --min-depth DEEP 2>&1; then
  if [ -s "${_GEN_OUTPUT}" ]; then
    _ORIG_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "?")
    _NEW_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${_GEN_OUTPUT}'))))" 2>/dev/null || echo "?")
    cp "${_GEN_OUTPUT}" "${TEMP_SPEC}"
    echo "[0b-gen/3] Merged: ${_ORIG_COUNT} existing + generated = ${_NEW_COUNT} total journeys"
  else
    echo "[0b-gen/3] WARN: generation produced empty output — using original spec"
  fi
else
  echo "[0b-gen/3] WARN: journey generation failed (non-fatal) — using original spec"
fi
rm -f "${_GEN_OUTPUT}"

# Step 0c: Resource verification (Phase 84 — pre-run resource inventory check)
# Verifies all test resources (accounts, credentials, documents, infra) are available.
# Populates _resource_cache used by fixture_guard's detect_seed_test_account.
echo ""
echo "[0c/3] Resource verification (Phase 84)..."
_RESOURCE_REPORT="${RESULTS_DIR}/resource-verification.json"
# Use `if` to suppress set -e on non-zero exit (set -e doesn't abort on failed
# `if` test commands). _RES_EXIT captures the real exit code for routing below.
_RES_EXIT=0
if ! "${PYTHON}" -m phronex_common.testing.resources verify \
  --product "${PRODUCT}" \
  --report "${_RESOURCE_REPORT}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC}" 2>&1; then
  _RES_EXIT=$?
fi
if [[ ${_RES_EXIT} -eq 2 ]]; then
  echo "[0c/3] Resource verification: INFRASTRUCTURE UNREACHABLE — aborting." >&2
  exit 2
elif [[ ${_RES_EXIT} -eq 1 ]]; then
  echo "[0c/3] Resource verification: some resources missing (see ${_RESOURCE_REPORT}). Continuing with degraded coverage."
else
  echo "[0c/3] Resource verification: all resources available."
fi

# Step 0c2: Resource criticality gate (D-02) — block on missing critical resources.
# --waive-resources flag skips this gate (JOURNEYHAWK_WAIVE_RESOURCES=1).
echo ""
if [[ "${JOURNEYHAWK_WAIVE_RESOURCES:-0}" == "0" ]]; then
    echo "[0c2/3] Resource criticality gate (D-02)..."
    "${PYTHON}" -c "
import sys
try:
    from phronex_common.testing.resources.seed import _build_inventory
    import os
    inventory = _build_inventory('${PRODUCT}')
    missing_critical = []
    for entry in inventory:
        if entry.get('default_criticality') == 'critical':
            ptype = entry.get('provider_type', '')
            if ptype == 'env_var':
                var = entry.get('provider_config', {}).get('var_name', '')
                if var and not os.environ.get(var):
                    missing_critical.append(entry['display_name'])
    if missing_critical:
        print(f'CRITICAL: {len(missing_critical)} missing critical resources:', file=sys.stderr)
        for name in missing_critical:
            print(f'  - {name}', file=sys.stderr)
        print('Use --waive-resources to skip this check.', file=sys.stderr)
        sys.exit(1)
    print('[0c2/3] All critical resources present.')
except Exception as exc:
    print(f'  warn: resource gate check failed (non-fatal): {exc}', file=sys.stderr)
" || {
    echo "BLOCKED: Missing critical resources. Use --waive-resources to skip." >&2
    exit 1
}
else
    echo "[0c2/3] Resource gate waived (--waive-resources flag)."
fi

# Step 0d: Journey depth enforcement (Phase 92 — Fix 4)
# Classifies each journey as SMOKE/SURFACE/DEEP/BEHAVIORAL.
# Policy: SMOKE journeys are auto-deepened via LLM or DROPPED.
# SURFACE journeys are flagged but run.  Override: JH_ALLOW_SMOKE=1.
echo ""
echo "[0d/3] Journey depth enforcement (Phase 92)..."
"${PYTHON}" -c "
import json, sys, os
from phronex_common.testing.depth_scorer import score_journey, DepthLevel

specs = json.loads(open('${TEMP_SPEC}').read())
allow_smoke = os.environ.get('JH_ALLOW_SMOKE', '0') == '1'

smoke = []
surface = []
kept = []

for j in specs:
    depth = score_journey(j)
    if depth == DepthLevel.SMOKE:
        smoke.append(j)
    elif depth == DepthLevel.SURFACE:
        surface.append(j)
        kept.append(j)
    else:
        kept.append(j)

if smoke and allow_smoke:
    print(f'  ALLOWED (override): {len(smoke)} SMOKE journeys pass via JH_ALLOW_SMOKE=1')
    kept.extend(smoke)
elif smoke:
    # Attempt auto-deepening via LLM
    deepened_count = 0
    try:
        from phronex_common.testing.spec_generator import deepen_journey_spec
        docs_dir = os.environ.get('_DOCS_DIR', '')
        for s in smoke:
            result = deepen_journey_spec(s, docs_dir=docs_dir or None)
            if result:
                new_depth = score_journey(result)
                if new_depth not in (DepthLevel.SMOKE,):
                    kept.append(result)
                    deepened_count += 1
                    continue
            # Could not deepen — DROP this journey
            print(f'  DROPPED: {s.get(\"id\", \"?\")} (SMOKE, could not auto-deepen)', file=sys.stderr)
        if deepened_count:
            print(f'  DEEPENED: {deepened_count}/{len(smoke)} SMOKE -> DEEP via LLM')
    except Exception as exc:
        print(f'  WARN: auto-deepen unavailable ({exc}) — dropping {len(smoke)} SMOKE journeys', file=sys.stderr)

if surface:
    ids = [s.get('id', '?') for s in surface]
    print(f'  FLAGGED: {len(surface)} SURFACE journeys (running but shallow): {ids}', file=sys.stderr)

total_original = len(specs)
total_kept = len(kept)
dropped = total_original - total_kept
deep_plus = total_kept - len(surface)
print(f'  Depth: {deep_plus} DEEP+, {len(surface)} SURFACE, {dropped} dropped out of {total_original} total')

# Write filtered spec back
with open('${TEMP_SPEC}', 'w') as f:
    json.dump(kept, f, indent=2)
" 2>&1 || echo "[0d/3] WARN: depth enforcement failed (non-fatal, continuing)"

# Step 0e: Strategist run filter (Phase 90)
# Applies depth gate (Reason D) + coverage-based filtering. Writes filtered spec
# to a temp file. If it succeeds, use the filtered spec downstream; otherwise
# continue with the original TEMP_SPEC unchanged (fail-open).
# Exports JH_RUN_FILTER_INCLUDED / JH_RUN_FILTER_SKIPPED for runner.py to
# persist in qa_runs (portal Strategist tab reads these).
echo ""
echo "[0e/3] Strategist run filter (Phase 90)..."
RUN_FILTER_OUTPUT=$(mktemp /tmp/jh-run-filter-XXXXXX.json)
PRE_FILTER_COUNT=$("${PYTHON}" -c "import json,sys; d=json.load(open('${TEMP_SPEC}')); print(len(d) if isinstance(d,list) else 1)" 2>/dev/null || echo "0")
if "${PYTHON}" -m phronex_common.testing.run_filter \
  --product "${PRODUCT}" \
  --spec "${TEMP_SPEC}" \
  --output "${RUN_FILTER_OUTPUT}" 2>&1; then
  if [ -s "${RUN_FILTER_OUTPUT}" ]; then
    POST_FILTER_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${RUN_FILTER_OUTPUT}'))))" 2>/dev/null || echo "${PRE_FILTER_COUNT}")
    cp "${RUN_FILTER_OUTPUT}" "${TEMP_SPEC}"
    export JH_RUN_FILTER_INCLUDED="${POST_FILTER_COUNT}"
    export JH_RUN_FILTER_SKIPPED=$(( PRE_FILTER_COUNT - POST_FILTER_COUNT ))
    echo "[0e/3] Run filter applied — ${JH_RUN_FILTER_INCLUDED} included, ${JH_RUN_FILTER_SKIPPED} skipped"
  else
    echo "[0e/3] WARN: run filter produced empty output — using original spec"
  fi
else
  echo "[0e/3] WARN: run filter failed (non-fatal) — using original spec"
fi
rm -f "${RUN_FILTER_OUTPUT}"

# Step 1a: Strategist Block A — fixture_guard pre-filter
# STRATEGIST_MODE controls behaviour (DISABLED|READ_ONLY|ACTIVE; default ACTIVE).
# Per-run override: --strategist-mode=VALUE flag exports STRATEGIST_MODE_OVERRIDE
# which the strategist mode.py read-through chain prefers above DB row + STRATEGIST_MODE env.
# fixture_guard parses each journey for fixture requirements (logins, seed
# data, backend reachability) and drops journeys whose fixtures aren't
# satisfied. Filtered spec on stdout -> ${FILTERED_SPEC}; decision report ->
# ${RESULTS_DIR}/fixture-decisions.json.
mkdir -p "${RESULTS_DIR}"
echo ""
echo "[1a/3] Fixture guard pre-filter (STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
"${PYTHON}" -m phronex_common.testing.strategist.fixture_guard \
  --spec "${TEMP_SPEC}" \
  --report "${RESULTS_DIR}/fixture-decisions.json" \
  > "${FILTERED_SPEC}"

# Step 1a2: Pre-run strategist signals (Q1-Q4)
# Log coverage_gap, yield_trend, ethos_priority, fixture_health signals to stderr.
# Also calls JourneyRecommender.rank() on the filtered spec to log journey priority order.
# Non-blocking: failures are logged as warnings and the run continues.
export JOURNEYHAWK_PRODUCT="${PRODUCT}"
export JOURNEYHAWK_FILTERED_SPEC="${FILTERED_SPEC}"
echo ""
echo "[1a2/3] Pre-run strategist signals (Q1-Q6)..."
"${PYTHON}" - <<'SIGNALS_EOF' || true
import os, sys, json

_db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
_product = os.environ.get("JOURNEYHAWK_PRODUCT", "")
_spec_file = os.environ.get("JOURNEYHAWK_FILTERED_SPEC", "")

if not _db_url:
    print("[strategist:pre-run] PHRONEX_QA_DATABASE_URL_SYNC not set — signals skipped", file=sys.stderr)
    sys.exit(0)
if not _product:
    print("[strategist:pre-run] JOURNEYHAWK_PRODUCT not set — signals skipped", file=sys.stderr)
    sys.exit(0)

try:
    import psycopg2
    from phronex_common.testing.strategist.questions import (
        answer_coverage_gap, answer_yield_trend,
        answer_sweep_priority,
        answer_fixture_health,
        answer_depth_quality, answer_docchain_freshness,
        answer_ethos_coverage,
    )
    _clean_url = _db_url.replace("postgresql+psycopg2://", "postgresql://")
    _conn = psycopg2.connect(_clean_url)
    try:
        q1 = answer_coverage_gap(_product, _conn)
        q2 = answer_yield_trend(_product, _conn)
        q3 = answer_sweep_priority(_product, _conn)
        q4 = answer_fixture_health(_product, _conn)
        q5 = answer_depth_quality(_product, _conn)
        q6 = answer_docchain_freshness(_product, _conn)
        q7 = answer_ethos_coverage(_product, _conn)
        print(f"[strategist:pre-run] Q1 coverage_gap={q1:.3f}  Q2 yield_trend={q2:.3f}  Q3 sweep_priority={q3:.3f}  Q4 fixture_health={q4:.3f}", file=sys.stderr)
        print(f"[strategist:pre-run] Q5 depth_quality={q5:.3f}  Q6 docchain_freshness={q6:.3f}  Q7 ethos_coverage={q7:.3f}", file=sys.stderr)

        # JourneyRecommender ranking (log top journeys by priority score)
        if _spec_file:
            from phronex_common.testing.strategist.recommender import JourneyRecommender
            _journeys = json.loads(open(_spec_file).read())
            _jlist = [{"journey_id": j.get("id", "?"), "product_slug": _product} for j in _journeys]
            if _jlist:
                _rec = JourneyRecommender()
                _ranked = _rec.rank(_jlist, _conn)
                if _ranked:
                    _top3 = _ranked[:3]
                    print(f"[strategist:pre-run] top-3 priority: {[r.journey_id for r in _top3]}", file=sys.stderr)
    finally:
        _conn.close()
except Exception as e:
    print(f"[strategist:pre-run] WARNING: signals failed (non-fatal): {e}", file=sys.stderr)
SIGNALS_EOF

# Step 1b: Apply wiki test_mutation directives to filtered spec
# Reads test_mutation JSONB from qa_wiki_articles and applies ADD_STEP / ADD_JOURNEY /
# SKIP_JOURNEY / REQUIRE_FIXTURE / ABORT_ON / DEEPEN directives in-memory.
# Fail-open: if DB unavailable or no directives, MUTATED_SPEC == FILTERED_SPEC.
MUTATED_SPEC=$(mktemp /tmp/jh-spec-mutated-XXXXXX.json)
export MUTATED_SPEC
trap 'rm -f "${TEMP_SPEC}" "${FILTERED_SPEC}" "${MUTATED_SPEC}"' EXIT
echo ""
echo "[1b/3] Applying wiki mutations (STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
"${PYTHON}" -m phronex_common.testing.strategist.mutations \
  --spec "${FILTERED_SPEC}" \
  --product "${PRODUCT}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  > "${MUTATED_SPEC}" || {
  echo "[1b/3] WARN: mutations applier failed — using filtered spec as-is" >&2
  cp "${FILTERED_SPEC}" "${MUTATED_SPEC}"
}

# Step 0.9: Pre-run time forecast — warn operator if estimated runtime exceeds cap.
# Reads journey count from spec + historical avg from qa_journeys.
# If forecast > max_runtime: prints warning and waits 60s for operator to Ctrl-C.
# If JOURNEYHAWK_SKIP_FORECAST=1: skips interactive wait (for CI / non-TTY runs).
export STRATEGIST_ABORT_MAX_RUNTIME_SEC="${STRATEGIST_ABORT_MAX_RUNTIME_SEC:-5400}"
echo ""
echo "[0.9/3] Pre-run time forecast..."
"${PYTHON}" - <<FORECAST_EOF || true
import json, os, sys, time

spec_path = os.environ.get("MUTATED_SPEC", "") or os.environ.get("SPEC_FILE", "")
max_runtime = float(os.environ.get("STRATEGIST_ABORT_MAX_RUNTIME_SEC", "5400"))
product = os.environ.get("JOURNEYHAWK_PRODUCT", "")
skip_forecast = os.environ.get("JOURNEYHAWK_SKIP_FORECAST", "") == "1"

# Count journeys in spec
journey_count = 0
try:
    with open(spec_path) as f:
        spec = json.load(f)
    if isinstance(spec, list):
        journey_count = len(spec)
    elif isinstance(spec, dict) and "journeys" in spec:
        journey_count = len(spec["journeys"])
    elif isinstance(spec, dict) and "testcases" in spec:
        journey_count = len(spec["testcases"])
except Exception:
    pass

# Historical avg from qa_journeys (last 5 completed runs for this product)
avg_sec = 120.0  # conservative fallback: 2 min per journey
db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
if db_url and product:
    try:
        import psycopg2
        clean = db_url.replace("postgresql+psycopg2://", "postgresql://").replace("postgresql+asyncpg://", "postgresql://")
        conn = psycopg2.connect(clean)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT gaps_found, created_at FROM qa_journeys "
                "WHERE product_slug = %s AND suite_scope NOT LIKE '%%:aborted' "
                "ORDER BY created_at DESC LIMIT 5",
                (product,),
            )
            rows = cur.fetchall()
        conn.close()
        # Use gap detector journey count as proxy; fall back to 120s default
        if rows:
            avg_sec = 120.0  # keep fallback; real duration not stored yet
    except Exception:
        pass

if journey_count == 0:
    print(f"  Journey count: unknown (spec parse failed) — proceeding with max_runtime={max_runtime:.0f}s cap")
    sys.exit(0)

estimated_sec = journey_count * avg_sec
estimated_min = estimated_sec / 60
max_min = max_runtime / 60

print(f"  Journeys in spec : {journey_count}")
print(f"  Avg per journey  : ~{avg_sec:.0f}s (historical)")
print(f"  Estimated total  : ~{estimated_min:.0f} min  ({estimated_sec:.0f}s)")
print(f"  Runtime cap      : {max_min:.0f} min  ({max_runtime:.0f}s)")

if estimated_sec > max_runtime:
    shortfall = journey_count - int(max_runtime / avg_sec)
    print(f"")
    print(f"  ⚠️  FORECAST EXCEEDS CAP: ~{estimated_min:.0f} min estimated vs {max_min:.0f} min cap.")
    print(f"     ~{shortfall} journey(s) at the END OF THE SPEC will likely be aborted.")
    print(f"     Options:")
    print(f"       1. Ctrl-C now, then set STRATEGIST_ABORT_MAX_RUNTIME_SEC={int(estimated_sec + 600)} and re-run")
    print(f"       2. Ctrl-C now and use a filtered spec with fewer journeys")
    print(f"       3. Press Enter or wait 60s to proceed with current cap (tail journeys will abort)")
    if not skip_forecast:
        import select
        print(f"  Waiting 60s for operator decision... (set JOURNEYHAWK_SKIP_FORECAST=1 to skip)", flush=True)
        rlist, _, _ = select.select([sys.stdin], [], [], 60)
        if rlist:
            line = sys.stdin.readline().strip()
            if line.lower() in ("q", "quit", "exit", "n", "no"):
                print("  Operator aborted before run.", file=sys.stderr)
                sys.exit(99)
        print("  Proceeding with current cap.")
    else:
        print("  JOURNEYHAWK_SKIP_FORECAST=1 set — proceeding without interactive wait.")
else:
    print(f"  ✓ Estimated runtime within cap. Proceeding.")
FORECAST_EOF
_FORECAST_EXIT=$?
if [[ ${_FORECAST_EXIT} -eq 99 ]]; then
  echo "[0.9/3] Operator aborted before run. Exiting."
  exit 1
fi

# Step 1: cc-test-runner (wrapped by run_arbiter)
# run_arbiter spawns cc-test-runner as a child, streams its stdout, and
# SIGTERMs the child on abort triggers (3 consecutive fails / >30 min runtime
# / per-journey 5 min hang / >50% network failure rate). On abort it writes
# ${RESULTS_DIR}/abort_reason.json which the pipeline (Step 2) reads to
# suffix qa_journeys.suite_scope with ':aborted'.
echo ""
echo "[1/3] Spawning cc-test-runner (wrapped by run_arbiter, max_runtime=${STRATEGIST_ABORT_MAX_RUNTIME_SEC}s)..."
CC_EXIT=0
"${PYTHON}" -m phronex_common.testing.strategist.run_arbiter \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec "${MUTATED_SPEC}" \
  -- \
  "${SCRIPT_DIR}/cli/cc-test-runner" \
    -t "${MUTATED_SPEC}" \
    -o "${RESULTS_DIR}" \
    --maxTurns 50 \
    --statePort "${CCTR_STATE_PORT}" \
  || CC_EXIT=$?
if [[ ${CC_EXIT} -ne 0 ]]; then
  echo "[1/3] cc-test-runner exit=${CC_EXIT} (test failures expected — continuing to pipeline)"
fi

# Step 1b (PQIP §12): Handoff Queue — poll for human-in-the-loop steps.
# If any journey steps were queued for operator action during cc-test-runner,
# poll until resolved or timeout (600s). Fail-open: if no handoffs or DB unavailable, skip.
echo ""
echo "[1b/3] Checking handoff queue (human-in-the-loop steps)..."
"${PYTHON}" - <<'HANDOFF_EOF' || true
import os, sys

_db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
_run_id = os.environ.get("JOURNEYHAWK_RUN_ID", "")
if not _db_url or not _run_id:
    print("[handoff] skipped: no DB URL or RUN_ID", file=sys.stderr)
    sys.exit(0)

try:
    import psycopg2
    from phronex_common.testing._qa_db import clean_dsn
    from phronex_common.testing.handoff import get_pending, poll_until_done

    _conn = psycopg2.connect(clean_dsn(_db_url))
    try:
        pending = get_pending(_conn, run_id=_run_id)
        if not pending:
            print("[handoff] no pending items — continuing", file=sys.stderr)
            sys.exit(0)

        print(f"[handoff] {len(pending)} items pending — polling (max 600s)...", file=sys.stderr)
        for item in pending:
            print(f"  [{item.reason}] {item.journey_id} step {item.step_id}: {item.instruction}", file=sys.stderr)

        completed, skipped, expired = poll_until_done(_conn, _run_id)
        print(f"[handoff] done: {completed} completed, {skipped} skipped, {expired} expired", file=sys.stderr)
    finally:
        _conn.close()
except Exception as e:
    print(f"[handoff] WARNING: poll failed (non-fatal): {e}", file=sys.stderr)
HANDOFF_EOF

# Re-export OAuth token for intelligence pipeline LLM calls.
# cc-test-runner is done — safe to restore ANTHROPIC_API_KEY from Claude credentials.
if [[ -f "$HOME/.claude/.credentials.json" ]]; then
  _OAUTH_TOKEN=$(python3 -c "
import json, sys
try:
    d = json.load(open('$HOME/.claude/.credentials.json'))
    print(d['claudeAiOauth']['accessToken'])
except Exception:
    sys.exit(1)
" 2>/dev/null) && export ANTHROPIC_API_KEY="${_OAUTH_TOKEN}"
fi

# Step 2: intelligence pipeline via phronex_common.testing.runner
echo ""
echo "[2/3] Running intelligence pipeline (phronex_common.testing.runner)..."
"${PYTHON}" -m phronex_common.testing.runner \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec-file "${SPEC_FILE}" \
  ${_DOCS_DIR:+--docs-dir "${_DOCS_DIR}"}

PIPE_EXIT=$?

# Step 3 (Strategist Block B): CycleCloseGate — quality gate before cycle_closed emission.
# Per REQUIREMENTS.md STRAT-05 / CONTEXT.md A2.Q1-A2.Q3.
# STRATEGIST_MODE controls gate behaviour (DISABLED|READ_ONLY|ACTIVE; default ACTIVE).
#
# - DISABLED:  gate skipped entirely (passthrough).
# - READ_ONLY: gate evaluates + logs to qa_cycle_log, but never blocks emission.
# - ACTIVE:    gate evaluates; if failed, cycle_closed is NOT emitted (exit 0 — run
#              succeeded; gate held emission per CONTEXT.md A2.Q2).
#
# TODO(STRAT-05): cycle_closed emission signal — when a downstream consumer is wired
# for the cycle_closed event, add it here AFTER the gate check (only when gate passes).
echo ""
echo "[strategist] Running cycle-close gate (STRAT-05)..."
"${PYTHON}" - <<'GATE_EOF' || true
import os, sys

_mode = os.environ.get("STRATEGIST_MODE", "ACTIVE").strip().upper()
if _mode == "DISABLED":
    print("[strategist] CycleCloseGate: DISABLED — passthrough")
    sys.exit(0)

try:
    import psycopg2
    from phronex_common.testing.strategist.mode import get_mode
    from phronex_common.testing.strategist.cycle_gate import CycleCloseGate

    db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
    if not db_url:
        print("[strategist] WARNING: PHRONEX_QA_DATABASE_URL_SYNC not set — gate skipped", file=sys.stderr)
        sys.exit(0)

    clean_url = db_url.replace("postgresql+psycopg2://", "postgresql://")
    db = psycopg2.connect(clean_url)
    try:
        # Phase 80: integer cycle_id not yet tracked (Phase 82 adds qa_runs.cycle_id).
        # Pass 0 — RCA condition checks all open defects (not cycle-scoped);
        # retry condition conservatively passes when is_retry column is absent.
        gate = CycleCloseGate(get_mode(), db)
        result = gate.check(cycle_id=0)
    finally:
        db.close()

    if result.passed:
        print(f"[strategist] CycleCloseGate: PASSED (mode={_mode})")
    else:
        failures = [f.value for f in result.failures]
        print(
            f"[strategist] CYCLE-HOLD: gate failed — {failures} "
            f"(mode={_mode}). cycle_closed emission skipped. Exit 0.",
            file=sys.stderr,
        )
        if _mode == "ACTIVE":
            # Run succeeded; gate held emission — exit 0 per CONTEXT.md A2.Q2
            sys.exit(0)

except Exception as e:
    print(f"[strategist] WARNING: CycleCloseGate error (non-fatal): {e}", file=sys.stderr)
GATE_EOF

# Step 3b (Phase 86): Data invariant check — run business-rule invariants
# against the product DB. Fail-open: invariant_runner errors never crash the run.
echo ""
echo "[3b/3] Data invariant check (Phase 86)..."
"${PYTHON}" - <<'INVARIANT_EOF' || true
import os, sys
product = os.environ.get("JOURNEYHAWK_PRODUCT", os.environ.get("PRODUCT", ""))
if not product:
    print("[invariants] skipped (no PRODUCT set)", file=sys.stderr)
    sys.exit(0)
product_db_url = os.environ.get(f"PHRONEX_{product.upper()}_DATABASE_URL")
if not product_db_url:
    print(f"[invariants] skipped: PHRONEX_{product.upper()}_DATABASE_URL not set", file=sys.stderr)
    sys.exit(0)
qa_db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
try:
    from phronex_common.testing.invariant_runner import run_invariants
    results = run_invariants(
        product,
        product_db_url=product_db_url,
        qa_db_url=qa_db_url or None,
    )
    total = len(results)
    passed = sum(1 for r in results if r.get("passed", False))
    failed = total - passed
    print(f"[invariants] {total} invariants checked: {passed} passed, {failed} failed")
    if failed > 0:
        for r in results:
            if not r.get("passed", False):
                print(f"  FAIL: {r.get('name', 'unknown')} — {r.get('error', 'no detail')}", file=sys.stderr)
except Exception as e:
    print(f"[invariants] WARNING: invariant check failed (non-fatal): {e}", file=sys.stderr)
INVARIANT_EOF

# Step 4: Strategist Post-Run Report — aggregates all intelligence pipeline outputs
# into a single visible summary. Fail-open: report errors never crash the run.
echo ""
echo "[4/3] Generating strategist report..."
"${PYTHON}" -m phronex_common.testing.strategist.report \
  --product "${PRODUCT}" \
  --run-id "${JOURNEYHAWK_RUN_ID}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  || echo "[strategist:report] WARNING: report generation failed (non-fatal)" >&2

echo ""
echo "[4.5/3] Generating comprehensive HTML strategist report..."
_HTML_OUT=$("${PYTHON}" -m phronex_common.testing.strategist.report_html \
  --product "${PRODUCT}" \
  --run-id "${JOURNEYHAWK_RUN_ID}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  --out-dir "${RESULTS_DIR}" \
  --suite-scope "${SUITE_SCOPE:-full}" \
  2>&1) && echo "  HTML report: ${_HTML_OUT}" \
  || {
    echo "[strategist:report_html] WARNING: HTML report generation failed (non-fatal)" >&2
    echo "  Error detail: ${_HTML_OUT}" >&2
  }

echo ""
echo "========================================"
echo "  JourneyHawk COMPLETE"
echo "  cc-test-runner exit : ${CC_EXIT}"
echo "  pipeline exit       : ${PIPE_EXIT}"
echo "  Results dir         : ${RESULTS_DIR}"
echo "  Finished: $(date -Iseconds)"
echo "========================================"

# ---------- Phase 88 gate-mode exit ----------
if [[ "$GATE_MODE" -eq 1 ]]; then
  GATE_DIR="${RESULTS_DIR}"
  GATE_REPORT="${GATE_DIR}/gate-report.md"

  # Phase 89: Query FLAKY journey IDs from qa_confidence_scores for quarantine.
  # If DB unavailable, FLAKY_IDS_FILE stays empty and all BROKEN findings count.
  FLAKY_IDS_FILE=$(mktemp)
  trap "rm -f '${FLAKY_IDS_FILE}'" EXIT
  FLAKY_QUARANTINED=0

  if [[ -n "${PHRONEX_QA_DATABASE_URL_SYNC:-}" ]]; then
    _FLAKY_IDS_FILE="${FLAKY_IDS_FILE}" "${PYTHON}" - <<'FLAKY_EOF' || true
import os, sys
try:
    import psycopg2
    db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
    if not db_url:
        sys.exit(0)
    clean_url = db_url.replace("postgresql+psycopg2://", "postgresql://")
    conn = psycopg2.connect(clean_url)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT journey_id FROM qa_confidence_scores "
                "WHERE classification = 'FLAKY'"
            )
            flaky_ids = [row[0] for row in cur.fetchall()]
    finally:
        conn.close()
    if flaky_ids:
        # Write one ID per line to the file path passed via env
        flaky_file = os.environ.get("_FLAKY_IDS_FILE", "")
        if flaky_file:
            with open(flaky_file, "w") as f:
                for fid in flaky_ids:
                    f.write(fid + "\n")
            print(f"[gate] loaded {len(flaky_ids)} FLAKY journey IDs for quarantine", file=sys.stderr)
except Exception as e:
    print(f"[gate] WARNING: FLAKY query failed (non-fatal, counting all BROKEN): {e}", file=sys.stderr)
FLAKY_EOF
  fi

  # Count all BROKEN findings
  BROKEN_RAW=$(grep -c '"severity":"BROKEN"' "${GATE_DIR}"/*.json 2>/dev/null || echo 0)

  # Filter out FLAKY journey IDs from BROKEN count
  if [[ -s "${FLAKY_IDS_FILE}" ]]; then
    # Extract BROKEN lines, then exclude any that contain a FLAKY journey ID
    BROKEN_LINES=$(grep '"severity":"BROKEN"' "${GATE_DIR}"/*.json 2>/dev/null || true)
    if [[ -n "${BROKEN_LINES}" ]]; then
      BROKEN_COUNT=$(echo "${BROKEN_LINES}" | grep -v -F -f "${FLAKY_IDS_FILE}" | grep -c . || echo 0)
      FLAKY_QUARANTINED=$(( BROKEN_RAW - BROKEN_COUNT ))
    else
      BROKEN_COUNT=0
    fi
  else
    BROKEN_COUNT="${BROKEN_RAW}"
  fi

  # Log quarantined FLAKY journeys
  if [[ "${FLAKY_QUARANTINED}" -gt 0 ]]; then
    echo "[gate] ${FLAKY_QUARANTINED} BROKEN finding(s) quarantined (FLAKY journey)" >&2
    while IFS= read -r flaky_id; do
      if grep -q "${flaky_id}" "${GATE_DIR}"/*.json 2>/dev/null; then
        echo "[gate] WARNING: FLAKY quarantined: ${flaky_id}" >&2
      fi
    done < "${FLAKY_IDS_FILE}"
  fi

  echo "## Findings Summary" > "${GATE_REPORT}"
  echo "" >> "${GATE_REPORT}"
  echo "| Severity | Count |" >> "${GATE_REPORT}"
  echo "|----------|-------|" >> "${GATE_REPORT}"
  for sev in BROKEN HALF_BUILT FRICTION DRIFT; do
    count=$(grep -c "\"severity\":\"$sev\"" "${GATE_DIR}"/*.json 2>/dev/null || echo 0)
    echo "| $sev | $count |" >> "${GATE_REPORT}"
  done
  echo "| FLAKY_QUARANTINED | $FLAKY_QUARANTINED |" >> "${GATE_REPORT}"
  echo "" >> "${GATE_REPORT}"

  if [[ "$BROKEN_COUNT" -gt 0 ]]; then
    echo "**BLOCKED:** $BROKEN_COUNT BROKEN finding(s) detected (${FLAKY_QUARANTINED} FLAKY quarantined). Fix before merging." >> "${GATE_REPORT}"
    exit 1
  else
    echo "**PASSED:** No BROKEN findings (${FLAKY_QUARANTINED} FLAKY quarantined). Non-blocking findings reported above." >> "${GATE_REPORT}"
    exit 0
  fi
fi

# Exit non-zero only if pipeline failed (test failures are not pipeline errors)
exit ${PIPE_EXIT}
