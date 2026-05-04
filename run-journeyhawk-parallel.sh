#!/usr/bin/env bash
# run-journeyhawk-parallel.sh — Parallel JourneyHawk orchestrator.
#
# Runs N products concurrently, each with its own MCPStateServer port.
# Thin wrapper around run-journeyhawk.sh — no gates are bypassed.
#
# Usage:
#   ./run-journeyhawk-parallel.sh jp cc portal
#   ./run-journeyhawk-parallel.sh --concurrency 3 --stagger 20 jp cc portal
#   ./run-journeyhawk-parallel.sh --all
#
# Each product gets:
#   Port:    3001 + index (jp=3001, cc=3002, portal=3003, ...)
#   Results: journeys-output/parallel-<TIMESTAMP>/<product>-<TIMESTAMP>/
#   Log:     journeys-output/parallel-<TIMESTAMP>/<product>.log
#
# Requires: run-journeyhawk.sh in the same directory, .qa.env sourced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PARALLEL_DIR="journeys-output/parallel-${TIMESTAMP}"

# ── Defaults ──────────────────────────────────────────────────────────────────
CONCURRENCY=2
STAGGER=15
BASE_PORT=3001
PRODUCTS=()

# ── Deterministic port map ────────────────────────────────────────────────────
declare -A PRODUCT_PORT_OFFSET=(
  [jp]=0
  [cc]=1
  [portal]=2
  [praxis]=3
  [comc]=4
  [website]=5
)

# ── Spec discovery: product → spec file ───────────────────────────────────────
find_spec() {
  local product="$1"
  local spec_dir="${SCRIPT_DIR}/${product}-journeys"
  # Prefer *-deep.json, fall back to *-tree.json
  local spec
  spec=$(ls "${spec_dir}"/*-deep.json 2>/dev/null | head -1) || true
  if [[ -z "$spec" ]]; then
    spec=$(ls "${spec_dir}"/*-tree.json 2>/dev/null | head -1) || true
  fi
  echo "$spec"
}

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency)
      CONCURRENCY="$2"; shift 2 ;;
    --stagger)
      STAGGER="$2"; shift 2 ;;
    --all)
      for dir in "${SCRIPT_DIR}"/*-journeys/; do
        slug=$(basename "$dir" | sed 's/-journeys$//')
        spec=$(find_spec "$slug")
        if [[ -n "$spec" ]]; then
          PRODUCTS+=("$slug")
        fi
      done
      shift ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      PRODUCTS+=("$1"); shift ;;
  esac
done

if [[ ${#PRODUCTS[@]} -eq 0 ]]; then
  echo "Usage: $0 [--concurrency N] [--stagger S] [--all] product1 product2 ..."
  echo ""
  echo "Available products (with journey specs):"
  for dir in "${SCRIPT_DIR}"/*-journeys/; do
    slug=$(basename "$dir" | sed 's/-journeys$//')
    spec=$(find_spec "$slug")
    [[ -n "$spec" ]] && echo "  $slug  →  $(basename "$spec")"
  done
  exit 1
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
mkdir -p "${PARALLEL_DIR}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  JourneyHawk Parallel Orchestrator                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Products:    ${PRODUCTS[*]}"
echo "║  Concurrency: ${CONCURRENCY}"
echo "║  Stagger:     ${STAGGER}s between spawns"
echo "║  Results:     ${PARALLEL_DIR}/"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Validate all products have specs before starting any
for product in "${PRODUCTS[@]}"; do
  spec=$(find_spec "$product")
  if [[ -z "$spec" ]]; then
    echo "ERROR: No journey spec found for '${product}' in ${SCRIPT_DIR}/${product}-journeys/"
    exit 1
  fi
done

# ── Worker tracking ──────────────────────────────────────────────────────────
declare -A WORKER_PIDS
declare -A WORKER_SPECS
declare -A WORKER_PORTS
declare -A WORKER_STARTS
declare -A WORKER_EXITS

# Trap: propagate SIGTERM/SIGINT to all children
cleanup() {
  echo ""
  echo "[parallel] Received signal — terminating all workers..."
  for pid in "${WORKER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "[parallel] All workers terminated."
  exit 130
}
trap cleanup SIGINT SIGTERM

# ── Launch workers ───────────────────────────────────────────────────────────
running=0
for i in "${!PRODUCTS[@]}"; do
  product="${PRODUCTS[$i]}"
  spec=$(find_spec "$product")
  offset="${PRODUCT_PORT_OFFSET[$product]:-$i}"
  port=$((BASE_PORT + offset))
  results_dir="${PARALLEL_DIR}/${product}-${TIMESTAMP}"
  log_file="${PARALLEL_DIR}/${product}.log"

  echo "[parallel] Spawning ${product} on port ${port} → ${log_file}"

  CCTR_STATE_PORT=$port \
    "${SCRIPT_DIR}/run-journeyhawk.sh" "$product" "$spec" "$results_dir" \
    > "$log_file" 2>&1 &

  WORKER_PIDS[$product]=$!
  WORKER_SPECS[$product]="$spec"
  WORKER_PORTS[$product]=$port
  WORKER_STARTS[$product]=$(date +%s)
  running=$((running + 1))

  # Concurrency semaphore: if at limit, wait for one to finish
  if [[ $running -ge $CONCURRENCY ]]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi

  # Stagger next spawn to avoid thundering herd
  if [[ $i -lt $((${#PRODUCTS[@]} - 1)) ]]; then
    sleep "$STAGGER"
  fi
done

# ── Wait for all workers to complete ─────────────────────────────────────────
echo ""
echo "[parallel] All workers spawned. Waiting for completion..."
echo ""

for product in "${PRODUCTS[@]}"; do
  pid="${WORKER_PIDS[$product]}"
  wait "$pid" 2>/dev/null
  WORKER_EXITS[$product]=$?
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Parallel Run Summary                                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"

now=$(date +%s)
all_ok=true
for product in "${PRODUCTS[@]}"; do
  exit_code="${WORKER_EXITS[$product]}"
  start="${WORKER_STARTS[$product]}"
  elapsed=$(( now - start ))
  port="${WORKER_PORTS[$product]}"
  log="${PARALLEL_DIR}/${product}.log"

  # Extract defect count from log (runner.py prints this)
  defects=$(grep -oP 'defects_written=\K\d+' "$log" 2>/dev/null | tail -1 || echo "?")
  gaps=$(grep -oP 'gaps_found=\K\d+' "$log" 2>/dev/null | tail -1 || echo "?")

  if [[ "$exit_code" -eq 0 ]]; then
    status="PASS"
  else
    status="FAIL(${exit_code})"
    all_ok=false
  fi

  printf "║  %-10s  port:%-5s  %-10s  gaps:%-3s  defects:%-3s  %ds\n" \
    "$product" "$port" "$status" "$gaps" "$defects" "$elapsed"
done

echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Results: ${PARALLEL_DIR}/"
echo "Logs:    ${PARALLEL_DIR}/*.log"

if $all_ok; then
  echo ""
  echo "All products passed."
  exit 0
else
  echo ""
  echo "Some products had failures — check individual logs."
  exit 1
fi
