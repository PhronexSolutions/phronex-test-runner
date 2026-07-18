#!/usr/bin/env bash
# tests/test_path_resolution.sh — regression test for the nested-worktree
# path-resolution bug class in run-journeyhawk.sh.
#
# On 2026-07-18 three separate bugs (QA_ENV, VENV, DOCS_SLICES) all shared ONE
# root cause: paths resolved via ${SCRIPT_DIR}/../X silently break when the script
# runs from a nested git worktree (.claude/worktrees/<name>/ — two dir levels below
# the repo root, not one). Fix 782f4a8 resolves via PHRONEX_CODE_ROOT first,
# falling back to the relative guess only if the primary path is absent.
#
# This test exercises the REAL resolution logic (via `--print-paths`, backed by the
# shared _resolve_phronex_path() helper) from a simulated nested worktree. Any future
# revert of the primary/fallback order at any of the three call sites breaks this test.
#
# Dependency-free (pure bash + coreutils). No LLM, no DB, no JourneyHawk run. < 5s.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/run-journeyhawk.sh"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "FATAL: run-journeyhawk.sh not found at ${SCRIPT}" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc}"
    echo "      expected: ${expected}"
    echo "      actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} (value unexpectedly contains '${needle}': ${haystack})"
    FAILURES=$((FAILURES + 1))
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} (value does NOT contain '${needle}': ${haystack})"
    FAILURES=$((FAILURES + 1))
  fi
}

parse() {
  # parse KEY from KEY=VALUE lines in $1
  local key="$1" out="$2"
  printf '%s\n' "${out}" | grep -E "^${key}=" | head -n1 | cut -d= -f2-
}

# --- Build a fake code root with the PHRONEX_CODE_ROOT targets PRESENT ---
mkdir -p "${WORK}/code/phronex-common/.venv/bin" "${WORK}/code/contentcompanion/.docs/slices"
touch "${WORK}/code/.qa.env"
touch "${WORK}/code/phronex-common/.venv/bin/python"

# --- Build a nested-worktree layout (TWO levels below repo root) and copy the
#     REAL script into it. Copying forces SCRIPT_DIR = the deeply-nested dir,
#     reproducing the bug condition (SCRIPT_DIR derived from BASH_SOURCE). ---
mkdir -p "${WORK}/repo/.claude/worktrees/wt"
cp "${SCRIPT}" "${WORK}/repo/.claude/worktrees/wt/"
NESTED="${WORK}/repo/.claude/worktrees/wt/run-journeyhawk.sh"

# ─── POSITIVE case: primary (PHRONEX_CODE_ROOT) targets present ───
echo "== POSITIVE case: PHRONEX_CODE_ROOT targets present =="
OUT="$(PHRONEX_CODE_ROOT="${WORK}/code" bash "${NESTED}" --print-paths cc)"
P_QA_ENV="$(parse QA_ENV "${OUT}")"
P_VENV="$(parse VENV "${OUT}")"
P_DOCS="$(parse DOCS_SLICES "${OUT}")"

check_eq "QA_ENV resolves to PHRONEX_CODE_ROOT/.qa.env" \
  "${WORK}/code/.qa.env" "${P_QA_ENV}"
check_eq "VENV resolves to PHRONEX_CODE_ROOT python" \
  "${WORK}/code/phronex-common/.venv/bin/python" "${P_VENV}"
check_eq "DOCS_SLICES resolves to PHRONEX_CODE_ROOT contentcompanion slices" \
  "${WORK}/code/contentcompanion/.docs/slices" "${P_DOCS}"

# Core regression assertion: none fell back to the broken nested relative path.
check_not_contains "QA_ENV did NOT use nested-worktree fallback" ".claude/worktrees" "${P_QA_ENV}"
check_not_contains "VENV did NOT use nested-worktree fallback" ".claude/worktrees" "${P_VENV}"
check_not_contains "DOCS_SLICES did NOT use nested-worktree fallback" ".claude/worktrees" "${P_DOCS}"

# ─── NEGATIVE-CONTROL case: primary targets ABSENT → fallback must fire ───
echo "== NEGATIVE-CONTROL case: primary targets absent → SCRIPT_DIR/.. fallback =="
mkdir -p "${WORK}/empty"
OUT2="$(PHRONEX_CODE_ROOT="${WORK}/empty" bash "${NESTED}" --print-paths cc)"
N_QA_ENV="$(parse QA_ENV "${OUT2}")"
N_VENV="$(parse VENV "${OUT2}")"
N_DOCS="$(parse DOCS_SLICES "${OUT2}")"

check_contains "QA_ENV fell back to SCRIPT_DIR/.. path" ".claude/worktrees" "${N_QA_ENV}"
check_contains "VENV fell back to SCRIPT_DIR/.. path" ".claude/worktrees" "${N_VENV}"
check_contains "DOCS_SLICES fell back to SCRIPT_DIR/.. path" ".claude/worktrees" "${N_DOCS}"

# --- Summary ---
echo ""
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "${FAILURES} CHECK(S) FAILED"
  exit 1
fi
