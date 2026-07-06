#!/usr/bin/env bash
# run-journeyhawk.sh — Single-entry JourneyHawk runner.
# Chains cc-test-runner + phronex_common.testing.runner atomically.
# Claude (as JourneyHawk skill) calls THIS script — never the two steps separately.
#
# The intelligence pipeline lives in phronex_common.testing.runner (version-controlled,
# reusable by all products). This script is a thin launcher only.
#
# Usage:
#   ./run-journeyhawk.sh [flags] <product-slug> <spec-file> [results-dir]
#
# Flags MUST appear BEFORE the positional args (product-slug, spec-file, results-dir):
#   --llm-oauth    Force all LLM calls through Claude OAuth subprocess (claude -p).
#                  $0 cost on Max subscription, ~3-4s extra latency per call.
#                  The JourneyHawk skill MUST always pass this flag.
#   --skip-passed  Skip journeys whose most recent verdict is PASS/PASS_ORACLE.
#                  Trunks (isSharedRoot) and depended-on journeys always run.
#                  Saves LLM budget by not re-running already-proven journeys.
#                  NOTE: MAINTAIN strategy mode auto-sets this — no flag needed.
#   --force-active Override MAINTAIN mode's skip flags. Runs ALL journeys with
#                  full generation + enrichment, treating existing specs as a base.
#                  Use after test infra changes or when you want a full reassessment.
#                  Also triggered automatically when DocChain detects stale artefacts.
#
# Examples (full run with intelligence pipeline):
#   ./run-journeyhawk.sh jp jp-journeys/jp-deep.json
#   ./run-journeyhawk.sh portal portal-journeys/portal-tree.json
#   ./run-journeyhawk.sh --skip-passed comc comc-journeys/comc-deep.json
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

# ---------- Gap-6: concurrency guard — one run per product at a time ----------
# flock is called after PRODUCT is parsed; see below.

# ---------- Gap-1: kill-signal grace — pipeline runs even on SIGTERM/Ctrl-C ----------
_pipeline_ran=0
_TEMP_FILES_TO_CLEAN=()

_run_pipeline() {
  if [[ "${_pipeline_ran}" -eq 1 ]]; then return; fi
  _pipeline_ran=1
  # Cleanup temp spec files before pipeline (avoids leaking mutated spec paths)
  for _f in "${_TEMP_FILES_TO_CLEAN[@]+"${_TEMP_FILES_TO_CLEAN[@]}"}"; do
    rm -f "${_f}" 2>/dev/null || true
  done
  if [[ -z "${RESULTS_DIR:-}" ]] || [[ -z "${PRODUCT:-}" ]]; then
    return  # pipeline not yet reached args parsing — nothing to do
  fi
  echo ""
  echo "[signal] Running intelligence pipeline after signal/abort (Gap-1 grace)..."
  "${PYTHON:-python3}" -m phronex_common.testing.runner \
    --product "${PRODUCT}" \
    --results-dir "${RESULTS_DIR}" \
    --spec-file "${SPEC_FILE}" \
    --merge-depth "${MERGE_DEPTH}" \
    ${_DOCS_DIR:+--docs-dir "${_DOCS_DIR}"} || true
}

trap '_run_pipeline; rm -f "${_TEMP_FILES_TO_CLEAN[@]+"${_TEMP_FILES_TO_CLEAN[@]}"}" 2>/dev/null; true' EXIT
trap '_run_pipeline; exit 0' SIGTERM SIGINT

# ---------- Phase 88 — gate mode for PR merge blocking ----------
GATE_MODE=0

# ---------- skip-passed flag — skip journeys that passed in prior runs ----------
SKIP_PASSED=0
FORCE_ACTIVE=0
MERGE_DEPTH=5

# ---------- Phase 82 STRAT-16 — per-run mode override ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gate-mode)
      GATE_MODE=1
      shift
      continue
      ;;
    --llm-oauth)
      export LLM_OAUTH_MANDATE_ALL=true
      shift
      continue
      ;;
    --skip-passed)
      SKIP_PASSED=1
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
    --force-active)
      FORCE_ACTIVE=1
      shift
      continue
      ;;
    --merge-depth)
      MERGE_DEPTH="$2"
      shift 2
      continue
      ;;
    --merge-depth=*)
      MERGE_DEPTH="${1#*=}"
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

PRODUCT="${1:?Usage: run-journeyhawk.sh [flags] <product-slug> <spec-file> [results-dir]}"
SPEC_FILE="${2:?Usage: run-journeyhawk.sh [flags] <product-slug> <spec-file> [results-dir]}"

# Gap-6: concurrency guard — prevent two runs for same product corrupting results.
_LOCK_FILE="/tmp/journeyhawk-${PRODUCT}.lock"
exec 9>"${_LOCK_FILE}"
flock -n 9 || {
  echo "ERROR: JourneyHawk run already in progress for product '${PRODUCT}'" >&2
  echo "       Lock file: ${_LOCK_FILE}" >&2
  echo "       If no run is active, remove the lock file and retry." >&2
  exit 1
}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${3:-journeys-output/${PRODUCT}-${TIMESTAMP}}"

# Run ID for handoff queue and intelligence pipeline correlation.
export JOURNEYHAWK_RUN_ID="${PRODUCT}-${TIMESTAMP}"
export JOURNEYHAWK_PRODUCT="${PRODUCT}"

# MCPStateServer port — auto-assigned for parallel execution safety.
# Each concurrent JourneyHawk run needs its own port; port collision causes
# cross-product test plan contamination (CC agent gets JP test plan, etc.).
# Range 30010-39999 avoids collisions with known services (3001 was the
# old default, 3002 = portal dev, 3003 = praxis).
if [[ -z "${CCTR_STATE_PORT:-}" ]]; then
  CCTR_STATE_PORT=$(python3 -c "import random; print(random.randint(30010, 39999))")
fi

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

# ─────────────────────────────────────────────────────────────────────────
# Phase 94 (Gap 3): Query qa_strategy_state.mode and auto-set skip flags.
#
# Routing:
#   COLD_START → JOURNEYHAWK_SKIP_GENERATION=1 (no LLM-generated journeys yet)
#   MAINTAIN   → JOURNEYHAWK_SKIP_GENERATION=1 + SKIP_PASSED=1
#                (only re-run regression anchors)
#   EXPAND/FOCUS → no auto-set (run normally)
#
# Fail-open: if PYTHON, DB, or qa_strategy_state row missing → mode='COLD_START'.
# Note: system python3 may not have phronex_common importable (venv-only on
# DevServer); the heredoc's `except Exception` guard prints 'COLD_START' in
# that case, which is the CORRECT fail-open behaviour (do not "fix" it).
# User overrides: if JOURNEYHAWK_SKIP_GENERATION or SKIP_PASSED already set in
# the environment, we honor the user's value (using ${VAR:-default} pattern).
# ─────────────────────────────────────────────────────────────────────────
STRATEGY_MODE="COLD_START"
if [[ -n "${PHRONEX_QA_DATABASE_URL_SYNC:-}" ]] && [[ -n "${JOURNEYHAWK_PRODUCT:-}" ]]; then
  _MODE_OUT=$(python3 - <<'PYEOF' 2>/dev/null || true
import os, sys
try:
    import psycopg2
    from phronex_common.testing._qa_db import clean_dsn
    from phronex_common.testing.runner import _get_product_strategy_mode
except Exception:
    print("COLD_START")
    sys.exit(0)
try:
    conn = psycopg2.connect(clean_dsn(os.environ["PHRONEX_QA_DATABASE_URL_SYNC"]))
except Exception:
    print("COLD_START")
    sys.exit(0)
try:
    print(_get_product_strategy_mode(conn, os.environ["JOURNEYHAWK_PRODUCT"]))
finally:
    try: conn.close()
    except Exception: pass
PYEOF
)
  if [[ -n "${_MODE_OUT}" ]]; then
    STRATEGY_MODE="${_MODE_OUT}"
  fi
fi
echo "[mode] strategy_mode=${STRATEGY_MODE}"

# --force-active: override MAINTAIN's skip flags — treat as full EXPAND run.
if [[ "${FORCE_ACTIVE}" -eq 1 ]]; then
  SKIP_PASSED=0
  JOURNEYHAWK_SKIP_GENERATION=0
  export JOURNEYHAWK_SKIP_GENERATION
  echo "[mode] --force-active: generation ON, skip-passed OFF (full reassessment)"
