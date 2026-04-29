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

# Step 1: cc-test-runner
echo ""
echo "[1/2] Spawning cc-test-runner..."
mkdir -p "${RESULTS_DIR}"
"${SCRIPT_DIR}/cli/dist/cc-test-runner" \
  -t "${SPEC_FILE}" \
  -o "${RESULTS_DIR}" \
  --maxTurns 50

CC_EXIT=$?
if [[ ${CC_EXIT} -ne 0 ]]; then
  echo "[1/2] cc-test-runner exit=${CC_EXIT} (test failures expected — continuing to pipeline)"
fi

# Step 2: intelligence pipeline via phronex_common.testing.runner
echo ""
echo "[2/2] Running intelligence pipeline (phronex_common.testing.runner)..."
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
