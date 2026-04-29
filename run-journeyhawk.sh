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
trap 'rm -f "${TEMP_SPEC}"' EXIT
sed "s|http://localhost:3002|${PORTAL_URL}|g" "${SPEC_FILE}" > "${TEMP_SPEC}"

# Step 0: Pre-run test data cleanup (optional — skipped if SDK key not set)
# Wipes QA test artefacts created by previous runs so journeys start clean.
# Requires these vars in .qa.env:
#   JP_TEST_CLEANUP_SDK_KEY   — must match QA_TEST_CLEANUP_SDK_KEY in /opt/jobportal/.env on EC2
#   PHRONEX_JP_TEST_URL       — defaults to https://jobc.phronex.com
#   PHRONEX_QA_ALLOWED_HOSTS  — must include jobc.phronex.com (production denylist bypass)
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
else
  echo "[0/3] Pre-run cleanup skipped (${PRODUCT}_TEST_CLEANUP_SDK_KEY not set in .qa.env)"
fi

# Step 1: cc-test-runner
echo ""
echo "[1/3] Spawning cc-test-runner..."
mkdir -p "${RESULTS_DIR}"
# Use TEMP_SPEC (URL-substituted) for browser tests; original SPEC_FILE for pipeline.
"${SCRIPT_DIR}/cli/dist/cc-test-runner" \
  -t "${TEMP_SPEC}" \
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