else
  # MAINTAIN → auto-enable skip-passed (only if user did not pass --skip-passed).
  if [[ "${STRATEGY_MODE}" == "MAINTAIN" ]] && [[ "${SKIP_PASSED}" -eq 0 ]]; then
    SKIP_PASSED=1
    echo "[mode] MAINTAIN: SKIP_PASSED=1 auto-set (regression anchors only)"
  fi

  # COLD_START or MAINTAIN → skip LLM journey generation.
  if [[ "${STRATEGY_MODE}" == "COLD_START" ]] || [[ "${STRATEGY_MODE}" == "MAINTAIN" ]]; then
    JOURNEYHAWK_SKIP_GENERATION="${JOURNEYHAWK_SKIP_GENERATION:-1}"
    export JOURNEYHAWK_SKIP_GENERATION
    echo "[mode] ${STRATEGY_MODE}: JOURNEYHAWK_SKIP_GENERATION=${JOURNEYHAWK_SKIP_GENERATION} (auto-set if unset)"
  fi
fi
export STRATEGY_MODE

# Locate Python with phronex-common installed
VENV="${SCRIPT_DIR}/../phronex-common/.venv/bin/python"
if [[ -f "${VENV}" ]]; then
  PYTHON="${VENV}"
else
  PYTHON=$(command -v python3 || command -v python)
fi
echo "[env] Python: ${PYTHON}"

# ---------- Step 0a-pre: Context Budget Gate (overnight-safety guard) ----------
# Calculates total context that JourneyHawk skill will load (SKILL.md + CLAUDE.md
# files + MEMORY.md + LEARNINGS.md + USER-SPEC.html + TEST-ORACLES.html).
#
# Stream-idle timeouts have been observed when context exceeds ~120K tokens
# (~480KB raw bytes). On YELLOW/RED, this gate AUTO-SLICES large files
# (TEST-ORACLES.html via oracle_slicer, LEARNINGS.md via learnings_slicer)
# then re-measures. Only halts if still RED after auto-slicing.
#
# Tunable via env vars (default GREEN<150KB, YELLOW 150-300KB, RED>=300KB):
#   JOURNEYHAWK_CONTEXT_BUDGET_YELLOW
#   JOURNEYHAWK_CONTEXT_BUDGET_RED
#
# Override (NOT recommended — only for emergency debugging):
#   JOURNEYHAWK_CONTEXT_BUDGET_BYPASS=1
#
# Skip auto-slicing (debugging only):
#   JOURNEYHAWK_CONTEXT_BUDGET_NO_AUTOSLICE=1
echo ""
echo "[0a-pre/budget] Context budget pre-flight for ${PRODUCT}..."
_BUDGET_EXIT=0
"${PYTHON}" -m phronex_common.testing.context_budget --product "${PRODUCT}" || _BUDGET_EXIT=$?

