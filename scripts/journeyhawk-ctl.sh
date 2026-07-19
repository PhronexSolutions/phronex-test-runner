#!/usr/bin/env bash
# journeyhawk-ctl.sh — pause/kill/resume/status control for a running JourneyHawk sprint.
#
# The runner (cli/src/index.ts) checks /tmp/journeyhawk-<id>.control BETWEEN
# journeys only — never mid-journey — so a signal always takes effect after
# the current journey's execution finishes cleanly. <id> is the product slug
# passed to run-journeyhawk.sh (--controlId), matching what index.ts derives.
#
# Usage:
#   ./scripts/journeyhawk-ctl.sh pause  <id>   # stop after current journey, resumable
#   ./scripts/journeyhawk-ctl.sh kill   <id>   # stop after current journey, purge run-transient state
#   ./scripts/journeyhawk-ctl.sh resume <id>   # clear a pause signal (re-invoke run-journeyhawk.sh yourself)
#   ./scripts/journeyhawk-ctl.sh status <id>   # show current signal, if any

set -euo pipefail

ACTION="${1:-}"
ID="${2:-}"

if [[ -z "$ACTION" || -z "$ID" ]]; then
  echo "Usage: $0 {pause|kill|resume|status} <id>" >&2
  exit 1
fi

CONTROL_FILE="/tmp/journeyhawk-${ID}.control"

case "$ACTION" in
  pause)
    echo "PAUSE" > "$CONTROL_FILE"
    echo "[journeyhawk-ctl] PAUSE requested for '${ID}' — will take effect after the current journey finishes."
    ;;
  kill)
    echo "KILL" > "$CONTROL_FILE"
    echo "[journeyhawk-ctl] KILL requested for '${ID}' — will take effect after the current journey finishes, then cleans up run-transient state (browser storageState + entity sidecars)."
    ;;
  resume)
    if [[ -f "$CONTROL_FILE" ]]; then
      rm -f "$CONTROL_FILE"
      echo "[journeyhawk-ctl] Cleared control signal for '${ID}'. Re-invoke run-journeyhawk.sh yourself to continue — resuming relies on --skip-passed against already-recorded phronex_qa verdicts, there is no separate resume flag."
    else
      echo "[journeyhawk-ctl] No control signal set for '${ID}' — nothing to clear."
    fi
    ;;
  status)
    if [[ -f "$CONTROL_FILE" ]]; then
      echo "[journeyhawk-ctl] '${ID}': $(cat "$CONTROL_FILE")"
    else
      echo "[journeyhawk-ctl] '${ID}': running (no control signal set)"
    fi
    ;;
  *)
    echo "Unknown action '${ACTION}'. Usage: $0 {pause|kill|resume|status} <id>" >&2
    exit 1
    ;;
esac
