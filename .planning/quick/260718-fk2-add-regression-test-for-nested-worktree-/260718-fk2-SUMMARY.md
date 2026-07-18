---
phase: quick-260718-fk2
plan: 01
subsystem: qa-runner
tags: [regression-test, path-resolution, ci, nested-worktree]
requires: []
provides:
  - _resolve_phronex_path() shared helper in run-journeyhawk.sh
  - --print-paths dry-run mode
  - tests/test_path_resolution.sh regression test
  - bash-tests CI job in pull-request.yml
affects:
  - run-journeyhawk.sh
tech-stack:
  added: []
  patterns:
    - Single shared path-resolution helper covers all three formerly-buggy sites + dry-run
key-files:
  created:
    - tests/test_path_resolution.sh
  modified:
    - run-journeyhawk.sh
    - .github/workflows/pull-request.yml
decisions:
  - Used -e (exists) in the helper so one function serves file targets (.qa.env, python binary) and dir targets (product repo) identically
  - Placed --print-paths early-exit BEFORE traps and flag while-loop so the dry-run never touches flock/python/pipeline
metrics:
  duration: ~8m
  completed: 2026-07-18
---

# Phase quick-260718-fk2 Plan 01: Nested-Worktree Path-Resolution Regression Test Summary

Added a fast, CI-wired bash regression test that runs the REAL `run-journeyhawk.sh` path-resolution logic from a simulated nested worktree, backed by a newly-consolidated `_resolve_phronex_path()` helper so the QA_ENV/VENV/DOCS_SLICES bug class cannot silently regress.

## What Was Built

- **Task 1 (`f7cabfe`):** Consolidated the repeated `PHRONEX_CODE_ROOT`-first / `SCRIPT_DIR/..`-fallback pattern (root cause of the 2026-07-18 QA_ENV/VENV/DOCS_SLICES bugs, fixed in 782f4a8) into one `_resolve_phronex_path()` helper. Added a `--print-paths [slug]` early-exit dry-run that prints the three resolved `KEY=VALUE` paths and exits before any traps, flock, python, or pipeline logic. Routed all three real call sites through the helper — byte-identical behavior on normal invocations.
- **Task 2 (`aae200b`):** `tests/test_path_resolution.sh` — copies the real script into a `.claude/worktrees/wt/` layout (two levels below a fake repo root), then asserts (positive case) that resolution uses the `PHRONEX_CODE_ROOT` targets and never falls back to `.claude/worktrees`, and (negative-control) that the `SCRIPT_DIR/..` fallback still fires when primary targets are absent. Dependency-free, < 5s, no LLM/DB/JourneyHawk run.
- **Task 3 (`c7fb5a4`):** Added an independent `bash-tests` job to `.github/workflows/pull-request.yml` (ubuntu-latest, checkout + run the test). Existing `lint-and-check` and `docker-build` jobs and the `on:` triggers unchanged.

## Verification Results

- `bash -n run-journeyhawk.sh` — passes (no syntax regression in the 2159-line script).
- `run-journeyhawk.sh --print-paths cc` — prints exactly three `KEY=VALUE` lines and exits 0 without invoking flock/python/pipeline.
- `bash tests/test_path_resolution.sh` — ALL CHECKS PASSED (exit 0).
- Guard effectiveness: temporarily reverting the helper's primary/fallback order makes the test exit 1 (the negative-control assertions catch it). Reverted copy confirmed to fail, then discarded.
- `pull-request.yml` — valid YAML; contains the `bash-tests` job invoking `tests/test_path_resolution.sh`.

## JourneyHawk Contract Note

Per this repo's CLAUDE.md, `run-journeyhawk.sh` is a JourneyHawk-contract file ("do not unilaterally relax a gate"). The Task 1 change is behavior-preserving: it only consolidates path-resolution mechanics into a shared helper and adds an early-exit dry-run. No gate logic (DocChain gate, intelligence pipeline, run filter, product scope lock, concurrency flock) was altered. The `--print-paths` block exits before any gate is reached.

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

- FOUND: run-journeyhawk.sh (modified)
- FOUND: tests/test_path_resolution.sh (created)
- FOUND: .github/workflows/pull-request.yml (modified)
- FOUND commit: f7cabfe (Task 1)
- FOUND commit: aae200b (Task 2)
- FOUND commit: c7fb5a4 (Task 3)