# If GREEN, we're done — proceed.
# If YELLOW or RED, attempt auto-slicing then re-measure.
if [[ "${_BUDGET_EXIT}" -ne 0 ]] && [[ "${JOURNEYHAWK_CONTEXT_BUDGET_NO_AUTOSLICE:-0}" -ne 1 ]]; then
  echo ""
  echo "[0a-pre/budget] Non-GREEN verdict — running auto-slicers..."

  # Map product slug → repo dir (matches context_budget._PRODUCT_REPO_MAP)
  case "${PRODUCT}" in
    praxis)  _REPO_DIR="praxis" ;;
    cc)      _REPO_DIR="contentcompanion" ;;
    jp)      _REPO_DIR="jobportal" ;;
    portal)  _REPO_DIR="phronex-portal" ;;
    comc)    _REPO_DIR="phronex-command-centre" ;;
    website) _REPO_DIR="phronex-website" ;;
    *)       _REPO_DIR="${PRODUCT}" ;;
  esac
  _DOCS_SLICES="${SCRIPT_DIR}/../${_REPO_DIR}/.docs/slices"
  _LEARNINGS_SLICE_OUT="${SCRIPT_DIR}/JOURNEYHAWK-LEARNINGS-${_REPO_DIR}.md"

  # Auto-slice 1: LEARNINGS.md → product-scoped slice
  # Drops other-products' per-product sections. Safe & cheap (always re-runnable).
  echo "[0a-pre/autoslice] LEARNINGS slicer..."
  "${PYTHON}" -m phronex_common.testing.learnings_slicer \
    --product "${PRODUCT}" \
    --out "${_LEARNINGS_SLICE_OUT}" \
    --stats-only 2>&1 | sed 's/^/  /' || true
  # The --stats-only flag suppresses content emission but we still want the file
  # written, so re-run without it suppressing only stdout.
  "${PYTHON}" -m phronex_common.testing.learnings_slicer \
    --product "${PRODUCT}" \
    --out "${_LEARNINGS_SLICE_OUT}" > /dev/null 2>&1 || true

  # Auto-slice 2: TEST-ORACLES.html → journey-scoped slice
  # Reads journey IDs from the spec file and extracts only relevant <section id="ora-X">
  # blocks. The slicer's authoritative resolver scans all tokens in each journey ID
  # against actual oracle sections — no manual feature mapping needed.
  if [[ -f "${SPEC_FILE}" ]]; then
    mkdir -p "${_DOCS_SLICES}"
    echo "[0a-pre/autoslice] Oracle slicer (reading journey IDs from ${SPEC_FILE})..."
    _JOURNEY_IDS=$("${PYTHON}" -c "
import json, sys
try:
    with open('${SPEC_FILE}') as f:
        spec = json.load(f)
    journeys = spec if isinstance(spec, list) else spec.get('journeys', [])
    # Prefer an explicit oracle feature token when a journey declares one
    # (lets opaque IDs like cc-J01 still drive oracle slicing); fall back to id.
    ids = [(j.get('feature') or j.get('id') or '') for j in journeys if (j.get('feature') or j.get('id'))]
    print(','.join(ids))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || true

    if [[ -n "${_JOURNEY_IDS}" ]]; then
      "${PYTHON}" -m phronex_common.testing.oracle_slicer \
        --product "${PRODUCT}" \
        --journeys "${_JOURNEY_IDS}" \
        --out "${_DOCS_SLICES}/TEST-ORACLES-active-journeys.html" 2>&1 | sed 's/^/  /' || true
    else
      echo "  (no journey IDs extracted — skipping oracle slicer)"
    fi
  else
    echo "[0a-pre/autoslice] Spec file not found (${SPEC_FILE}) — skipping oracle slicer"
  fi

  # Re-measure after auto-slicing
  echo ""
  echo "[0a-pre/budget] Re-measuring after auto-slicing..."
  _BUDGET_EXIT=0
  "${PYTHON}" -m phronex_common.testing.context_budget --product "${PRODUCT}" || _BUDGET_EXIT=$?
fi

# Final verdict handling
if [[ "${_BUDGET_EXIT}" -eq 3 ]]; then
  if [[ "${JOURNEYHAWK_CONTEXT_BUDGET_BYPASS:-0}" -eq 1 ]]; then
    echo "[0a-pre/budget] ⚠️  RED verdict bypassed via JOURNEYHAWK_CONTEXT_BUDGET_BYPASS=1"
    echo "[0a-pre/budget] ⚠️  Stream-idle timeout risk accepted by operator"
  else
    echo ""
    echo "⛔ JOURNEYHAWK HALT — context budget RED (even after auto-slicing)"
    echo "   See abort log in /tmp/journeyhawk-${PRODUCT}-aborted-budget-*.json"
    echo "   Suggested fixes are printed above."
    echo "   To bypass (NOT recommended): JOURNEYHAWK_CONTEXT_BUDGET_BYPASS=1 $0 $*"
    exit 3
  fi
elif [[ "${_BUDGET_EXIT}" -eq 1 ]]; then
  echo "[0a-pre/budget] ⚠️  YELLOW verdict — proceeding (under RED threshold)"
else
  echo "[0a-pre/budget] ✅ GREEN — context budget healthy"
fi

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

# --- ComC production-target guard (additive safety gate, added during stabilization) ---
# ComC QA MUST target the LOCAL stack (portal :3002 -> local :8004/:8002). PORTAL_URL
# defaults to production app.phronex.com (correct for CC/JP/Praxis, which have no local
# stack). A ComC run that forgets `PORTAL_URL=http://localhost:3002` silently hits prod:
# trunks pass (qa user exists on prod) but leaves fail against prod data -> misleading ~6/32.
# Fail fast instead of producing a false result.
if [[ "${PRODUCT}" == "comc" ]] && [[ "${PORTAL_URL}" == *"app.phronex.com"* ]] && [[ "${JOURNEYHAWK_ALLOW_PROD_COMC:-0}" != "1" ]]; then
  echo "" >&2
  echo "⛔ ComC QA must target the LOCAL stack, not production (${PORTAL_URL})." >&2
  echo "   ComC has no production QA data; running against prod yields a false ~6/32." >&2
  echo "   Fix:      PORTAL_URL=http://localhost:3002 ./run-journeyhawk.sh comc <spec> <results-dir>" >&2
  echo "   Override: JOURNEYHAWK_ALLOW_PROD_COMC=1  (only if you truly intend a prod run)" >&2
  exit 2
fi
TEMP_SPEC=$(mktemp /tmp/jh-spec-XXXXXX.json)
FILTERED_SPEC=$(mktemp /tmp/jh-spec-filtered-XXXXXX.json)
_SPEC_ACTIVE=$(mktemp /tmp/jh-spec-active-XXXXXX.json)
_TEMP_FILES_TO_CLEAN+=("${TEMP_SPEC}" "${FILTERED_SPEC}" "${_SPEC_ACTIVE}")
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
# Pre-filter: strip journeys with _retired_at or _skip before credential substitution.
# _retired_at: journey permanently removed from suite (curator decision).
# _skip: journey generated from architecture/HLD docs — needs API-level runner, not browser.
# Exception: isSharedRoot trunk journeys are NEVER filtered — they establish
# the browser session that all leaf journeys depend on.
"${PYTHON}" -c "
import json, sys
spec = json.load(open('${SPEC_FILE}'))
active = [j for j in spec if (not j.get('_retired_at') and not j.get('_skip')) or j.get('isSharedRoot')]
json.dump(active, sys.stdout, ensure_ascii=False)
" > "${_SPEC_ACTIVE}" 2>/dev/null || cp "${SPEC_FILE}" "${_SPEC_ACTIVE}"
echo "[pre] Active journeys after filtering retired+skipped: $("${PYTHON}" -c "import json; print(len(json.load(open('${_SPEC_ACTIVE}'))))" 2>/dev/null || echo '?')"
sed \
  -e "s|http://localhost:3002|${PORTAL_URL}|g" \
  -e "s|https://app.phronex.com|${PORTAL_URL}|g" \
  -e "s|http://app.phronex.com|${PORTAL_URL}|g" \
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
  "${_SPEC_ACTIVE}" > "${TEMP_SPEC}"
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
  for resource in instances content-artifacts chat-sessions; do
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
_DOCS_DIR="${PHRONEX_CODE_ROOT:-/home/phronex/code}/${_PRODUCT_REPO}/.docs"
_DOCCHAIN_CHANGED=0
if [[ -d "${_DOCS_DIR}" ]]; then
  echo ""
  echo "[0b/3] DocChain stage gate (STRAT-09, STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
  _GATE_MODE="${STRATEGIST_MODE_OVERRIDE:-${STRATEGIST_MODE:-ACTIVE}}"
  _GATE_EXIT=0
  _GATE_LOG=$(mktemp /tmp/jh-gate-XXXXXX.log)
  _TEMP_FILES_TO_CLEAN+=("${_GATE_LOG}")
  "${PYTHON}" -m phronex_common.docchain.stage_gate \
    --stage pre_run \
    --docs-dir "${_DOCS_DIR}" \
    --product "${PRODUCT}" 2>&1 | tee "${_GATE_LOG}" || _GATE_EXIT=$?
  if [[ ${_GATE_EXIT} -ne 0 ]]; then
    if [[ "${_GATE_MODE}" == "ACTIVE" ]]; then
      echo "[0b/3] DocChain gate: BLOCKED (ACTIVE mode) — aborting run. Fix missing artefacts above." >&2
      exit ${_GATE_EXIT}
    else
      echo "[0b/3] DocChain gate: advisory (non-blocking in ${_GATE_MODE} mode)"
    fi
  fi
  if grep -qE "auto-generated|regenerat" "${_GATE_LOG}" 2>/dev/null; then
    _DOCCHAIN_CHANGED=1
  fi
else
  echo "[0b/3] DocChain stage gate skipped — docs dir not found: ${_DOCS_DIR}"
fi

# MAINTAIN override: if DocChain artefacts were regenerated (= product design shifted),
# force generation ON and skip-passed OFF for this run only.
if [[ "${_DOCCHAIN_CHANGED}" -eq 1 ]] && [[ "${STRATEGY_MODE}" == "MAINTAIN" ]]; then
  echo "[mode] MAINTAIN override: DocChain artefacts changed — running as EXPAND this cycle"
  JOURNEYHAWK_SKIP_GENERATION=0
  export JOURNEYHAWK_SKIP_GENERATION
  SKIP_PASSED=0
fi

# Restore OAuth token for Python LLM calls in journey generation (Step 0b-gen).
# ANTHROPIC_API_KEY was unset above to prevent cc-test-runner from using it.
# The Python intelligence pipeline (journey_generator, business_journey_generator)
# uses phronex_common.llm which needs ANTHROPIC_API_KEY = OAuth access token.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -f "$HOME/.claude/.credentials.json" ]]; then
  _EARLY_OAUTH=$(python3 -c "
import json, sys
try:
    d = json.load(open('$HOME/.claude/.credentials.json'))
    print(d['claudeAiOauth']['accessToken'])
except Exception:
    sys.exit(1)
" 2>/dev/null) && export ANTHROPIC_API_KEY="${_EARLY_OAUTH}" \
  && echo "[env] Restored OAuth token for Python LLM calls"
fi

# ── Pipeline funnel tracking ────────────────────────────────────────────────
# Each stage updates these counters so the final funnel summary is accurate.
_STAGE_BASELINE=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "?")
_STAGE_AFTER_GEN="${_STAGE_BASELINE}"
_STAGE_AFTER_DEPTH="${_STAGE_BASELINE}"
_STAGE_AFTER_RUNFILTER="${_STAGE_BASELINE}"
_STAGE_AFTER_FIXTURE="${_STAGE_BASELINE}"
_STAGE_AFTER_MUTATIONS="${_STAGE_BASELINE}"
_STAGE_GEN_STATUS="skipped"
_STAGE_DEPTH_STATUS="ok"
_STAGE_RUNFILTER_STATUS="ok"
_STAGE_FIXTURE_STATUS="ok"
_STAGE_MUTATIONS_STATUS="ok"

# Step 0b-gen: Journey generation (Phase 92 — coverage gap fill)
# Three signal sources: portal pages, backend endpoint clusters, .docs/ artefacts.
# Identifies features without journey coverage and generates DEEP specs for them.
# Merges with existing spec (existing take precedence). Fail-open: if generation
# fails, original spec used.
echo ""
echo "[0b-gen/3] Journey generation (coverage gap fill + spec cache)..."
if [ "${JOURNEYHAWK_SKIP_GENERATION:-0}" = "1" ]; then
  echo "[0b-gen/3] SKIP: JOURNEYHAWK_SKIP_GENERATION=1 — using original spec without LLM generation"
  _STAGE_GEN_STATUS="skipped (JOURNEYHAWK_SKIP_GENERATION=1)"
else
_GEN_OUTPUT=$(mktemp /tmp/jh-generated-XXXXXX.json)
_DOCS_DIR="${PHRONEX_CODE_ROOT:-${HOME}/code}/${_PRODUCT_REPO}/.docs"
# --existing-spec: the credential-substituted temp copy (for correct journey loading)
# --base-spec:     the stable original spec path (for cache/provenance location)
# Default: LLM enrichment ON — produces BEHAVIORAL-depth journeys (template variables,
# persistence blocks, cross-feature chains). Fail-open: if rate limits hit mid-generation,
# the generator keeps whatever heuristic output was produced (never produces 0 journeys).
# Set JOURNEYHAWK_NO_LLM=1 to force heuristic-only mode (no LLM calls, ~136 DEEP journeys).
_NO_LLM_FLAG=""
if [ "${JOURNEYHAWK_NO_LLM:-0}" = "1" ]; then
  _NO_LLM_FLAG="--no-llm"
  echo "[0b-gen/3] JOURNEYHAWK_NO_LLM=1 — heuristic mode (oracle-driven + inferred flows, no LLM calls)"
else
  echo "[0b-gen/3] LLM enrichment enabled (BEHAVIORAL-depth target; set JOURNEYHAWK_NO_LLM=1 to skip)"
fi
if "${PYTHON}" -m phronex_common.testing.journey_generator \
  --product "${PRODUCT}" \
  --existing-spec "${TEMP_SPEC}" \
  --base-spec "${SPEC_FILE}" \
  --docs-dir "${_DOCS_DIR}" \
  --code-root "${PHRONEX_CODE_ROOT:-${HOME}/code}" \
  --output "${_GEN_OUTPUT}" \
  --max-journeys 250 \
  --min-depth DEEP \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  ${_NO_LLM_FLAG} 2>&1; then
  if [ -s "${_GEN_OUTPUT}" ]; then
    _ORIG_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "?")
    _NEW_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${_GEN_OUTPUT}'))))" 2>/dev/null || echo "?")
    cp "${_GEN_OUTPUT}" "${TEMP_SPEC}"
    echo "[0b-gen/3] Merged: ${_ORIG_COUNT} existing + generated = ${_NEW_COUNT} total journeys"
    _STAGE_AFTER_GEN="${_NEW_COUNT}"
    _STAGE_GEN_STATUS="ok (+$(( ${_NEW_COUNT} - ${_ORIG_COUNT} )) generated)"
  else
    echo "[0b-gen/3] WARN: generation produced empty output — using original spec"
    _STAGE_GEN_STATUS="WARN: empty output — kept ${_STAGE_BASELINE}"
  fi
