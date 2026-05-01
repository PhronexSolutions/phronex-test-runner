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
# Examples:
#   ./run-journeyhawk.sh jp jp-journeys/jp-deep.json
#   ./run-journeyhawk.sh jp jp-journeys/jp-smoke.json jp-journeys/results-smoke-$(date +%Y%m%d)

set -euo pipefail

# cc-test-runner spawns `claude` subprocesses. If ANTHROPIC_API_KEY is set in the
# shell, it takes precedence over OAuth credentials even when the key is exhausted.
# Unset it here so the runner always falls back to ~/.claude/.credentials.json (OAuth /
# Claude Max subscription) which is the correct auth path for DevServer runs.
unset ANTHROPIC_API_KEY

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
_PORTAL_PASS="${PHRONEX_PORTAL_TEST_PASSWORD:-${QA_SUPERADMIN_PASSWORD:-}}"
_PORTAL_EMAIL="${PHRONEX_PORTAL_TEST_EMAIL:-qa-test-journeyhawk@phronex.com}"
_OWNER_EMAIL="${QA_OWNER_EMAIL:-qa-owner@phronex.com}"
_OWNER_PASS="${QA_OWNER_PASSWORD:-}"
_USER_EMAIL="${QA_USER_EMAIL:-qa-user@phronex.com}"
_USER_PASS="${QA_USER_PASSWORD:-}"
sed \
  -e "s|http://localhost:3002|${PORTAL_URL}|g" \
  -e "s|QA_SUPERADMIN_PASSWORD|${_PORTAL_PASS}|g" \
  -e "s|qa-test-journeyhawk@phronex\.com|${_PORTAL_EMAIL}|g" \
  -e "s|QA_OWNER_EMAIL|${_OWNER_EMAIL}|g" \
  -e "s|QA_OWNER_PASSWORD|${_OWNER_PASS}|g" \
  -e "s|QA_USER_EMAIL|${_USER_EMAIL}|g" \
  -e "s|QA_USER_PASSWORD|${_USER_PASS}|g" \
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

# Step 1a: Strategist Block A — fixture_guard pre-filter
# STRATEGIST_MODE controls behaviour (DISABLED|READ_ONLY|ACTIVE; default ACTIVE).
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

# Step 1: cc-test-runner (wrapped by run_arbiter)
# run_arbiter spawns cc-test-runner as a child, streams its stdout, and
# SIGTERMs the child on abort triggers (3 consecutive fails / >30 min runtime
# / per-journey 5 min hang / >50% network failure rate). On abort it writes
# ${RESULTS_DIR}/abort_reason.json which the pipeline (Step 2) reads to
# suffix qa_journeys.suite_scope with ':aborted'.
echo ""
echo "[1/3] Spawning cc-test-runner (wrapped by run_arbiter)..."
"${PYTHON}" -m phronex_common.testing.strategist.run_arbiter \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec "${FILTERED_SPEC}" \
  -- \
  "${SCRIPT_DIR}/cli/dist/cc-test-runner" \
    -t "${FILTERED_SPEC}" \
    -o "${RESULTS_DIR}" \
    --maxTurns 50

CC_EXIT=$?
if [[ ${CC_EXIT} -ne 0 ]]; then
  echo "[1/3] cc-test-runner exit=${CC_EXIT} (test failures expected — continuing to pipeline)"
fi

# Step 2: intelligence pipeline via phronex_common.testing.runner
echo ""
echo "[2/3] Running intelligence pipeline (phronex_common.testing.runner)..."
"${PYTHON}" -m phronex_common.testing.runner \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec-file "${SPEC_FILE}"

PIPE_EXIT=$?

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
