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

# ---------- Phase 82 STRAT-16 — per-run mode override ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strategist-mode=*)
      val="${1#*=}"
      ;;
    --strategist-mode)
      val="$2"
      shift
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
if [[ "${PRODUCT}" == "jp" ]] && [[ -n "${JP_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  JP_CLEANUP_URL="${PHRONEX_JP_TEST_URL:-https://jobc.phronex.com}"
  echo "[0/3] Pre-run JP cleanup at ${JP_CLEANUP_URL}..."
  for resource in users jobs applications; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${JP_CLEANUP_URL}/api/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${JP_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
  done
elif [[ "${PRODUCT}" == "cc" ]] && [[ -n "${CC_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  CC_CLEANUP_URL="${PHRONEX_CC_TEST_URL:-https://cc.phronex.com}"
  echo "[0/3] Pre-run CC cleanup at ${CC_CLEANUP_URL}..."
  for resource in conversations widgets; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${CC_CLEANUP_URL}/api/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${CC_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
  done
elif [[ "${PRODUCT}" == "auth" ]] && [[ -n "${PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY:-}" ]]; then
  AUTH_CLEANUP_URL="${PHRONEX_AUTH_TEST_URL:-https://auth.phronex.com}"
  echo "[0/3] Pre-run Auth cleanup at ${AUTH_CLEANUP_URL}..."
  for resource in users instances impersonation_tokens payment_records; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${AUTH_CLEANUP_URL}/admin/test-cleanup/${resource}" \
      -H "X-SDK-Key: ${PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY}" \
      --max-time 10 2>/dev/null || echo "ERR")
    echo "  cleanup/${resource}: HTTP ${HTTP}"
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

# Kill any stale cctr-state MCP server on port 3001 from a previous aborted run.
# If left running it serves the last journey's stale test plan to the next run.
_STALE_PID=$(lsof -ti:3001 2>/dev/null || true)
if [[ -n "${_STALE_PID}" ]]; then
  echo "[preflight] Killing stale cctr-state server (PID ${_STALE_PID}) on port 3001"
  kill "${_STALE_PID}" 2>/dev/null || true
  sleep 1
fi

# Step 0b: DocChain stage gate (STRAT-09) — verify docs artefacts before burning test turns.
# Checks 6 gates: USER-SPEC.html, ARCHITECTURE.html, INTEGRATION-MAP.html,
# TEST-ORACLES.html, QUALITY-STANDARDS.html, and snapshot freshness.
# In READ_ONLY mode: advisory only (non-blocking). In ACTIVE mode: non-zero exit blocks run.
# Docs dir resolved relative to product codebase: ${PHRONEX_CODE_ROOT}/<product>/.docs/
# Product slug → repo name mapping (slug != repo name for jp and cc)
declare -A _PRODUCT_REPO_MAP=(["jp"]="jobportal" ["cc"]="contentcompanion")
_PRODUCT_REPO="${_PRODUCT_REPO_MAP[${PRODUCT}]:-${PRODUCT}}"
_DOCS_DIR="${PHRONEX_CODE_ROOT:-/home/ouroborous/code}/${_PRODUCT_REPO}/.docs"
if [[ -d "${_DOCS_DIR}" ]]; then
  echo ""
  echo "[0b/3] DocChain stage gate (STRAT-09, STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
  _GATE_MODE="${STRATEGIST_MODE_OVERRIDE:-${STRATEGIST_MODE:-ACTIVE}}"
  "${PYTHON}" -m phronex_common.docchain.stage_gate \
    --stage pre_run \
    --docs-dir "${_DOCS_DIR}" \
    --product "${PRODUCT}"
  _GATE_EXIT=$?
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
echo "[1a2/3] Pre-run strategist signals (Q1-Q4)..."
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
        answer_ethos_priority, answer_fixture_health,
    )
    _clean_url = _db_url.replace("postgresql+psycopg2://", "postgresql://")
    _conn = psycopg2.connect(_clean_url)
    try:
        q1 = answer_coverage_gap(_product, _conn)
        q2 = answer_yield_trend(_product, _conn)
        q3 = answer_ethos_priority(_product, _conn)
        q4 = answer_fixture_health(_product, _conn)
        print(f"[strategist:pre-run] Q1 coverage_gap={q1:.3f}  Q2 yield_trend={q2:.3f}  Q3 ethos_priority={q3:.3f}  Q4 fixture_health={q4:.3f}", file=sys.stderr)

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

# Step 1: cc-test-runner (wrapped by run_arbiter)
# run_arbiter spawns cc-test-runner as a child, streams its stdout, and
# SIGTERMs the child on abort triggers (3 consecutive fails / >30 min runtime
# / per-journey 5 min hang / >50% network failure rate). On abort it writes
# ${RESULTS_DIR}/abort_reason.json which the pipeline (Step 2) reads to
# suffix qa_journeys.suite_scope with ':aborted'.
echo ""
echo "[1/3] Spawning cc-test-runner (wrapped by run_arbiter)..."
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
  || CC_EXIT=$?
if [[ ${CC_EXIT} -ne 0 ]]; then
  echo "[1/3] cc-test-runner exit=${CC_EXIT} (test failures expected — continuing to pipeline)"
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

echo ""
echo "========================================"
echo "  JourneyHawk COMPLETE"
echo "  cc-test-runner exit : ${CC_EXIT}"
echo "  pipeline exit       : ${PIPE_EXIT}"
echo "  Results dir         : ${RESULTS_DIR}"
echo "  Finished: $(date -Iseconds)"
echo "========================================"

# Exit non-zero only if pipeline failed (test failures are not pipeline errors)
exit ${PIPE_EXIT}