else
  echo "[0b-gen/3] WARN: journey generation failed (non-fatal) — using original spec"
  _STAGE_GEN_STATUS="WARN: failed — kept ${_STAGE_BASELINE}"
fi
rm -f "${_GEN_OUTPUT}"
_STAGE_AFTER_GEN=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "${_STAGE_AFTER_GEN}")
fi  # end JOURNEYHAWK_SKIP_GENERATION check

# Step 0b2: Tree optimization — restructure flat dependencies into deep branch trees.
# The journey generator runs optimize_tree() internally, but static-spec journeys
# (dependsOn=trunk) may not get grouped with generated journeys if they were loaded
# separately.  This second pass ensures the MERGED spec is always tree-optimized
# regardless of merge order or cache-hit paths inside the generator.
# Fail-open: if the optimizer raises, TEMP_SPEC is unchanged.
echo ""
echo "[0b2/3] Tree optimization (post-merge)..."
"${PYTHON}" - "${TEMP_SPEC}" <<'TREE_OPT_EOF' || true
import json, sys
spec_path = sys.argv[1] if len(sys.argv) > 1 else ""
if not spec_path:
    sys.exit(0)
try:
    from phronex_common.testing.tree_optimizer import optimize_tree
    spec = json.load(open(spec_path))
    before = len(spec)
    # Count trunk-direct (non-root, non-branch) journeys before optimization
    trunk_id = None
    for j in spec:
        if j.get("isSharedRoot") or j.get("role") == "root":
            trunk_id = j.get("id")
            break
    trunk_direct_before = sum(
        1 for j in spec
        if j.get("dependsOn") == trunk_id
        and j.get("role") not in ("root", "branch")
        and not j.get("isSharedRoot")
    ) if trunk_id else 0
    optimized = optimize_tree(spec)
    after = len(optimized)
    branches_added = after - before
    trunk_direct_after = sum(
        1 for j in optimized
        if j.get("dependsOn") == trunk_id
        and j.get("role") not in ("root", "branch")
        and not j.get("isSharedRoot")
    ) if trunk_id else 0
    rewired = trunk_direct_before - trunk_direct_after
    with open(spec_path, "w") as f:
        json.dump(optimized, f, indent=2)
    if branches_added > 0 or rewired > 0:
        print(f"[0b2/3] Tree optimizer: {branches_added} branches added, {rewired} journeys rewired to branches")
    else:
        print(f"[0b2/3] Tree optimizer: spec already optimized ({after} journeys, 0 changes)")
except Exception as e:
    print(f"[0b2/3] Tree optimizer failed (non-fatal): {e}", file=sys.stderr)
TREE_OPT_EOF
_STAGE_AFTER_GEN=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "${_STAGE_AFTER_GEN}")

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

# Step 0c3: Dependency graph pre-flight validation.
# Validates that every dependsOn ID resolves to a journey in the spec, and that
# every stateOutputPath referenced by a downstream journey is declared by an
# upstream trunk. If a superadmin trunk is missing but a main trunk exists,
# auto-aliases it (cp trunk-main → trunk-superadmin equivalent via spec injection).
# HALTS with a recovery table if any dependency cannot be resolved.
echo ""
echo "[0c3/3] Dependency graph pre-flight..."
TMP_DIR="${TMP_DIR:-/tmp}"
"${PYTHON}" - "${TEMP_SPEC}" "${TMP_DIR}" <<'DEPGRAPH_EOF' || { echo "⛔ Dependency graph pre-flight failed (see above). Fix spec before re-running."; exit 4; }
import json, sys, shutil, pathlib

spec_path = sys.argv[1]
tmp_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp"
spec = json.load(open(spec_path))

all_ids = {j["id"] for j in spec}
# Map: journey ID → stateOutputPath (for trunks that write session files)
state_writers = {j["id"]: j["stateOutputPath"] for j in spec if j.get("stateOutputPath")}

missing_deps = []   # (journey_id, missing_depends_on_id)
unresolved_states = []  # (journey_id, depends_on_id, expected_state_file, resolution)
auto_aliased = []   # (from_path, to_path, reason)

for j in spec:
    dep_id = j.get("dependsOn")
    if not dep_id:
        continue
    if dep_id not in all_ids:
        missing_deps.append((j["id"], dep_id))
    elif dep_id in state_writers:
        state_path = state_writers[dep_id]
        # Check if downstream journey LOADS a stateFile that matches a DIFFERENT trunk
        # (common pattern: journey loads superadmin state but dependsOn=main trunk)
        for step in j.get("steps", []):
            desc = step.get("description", "")
            if "storage_state" in desc.lower() or "storagestate" in desc.lower():
                if "superadmin" in desc.lower() and "superadmin" not in state_path:
                    # Journey expects superadmin state but trunk writes main state
                    superadmin_path = state_path.replace("main", "superadmin")
                    if not pathlib.Path(superadmin_path).exists():
                        # Can we auto-alias? Only safe if main state file exists (will be written by trunk)
                        auto_aliased.append((state_path, superadmin_path,
                            f"journey {j['id']} loads superadmin state but only main trunk declared"))
                break

if missing_deps:
    print("⛔ DEPENDENCY GRAPH ERRORS — journeys reference IDs not in spec:")
    for jid, dep in missing_deps:
        print(f"  Journey: {jid}")
        print(f"    dependsOn: '{dep}' — NOT FOUND in spec")
        print(f"    Fix: add '{dep}' to the spec, or update dependsOn to an existing trunk ID")
    sys.exit(1)

if auto_aliased:
    print(f"[0c3/3] Auto-alias: {len(auto_aliased)} state path(s) will be created from main→superadmin after trunk runs:")
    for src, dst, reason in auto_aliased:
        print(f"  {src} → {dst}")
        print(f"  Reason: {reason}")
    # Write a small shell script that run-arbiter.sh will source after each trunk completion
    alias_script = pathlib.Path(tmp_dir) / "jh-state-aliases.sh"
    with open(alias_script, "w") as f:
        f.write("#!/usr/bin/env bash\n# Auto-generated by dependency graph pre-flight\n")
        for src, dst, _ in auto_aliased:
            f.write(f'[ -f "{src}" ] && [ ! -f "{dst}" ] && cp "{src}" "{dst}" && echo "[alias] Created {dst} from {src}"\n')
    alias_script.chmod(0o755)
    print(f"[0c3/3] Alias script written: {alias_script}")

total = len(spec)
trunks = sum(1 for j in spec if j.get("isSharedRoot") or j.get("role") == "root")
leaves_with_deps = sum(1 for j in spec if j.get("dependsOn"))
print(f"[0c3/3] Graph validated: {total} journeys, {trunks} trunk(s), {leaves_with_deps} with dependsOn — all resolved ✓")
DEPGRAPH_EOF

# Source the auto-alias script after trunk completes (wired into run loop below via env var).
export JH_STATE_ALIAS_SCRIPT="${TMP_DIR}/jh-state-aliases.sh"
# Pre-flight: if alias script exists from a PREVIOUS run (state files already written), apply now.
# This covers re-runs where trunk-main state.json was written by a prior run but superadmin alias missing.
if [[ -f "${JH_STATE_ALIAS_SCRIPT}" ]]; then
  bash "${JH_STATE_ALIAS_SCRIPT}" 2>/dev/null || true
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

# D-10 fix: static-spec journeys always run regardless of SMOKE classification.
# Human-authored journeys should never be silently dropped by the depth gate.
# Retired journeys (_retired_at set) are excluded from the static_ids set so they
# do not receive the "always run" exemption and are dropped by the depth gate.
try:
    static_ids = {j.get('id', '') for j in json.load(open('${SPEC_FILE}'))
                  if not j.get('_retired_at')}
except Exception:
    static_ids = set()

smoke = []
surface = []
kept = []

for j in specs:
    depth = score_journey(j)
    jid = j.get('id', '')
    if depth == DepthLevel.SMOKE:
        if jid in static_ids:
            # Static-spec journey: always run even if SMOKE (D-10)
            # Strip 'depth' — internal classification field, not in cc-test-runner Zod schema
            j.pop('depth', None)
            kept.append(j)
        else:
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
print(f'  Depth gate: {total_original} in → {total_kept} kept ({deep_plus} DEEP+, {len(surface)} SURFACE, {dropped} dropped/deepened)')

# Sanitize before writing: strip non-schema fields (pillar, persistence,
# _depth_warning, etc.) that break cc-test-runner's strict zod schema.
from phronex_common.testing.journey_generator import sanitize_journey_spec
kept = sanitize_journey_spec(kept)

# Write filtered spec back
with open('${TEMP_SPEC}', 'w') as f:
    json.dump(kept, f, indent=2)
" 2>&1 && _STAGE_DEPTH_STATUS="ok" || { echo "[0d/3] WARN: depth enforcement failed (non-fatal, continuing)"; _STAGE_DEPTH_STATUS="WARN: failed"; }
_STAGE_AFTER_DEPTH=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "${_STAGE_AFTER_GEN}")

# Step 0d/3: Write depth classifications to qa_journey_depth_log (Phase 92)
"${PYTHON}" - <<'DEPTH_LOG_EOF' || true
import os, json, sys
db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
run_id = os.environ.get("JOURNEYHAWK_RUN_ID", "")
product = os.environ.get("JOURNEYHAWK_PRODUCT", "")
spec_path = os.environ.get("MUTATED_SPEC") or os.environ.get("TEMP_SPEC", "")
if not db_url or not product or not spec_path:
    sys.exit(0)
try:
    import psycopg2
    from phronex_common.testing._qa_db import clean_dsn
    from phronex_common.testing.depth_scorer import score_journey
    specs = json.load(open(spec_path))
    conn = psycopg2.connect(clean_dsn(db_url))
    with conn.cursor() as cur:
        for j in specs:
            depth = score_journey(j)
            cur.execute(
                "INSERT INTO qa_journey_depth_log "
                "(product_slug, journey_id, run_id, depth_classification, action_taken) "
                "VALUES (%s, %s, %s, %s, %s)",
                (product, j.get("id", "?"), run_id, depth.value, "kept")
            )
    conn.commit()
    conn.close()
    print(f"[0d/3] Depth log: {len(specs)} rows written to qa_journey_depth_log")
except Exception as e:
    print(f"[0d/3] Depth log write failed (non-fatal): {e}", file=sys.stderr)
DEPTH_LOG_EOF

# Step 0e: Strategist run filter (Phase 90)
# Applies depth gate (Reason D) + coverage-based filtering. Writes filtered spec
# to a temp file. If it succeeds, use the filtered spec downstream; otherwise
# continue with the original TEMP_SPEC unchanged (fail-open).
# Exports JH_RUN_FILTER_INCLUDED / JH_RUN_FILTER_SKIPPED for runner.py to
# persist in qa_runs (portal Strategist tab reads these).
# --skip-passed: when the flag is active, adds --skip-passed to the filter CLI
# which skips journeys whose most recent per-journey verdict is PASS/PASS_ORACLE.
# Trunks (isSharedRoot) and dependsOn targets are always included regardless.
echo ""
echo "[0e/3] Strategist run filter (Phase 90)..."
RUN_FILTER_OUTPUT=$(mktemp /tmp/jh-run-filter-XXXXXX.json)
PRE_FILTER_COUNT=$("${PYTHON}" -c "import json,sys; d=json.load(open('${TEMP_SPEC}')); print(len(d) if isinstance(d,list) else 1)" 2>/dev/null || echo "0")
_SKIP_PASSED_FLAG=""
if [[ "${SKIP_PASSED}" == "1" ]]; then
  _SKIP_PASSED_FLAG="--skip-passed"
  echo "[0e/3] --skip-passed active: journeys with PASS/PASS_ORACLE in prior runs will be excluded"
fi
if "${PYTHON}" -m phronex_common.testing.run_filter \
  --product "${PRODUCT}" \
  --spec "${TEMP_SPEC}" \
  --output "${RUN_FILTER_OUTPUT}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  ${_SKIP_PASSED_FLAG} 2>&1; then
  if [ -s "${RUN_FILTER_OUTPUT}" ]; then
    POST_FILTER_COUNT=$("${PYTHON}" -c "import json; print(len(json.load(open('${RUN_FILTER_OUTPUT}'))))" 2>/dev/null || echo "${PRE_FILTER_COUNT}")
    # Debug: preserve run filter output for post-mortem inspection (overwritten each run)
    cp "${RUN_FILTER_OUTPUT}" /tmp/jh-run-filter-last.json 2>/dev/null || true
    cp "${RUN_FILTER_OUTPUT}" "${TEMP_SPEC}"
    export JH_RUN_FILTER_INCLUDED="${POST_FILTER_COUNT}"
    export JH_RUN_FILTER_SKIPPED=$(( PRE_FILTER_COUNT - POST_FILTER_COUNT ))
    echo "[0e/3] Run filter: ${PRE_FILTER_COUNT} in → ${JH_RUN_FILTER_INCLUDED} included, ${JH_RUN_FILTER_SKIPPED} skipped"
    _STAGE_RUNFILTER_STATUS="ok (${JH_RUN_FILTER_INCLUDED} of ${PRE_FILTER_COUNT} selected)"
  else
    echo "[0e/3] WARN: run filter produced empty output — using original spec (all ${PRE_FILTER_COUNT} journeys)"
    _STAGE_RUNFILTER_STATUS="WARN: empty output — all ${PRE_FILTER_COUNT} kept"
  fi
else
  echo "[0e/3] WARN: run filter failed (non-fatal) — using original spec (all ${PRE_FILTER_COUNT} journeys)"
  _STAGE_RUNFILTER_STATUS="WARN: failed — all ${PRE_FILTER_COUNT} kept"
fi
rm -f "${RUN_FILTER_OUTPUT}"
_STAGE_AFTER_RUNFILTER=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "${_STAGE_AFTER_DEPTH}")

# Step 1a-pre: Portal EC2 reachability probe (D-13)
# Runs once before fixture_guard so detect_portal_ec2_reachable can use the
# cached result (PORTAL_EC2_DOWN env var) without reconnecting per journey.
# When EC2 is down: trunk login journey gets SKIP verdict, not FAIL — preventing
# 50+ cascade failures from appearing as legitimate product defects.
_PORTAL_HOST=$(echo "${PORTAL_URL}" | sed 's|https\?://||' | cut -d/ -f1 | cut -d: -f1)
if [[ "${_PORTAL_HOST}" == "localhost" || "${_PORTAL_HOST}" == "127.0.0.1" ]]; then
  export PORTAL_EC2_DOWN="false"
  echo "[1a-pre] Portal EC2 probe: local portal (${_PORTAL_HOST}) — skipping remote check"
elif nc -z -w 5 "${_PORTAL_HOST}" 443 2>/dev/null; then
  export PORTAL_EC2_DOWN="false"
  echo "[1a-pre] Portal EC2 probe: ${_PORTAL_HOST}:443 reachable"
else
  export PORTAL_EC2_DOWN="true"
  echo "[1a-pre] WARN: Portal EC2 probe: ${_PORTAL_HOST}:443 unreachable — trunk journeys will be SKIP not FAIL"
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
_FIXTURE_IN=$("${PYTHON}" -c "import json; print(len(json.load(open('${TEMP_SPEC}'))))" 2>/dev/null || echo "?")
if "${PYTHON}" -m phronex_common.testing.strategist.fixture_guard \
  --spec "${TEMP_SPEC}" \
  --report "${RESULTS_DIR}/fixture-decisions.json" \
  > "${FILTERED_SPEC}"; then
  _FIXTURE_OUT=$("${PYTHON}" -c "import json; print(len(json.load(open('${FILTERED_SPEC}'))))" 2>/dev/null || echo "?")
  _FIXTURE_DROPPED=$(( ${_FIXTURE_IN} - ${_FIXTURE_OUT} )) 2>/dev/null || _FIXTURE_DROPPED="?"
  echo "[1a/3] Fixture guard: ${_FIXTURE_IN} in → ${_FIXTURE_OUT} kept, ${_FIXTURE_DROPPED} dropped (fixture unsatisfied)"
  _STAGE_AFTER_FIXTURE="${_FIXTURE_OUT}"
  _STAGE_FIXTURE_STATUS="ok (${_FIXTURE_OUT} of ${_FIXTURE_IN} passed)"
else
  echo "[1a/3] WARN: fixture guard failed — using pre-filter spec as-is"
  cp "${TEMP_SPEC}" "${FILTERED_SPEC}"
  _STAGE_FIXTURE_STATUS="WARN: failed — all ${_FIXTURE_IN} kept"
  _STAGE_AFTER_FIXTURE="${_FIXTURE_IN}"
fi

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
_TEMP_FILES_TO_CLEAN+=("${MUTATED_SPEC}")
echo ""
echo "[1b/3] Applying wiki mutations (STRATEGIST_MODE=${STRATEGIST_MODE:-ACTIVE})..."
_MUTATIONS_IN=$("${PYTHON}" -c "import json; print(len(json.load(open('${FILTERED_SPEC}'))))" 2>/dev/null || echo "?")
if "${PYTHON}" -m phronex_common.testing.strategist.mutations \
  --spec "${FILTERED_SPEC}" \
  --product "${PRODUCT}" \
  --db-url "${PHRONEX_QA_DATABASE_URL_SYNC:-}" \
  > "${MUTATED_SPEC}"; then
  _MUTATIONS_OUT=$("${PYTHON}" -c "import json; print(len(json.load(open('${MUTATED_SPEC}'))))" 2>/dev/null || echo "${_MUTATIONS_IN}")
  _MUTATIONS_ADDED=$(( ${_MUTATIONS_OUT} - ${_MUTATIONS_IN} )) 2>/dev/null || _MUTATIONS_ADDED="0"
  if [[ "${_MUTATIONS_ADDED}" -gt 0 ]] 2>/dev/null; then
    echo "[1b/3] Wiki mutations: ${_MUTATIONS_IN} journeys → ${_MUTATIONS_OUT} (${_MUTATIONS_ADDED} injected from wiki directives)"
  else
    echo "[1b/3] Wiki mutations: no directives applied (${_MUTATIONS_OUT} journeys unchanged)"
  fi
  _STAGE_AFTER_MUTATIONS="${_MUTATIONS_OUT}"
  _STAGE_MUTATIONS_STATUS="ok"
else
  echo "[1b/3] WARN: mutations applier failed — using filtered spec as-is" >&2
  cp "${FILTERED_SPEC}" "${MUTATED_SPEC}"
  _STAGE_MUTATIONS_STATUS="WARN: failed — kept ${_MUTATIONS_IN}"
  _STAGE_AFTER_MUTATIONS="${_MUTATIONS_IN}"
fi

# Step 1b2: Apply approved heuristics from qa_proposed_heuristics (Phase 93)
# Appends verification steps to matching journeys for approved PROPOSED_INVARIANTS.
# Fail-open: if function raises, MUTATED_SPEC unchanged.
"${PYTHON}" - <<'APPROVED_HEURISTICS_EOF' || true
import os, json, sys
db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
product = os.environ.get("JOURNEYHAWK_PRODUCT", "")
spec_path = os.environ.get("MUTATED_SPEC", "")
if not db_url or not product or not spec_path:
    sys.exit(0)
try:
    from phronex_common.testing.strategist.approved_heuristics import apply_approved_heuristics
    spec = json.load(open(spec_path))
    before = sum(len(j.get("steps", [])) for j in spec)
    mutated = apply_approved_heuristics(product, spec, db_url=db_url)
    after = sum(len(j.get("steps", [])) for j in mutated)
    added = after - before
    if added > 0:
        with open(spec_path, "w") as f:
            json.dump(mutated, f, indent=2)
        print(f"[1b2/3] Approved heuristics: {added} verification steps appended")
    else:
        print("[1b2/3] Approved heuristics: no matching journeys (0 steps added)")
except Exception as e:
    print(f"[1b2/3] Approved heuristics failed (non-fatal): {e}", file=sys.stderr)
APPROVED_HEURISTICS_EOF

# Step 1c: Second-pass substitution on MUTATED_SPEC.
# The sed at line 318 only runs on the baseline spec.  Generated + enriched
# journeys (step 0b-gen) and wiki-injected steps (step 1b) are added AFTER
# that initial sed, so any localhost:3002 references AND credential placeholders
# they carry leak through.  This pass catches them all.
sed -i \
  -e "s|http://localhost:3002|${PORTAL_URL}|g" \
  -e "s|https://app.phronex.com|${PORTAL_URL}|g" \
  -e "s|http://app.phronex.com|${PORTAL_URL}|g" \
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
  "${MUTATED_SPEC}"

# ── Pipeline funnel summary ──────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Pipeline Funnel — ${PRODUCT}"
echo "============================================================"
echo "  Stage                  In       Out      Status"
echo "  ─────────────────────────────────────────────────────────"
printf "  %-22s %-8s %-8s %s\n" "Baseline (spec file)"    "${_STAGE_BASELINE}"       "${_STAGE_BASELINE}"       "source spec"
printf "  %-22s %-8s %-8s %s\n" "0b-gen  (generation)"    "${_STAGE_BASELINE}"       "${_STAGE_AFTER_GEN}"      "${_STAGE_GEN_STATUS}"
printf "  %-22s %-8s %-8s %s\n" "0d      (depth gate)"    "${_STAGE_AFTER_GEN}"      "${_STAGE_AFTER_DEPTH}"    "${_STAGE_DEPTH_STATUS}"
printf "  %-22s %-8s %-8s %s\n" "0e      (run filter)"    "${_STAGE_AFTER_DEPTH}"    "${_STAGE_AFTER_RUNFILTER}" "${_STAGE_RUNFILTER_STATUS}"
printf "  %-22s %-8s %-8s %s\n" "1a      (fixture guard)" "${_STAGE_AFTER_RUNFILTER}" "${_STAGE_AFTER_FIXTURE}"  "${_STAGE_FIXTURE_STATUS}"
printf "  %-22s %-8s %-8s %s\n" "1b      (wiki mutations)" "${_STAGE_AFTER_FIXTURE}"  "${_STAGE_AFTER_MUTATIONS}" "${_STAGE_MUTATIONS_STATUS}"
echo "  ─────────────────────────────────────────────────────────"
printf "  %-22s          %-8s %s\n" "FINAL for cc-test-runner" "${_STAGE_AFTER_MUTATIONS}" "journeys queued"
echo "============================================================"
echo ""

# Step 0.9: Pre-run time forecast — warn operator if estimated runtime exceeds cap.
# Reads journey count from spec + historical avg from qa_journeys.
# If forecast > max_runtime: prints warning and waits 60s for operator to Ctrl-C.
# If JOURNEYHAWK_SKIP_FORECAST=1: skips interactive wait (for CI / non-TTY runs).
# STRATEGIST_ABORT_MAX_RUNTIME_SEC is set dynamically from the forecast below.
# Operator may override by setting the env var before invoking this script.
export _OPERATOR_CAP="${STRATEGIST_ABORT_MAX_RUNTIME_SEC:-}"
echo ""
echo "[0.9/3] Pre-run time forecast..."
_FORECAST_CAP_FILE="$(mktemp /tmp/jh-forecast-cap.XXXXXX)"
"${PYTHON}" - "${_FORECAST_CAP_FILE}" <<FORECAST_EOF || true
import json, os, sys, time

cap_file = sys.argv[1] if len(sys.argv) > 1 else ""
spec_path = os.environ.get("MUTATED_SPEC", "") or os.environ.get("SPEC_FILE", "")
operator_cap = os.environ.get("_OPERATOR_CAP", "")  # non-empty = operator override
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

# Historical avg per journey from qa_runs (last 5 non-aborted runs for this product).
# runner_duration_sec / journeys_run gives real seconds-per-journey.
# Falls back to 120s if no data or DB unreachable.
avg_sec = 120.0  # conservative fallback: 2 min per journey
db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
if db_url and product:
    try:
        import psycopg2
        clean = db_url.replace("postgresql+psycopg2://", "postgresql://").replace("postgresql+asyncpg://", "postgresql://")
        conn = psycopg2.connect(clean)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT runner_duration_sec, journeys_run FROM qa_runs "
                "WHERE product_slug = %s "
                "  AND suite_scope NOT LIKE '%%:aborted' "
                "  AND runner_duration_sec IS NOT NULL "
                "  AND journeys_run > 0 "
                "ORDER BY started_at DESC LIMIT 5",
                (product,),
            )
            rows = cur.fetchall()
        conn.close()
        if rows:
            per_journey = [dur / count for dur, count in rows if count > 0]
            if per_journey:
                avg_sec = sum(per_journey) / len(per_journey)
    except Exception:
        pass

if journey_count == 0:
    fallback = float(operator_cap) if operator_cap else 10800.0
    print(f"  Journey count: unknown (spec parse failed) — using cap={fallback:.0f}s")
    if cap_file:
        open(cap_file, "w").write(str(int(fallback)))
    sys.exit(0)

estimated_sec = journey_count * avg_sec
# Overall runtime cap is DISABLED (0 = no cap).
# Silence timeout (STRATEGIST_ABORT_SILENCE_SEC=900) kills stuck processes only.
if operator_cap:
    max_runtime = float(operator_cap)
    cap_source = "operator override"
else:
    max_runtime = 0
    cap_source = "disabled (silence timeout protects against stuck processes)"

silence_sec = int(os.environ.get("STRATEGIST_ABORT_SILENCE_SEC", "900") or 900)
per_journey_sec = int(os.environ.get("STRATEGIST_ABORT_PER_JOURNEY_SEC", "0") or 0)

# Write computed cap back to shell
if cap_file:
    open(cap_file, "w").write(str(int(max_runtime)))

estimated_min = estimated_sec / 60

print(f"  Journeys in spec : {journey_count}")
print(f"  Avg per journey  : ~{avg_sec:.0f}s (historical)")
print(f"  Estimated total  : ~{estimated_min:.0f} min  ({estimated_sec:.0f}s)")
print(f"  Runtime cap      : {cap_source}")
print(f"  Silence timeout  : {silence_sec}s (kills stuck processes only)")
if per_journey_sec > 0:
    print(f"  Per-journey cap  : {per_journey_sec}s (one hung journey can't poison the suite)")
else:
    print(f"  Per-journey cap  : disabled (set STRATEGIST_ABORT_PER_JOURNEY_SEC to enable)")
print(f"  ✓ No runtime caps — genuinely running journeys will complete.")
FORECAST_EOF
_FORECAST_EXIT=$?
# Read the cap computed by the forecast (or operator override) back into the shell
if [[ -s "${_FORECAST_CAP_FILE}" ]]; then
  export STRATEGIST_ABORT_MAX_RUNTIME_SEC="$(cat "${_FORECAST_CAP_FILE}")"
fi
rm -f "${_FORECAST_CAP_FILE}"
if [[ ${_FORECAST_EXIT} -eq 99 ]]; then
  echo "[0.9/3] Operator aborted before run. Exiting."
  exit 1
fi

# Step 0.95: Start real-time verdict sink.
# Writes qa_journey_verdicts rows as each journey completes — durable even if
# Step 2 crashes. The sink starts without a run_id (buffering verdicts) and
# runner.py registers the qa_runs UUID via PUT /register-run-id at the top of
# Step 2. The sink process is killed after Step 2 completes.
_SINK_PORT_FILE="$(mktemp /tmp/jh-verdict-sink-port.XXXXXX)"
_SINK_PID=""
export JOURNEYHAWK_VERDICT_SINK_URL=""
if [[ -n "${PHRONEX_QA_DATABASE_URL_SYNC:-}" ]]; then
  "${PYTHON}" -m phronex_common.testing.verdict_sink \
    --product "${PRODUCT}" \
    --port-file "${_SINK_PORT_FILE}" \
    > /tmp/jh-verdict-sink-${PRODUCT}.log 2>&1 &
  _SINK_PID=$!
  # Poll until port-file is written (sink is ready) — max 5s
  for _i in 1 2 3 4 5; do
    if [[ -s "${_SINK_PORT_FILE}" ]]; then break; fi
    sleep 1
  done
  if [[ -s "${_SINK_PORT_FILE}" ]]; then
    export JOURNEYHAWK_VERDICT_SINK_URL="http://127.0.0.1:$(cat "${_SINK_PORT_FILE}")"
    echo "[0.95/3] Verdict sink started (${JOURNEYHAWK_VERDICT_SINK_URL})"
  else
    echo "[0.95/3] Verdict sink startup timeout — continuing without real-time verdicts"
    kill "${_SINK_PID}" 2>/dev/null || true
    _SINK_PID=""
  fi
else
  echo "[0.95/3] Verdict sink skipped (no PHRONEX_QA_DATABASE_URL_SYNC)"
fi
rm -f "${_SINK_PORT_FILE}"

# === Phase 95 Gap-B: Non-browser journey dispatch ===
# Dispatches non-browser journeys (http/db executors) from MUTATED_SPEC before
# Playwright runs. Results land in qa_non_browser_results for the current run_id.
# Fail-open: if the module is absent or DB unreachable, continues with 0 results.
echo ""
echo "[0b/3] Dispatching non-browser journeys (Phase 95 Gap-B)..."
"${PYTHON}" - <<'NON_BROWSER_EOF' || true
import os, sys

_db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
_run_id = os.environ.get("JOURNEYHAWK_RUN_ID", "")
_spec   = os.environ.get("MUTATED_SPEC", "")
_product = os.environ.get("PRODUCT", "")

if not _db_url or not _run_id or not _spec:
    print("[non_browser] skipped: missing DB URL, RUN_ID, or MUTATED_SPEC", file=sys.stderr)
    sys.exit(0)

try:
    import json
    from pathlib import Path
    journeys = json.loads(Path(_spec).read_text())
    nb_journeys = [j for j in journeys if j.get("executor") in ("http", "db")]
    if not nb_journeys:
        print(f"[non_browser] 0 non-browser journeys in spec — skipping dispatch", file=sys.stderr)
        sys.exit(0)

    from phronex_common.testing.non_browser_runner import dispatch_non_browser_journeys
    import psycopg2
    from phronex_common.testing._qa_db import clean_dsn
    _conn = psycopg2.connect(clean_dsn(_db_url))
    try:
        results_written = dispatch_non_browser_journeys(
            conn=_conn,
            run_id=_run_id,
            product_slug=_product,
            journeys=nb_journeys,
        )
        print(f"[non_browser] dispatched {len(nb_journeys)} journeys → {results_written} results written", file=sys.stderr)
    finally:
        _conn.close()
except ImportError:
    print("[non_browser] dispatch skipped: non_browser_runner not available (fail-open)", file=sys.stderr)
except Exception as _e:
    print(f"[non_browser] WARNING: dispatch failed (non-fatal): {_e}", file=sys.stderr)
NON_BROWSER_EOF
# === End Phase 95 Gap-B non-browser dispatch ===

# Step 0.96: Per-journey dynamic maxTurns injection.
# Computes a turn budget per journey based on step count × depth multiplier and
# writes it back into MUTATED_SPEC as a "maxTurns" field.  The cc-test-runner
# Zod schema accepts this field and passes it to claude --max-turns, overriding
# the CLI-level --maxTurns 150 ceiling for journeys that need more or less budget.
#
# Formula: budget = max(30, min(250, round(15 × steps × depth_multiplier)))
# Depth multipliers: SMOKE=0.5, SURFACE=1.0, DEEP=1.5, BEHAVIORAL=2.0
# Trunk journeys (isSharedRoot): fixed 40 turns (login + storage capture only)
echo ""
echo "[0.96/3] Injecting per-journey turn budgets..."
"${PYTHON}" - <<'TURN_BUDGET_EOF' || true
import json, os, re, sys

spec_path = os.environ.get("MUTATED_SPEC", "")
if not spec_path:
    print("[turn_budget] skipped: MUTATED_SPEC not set", file=sys.stderr)
    sys.exit(0)

try:
    with open(spec_path) as f:
        journeys = json.load(f)
except Exception as e:
    print(f"[turn_budget] skipped: could not read spec — {e}", file=sys.stderr)
    sys.exit(0)

# Depth multipliers
DEPTH_MULTIPLIER = {"SMOKE": 0.5, "SURFACE": 1.0, "DEEP": 1.5, "BEHAVIORAL": 2.0}
TURNS_PER_STEP = 15
MIN_TURNS = 30
MAX_TURNS = int(os.environ.get("JOURNEYHAWK_MAX_TURNS_CAP", "250"))
TRUNK_TURNS = 40

# Minimal depth classifier (mirrors phronex_common.testing.depth_scorer logic)
PASSIVE_KW = {"navigate", "goto", "go to", "waitfor", "wait_for", "wait for",
              "verify", "assert", "check", "expect", "see", "observe",
              "screenshot", "capture"}
ACTIVE_KW = {"click", "fill", "type", "submit", "select", "upload", "press",
             "toggle", "drag", "drop", "input", "enter", "choose", "pick",
             "scroll", "swipe", "tap"}
PERSIST_KW = {"persistence", "persist", "navigate_away", "reload", "refresh",
              "re-assert", "reassert", "still visible", "still present",
              "still exists", "data saved", "saved successfully"}
TPL_VAR = re.compile(r"\{\{.*?\}\}")

def classify_depth(journey):
    if journey.get("isSharedRoot") or journey.get("is_shared_root"):
        return "DEEP"
    steps = journey.get("steps", [])
    if not steps:
        return "SMOKE"
    if any(s.get("human_required") for s in steps):
        return "DEEP"
    def step_text(s):
        parts = []
        for k in ("action", "type", "description", "instruction", "name"):
            v = s.get(k)
            if isinstance(v, str):
                parts.append(v)
        return " ".join(parts).lower()
    texts = [step_text(s) for s in steps]
    full = " ".join(texts)
    has_active = any(any(kw in t for kw in ACTIVE_KW) for t in texts)
    has_persist = any(kw in full for kw in PERSIST_KW) or journey.get("persistence") is not None
    has_tpl = bool(TPL_VAR.search(full))
    interactive = sum(1 for t in texts if any(kw in t for kw in ACTIVE_KW))
    nav_count = sum(1 for t in texts if any(kw in t for kw in {"navigate", "goto", "go to"}))
    assert_count = sum(1 for t in texts if any(kw in t for kw in {"verify", "assert", "check", "expect"}))
    if interactive >= 5 and has_tpl:
        return "BEHAVIORAL"
    if has_active and has_persist:
        return "DEEP"
    if has_active and len(steps) >= 3 and nav_count >= 2 and assert_count >= 1:
        return "DEEP"
    if has_active:
        return "SURFACE"
    return "SMOKE"

updated = 0
budget_log = []
for j in journeys:
    jid = j.get("id", "?")
    if j.get("isSharedRoot") or j.get("is_shared_root"):
        budget = TRUNK_TURNS
        depth = "TRUNK"
    else:
        depth = classify_depth(j)
        mult = DEPTH_MULTIPLIER.get(depth, 1.0)
        steps = len(j.get("steps", []))
        budget = max(MIN_TURNS, min(MAX_TURNS, round(TURNS_PER_STEP * steps * mult)))
    old = j.get("maxTurns")
    if old != budget:
        j["maxTurns"] = budget
        updated += 1
    budget_log.append(f"  {jid}: {depth} × {len(j.get('steps',[]))} steps → {budget} turns")

with open(spec_path, "w") as f:
    json.dump(journeys, f, indent=2)

print(f"[turn_budget] {updated}/{len(journeys)} journeys updated", file=sys.stderr)
for line in budget_log:
    print(line, file=sys.stderr)
TURN_BUDGET_EOF

# Step 1: cc-test-runner (wrapped by run_arbiter)
# run_arbiter spawns cc-test-runner as a child, streams its stdout, and
# SIGTERMs the child on abort triggers (3 consecutive fails / >30 min runtime
# / per-journey 5 min hang / >50% network failure rate). On abort it writes
# ${RESULTS_DIR}/abort_reason.json which the pipeline (Step 2) reads to
# suffix qa_journeys.suite_scope with ':aborted'.
# Re-unset ANTHROPIC_API_KEY before cc-test-runner — it uses Claude OAuth, not API key.
unset ANTHROPIC_API_KEY

# Start background state-alias watcher: polls for trunk state files and creates aliases.
# Runs every 5 seconds. Exits when the runner finishes (on SIGTERM from trap below).
if [[ -f "${JH_STATE_ALIAS_SCRIPT}" ]]; then
  (
    while true; do
      bash "${JH_STATE_ALIAS_SCRIPT}" 2>/dev/null || true
      sleep 5
    done
  ) &
  _ALIAS_WATCHER_PID=$!
  trap 'kill "${_ALIAS_WATCHER_PID}" 2>/dev/null || true' EXIT
  echo "[1/3] State alias watcher started (PID ${_ALIAS_WATCHER_PID})"
fi

echo ""
echo "[1/3] Spawning cc-test-runner (wrapped by run_arbiter, max_runtime=${STRATEGIST_ABORT_MAX_RUNTIME_SEC}s)..."
CC_EXIT=0
_RUNNER_START_SEC=${SECONDS}
"${PYTHON}" -m phronex_common.testing.strategist.run_arbiter \
  --product "${PRODUCT}" \
  --results-dir "${RESULTS_DIR}" \
  --spec "${MUTATED_SPEC}" \
  -- \
  "${SCRIPT_DIR}/cli/cc-test-runner" \
    -t "${MUTATED_SPEC}" \
    -o "${RESULTS_DIR}" \
    --maxTurns 150 \
    --statePort "${CCTR_STATE_PORT}" \
    --model "${JOURNEYHAWK_MODEL:-claude-sonnet-4-6}" \
  || CC_EXIT=$?
export JH_RUNNER_DURATION_SEC=$(( SECONDS - _RUNNER_START_SEC ))
if [[ ${CC_EXIT} -ne 0 ]]; then
  echo "[1/3] cc-test-runner exit=${CC_EXIT} (test failures expected — continuing to pipeline)"
fi
echo "[1/3] cc-test-runner wall-clock: ${JH_RUNNER_DURATION_SEC}s"

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

# === Phase 95 Gap-B: CTRF merge — non-browser results into unified report ===
# Merges qa_non_browser_results rows (written above) into the CTRF report file
# that the intelligence pipeline reads. Fail-open: if no non-browser results or
# the merge module is absent, ctrf-report.json is left as-is (Playwright-only).
echo ""
echo "[1c/3] Merging non-browser results into CTRF report (Phase 95 Gap-B)..."
"${PYTHON}" - <<'CTRF_MERGE_EOF' || true
import os, sys

_db_url  = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", "")
_run_id  = os.environ.get("JOURNEYHAWK_RUN_ID", "")
_results = os.environ.get("RESULTS_DIR", "")

if not _db_url or not _run_id or not _results:
    print("[ctrf_merge] skipped: missing DB URL, RUN_ID, or RESULTS_DIR", file=sys.stderr)
    sys.exit(0)

try:
    import json
    from pathlib import Path

    _ctrf_path = Path(_results) / "ctrf-report.json"
    if not _ctrf_path.exists():
        print("[ctrf_merge] no ctrf-report.json yet — skipping merge", file=sys.stderr)
        sys.exit(0)

    import psycopg2
    from phronex_common.testing._qa_db import clean_dsn
    _conn = psycopg2.connect(clean_dsn(_db_url))
    try:
        with _conn.cursor() as _cur:
            _cur.execute(
                "SELECT journey_id, status, duration_ms, error_detail"
                " FROM qa_non_browser_results"
                " WHERE run_id = %s",
                (_run_id,),
            )
            _nb_rows = _cur.fetchall()
    finally:
        _conn.close()

    if not _nb_rows:
        print("[ctrf_merge] 0 non-browser results — no merge needed", file=sys.stderr)
        sys.exit(0)

    _ctrf = json.loads(_ctrf_path.read_text())
    _tests = _ctrf.setdefault("results", {}).setdefault("tests", [])
    _merged = 0
    for _jid, _status, _dur_ms, _err in _nb_rows:
        _tests.append({
            "name": _jid,
            "status": "passed" if _status == "pass" else "failed",
            "duration": _dur_ms or 0,
            "message": _err or "",
            "suite": "non_browser",
        })
        _merged += 1

    _summary = _ctrf["results"].setdefault("summary", {})
    _summary["tests"] = len(_tests)
    _summary["passed"] = sum(1 for t in _tests if t.get("status") == "passed")
    _summary["failed"] = sum(1 for t in _tests if t.get("status") == "failed")

    _ctrf_path.write_text(json.dumps(_ctrf, indent=2))
    print(f"[ctrf_merge] merged {_merged} non-browser results into {_ctrf_path}", file=sys.stderr)

except ImportError:
    print("[ctrf_merge] skipped: _qa_db not available (fail-open)", file=sys.stderr)
except Exception as _e:
    print(f"[ctrf_merge] WARNING: merge failed (non-fatal): {_e}", file=sys.stderr)
CTRF_MERGE_EOF
# === End Phase 95 Gap-B CTRF merge ===

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

if [[ "${_pipeline_ran}" -eq 0 ]]; then
  # Step 2: intelligence pipeline via phronex_common.testing.runner
  echo ""
  echo "[2/3] Running intelligence pipeline (phronex_common.testing.runner)..."
  "${PYTHON}" -m phronex_common.testing.runner \
    --product "${PRODUCT}" \
    --results-dir "${RESULTS_DIR}" \
    --spec-file "${SPEC_FILE}" \
    --merge-depth "${MERGE_DEPTH}" \
    ${_DOCS_DIR:+--docs-dir "${_DOCS_DIR}"}
  PIPE_EXIT=$?
  _pipeline_ran=1
else
  echo "[2/3] Intelligence pipeline already ran (via signal trap) — skipping duplicate."
  PIPE_EXIT=0
fi

# Teardown verdict sink now that Step 2 is complete.
if [[ -n "${_SINK_PID}" ]]; then
  kill "${_SINK_PID}" 2>/dev/null || true
  _SINK_PID=""
fi

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
