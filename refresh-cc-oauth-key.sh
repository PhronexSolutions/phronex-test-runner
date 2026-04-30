#!/usr/bin/env bash
# refresh-cc-oauth-key.sh
# Reads the Claude Max OAuth access token from ~/.claude/.credentials.json and
# deploys it to EC2 contentcompanion as ANTHROPIC_API_KEY.
#
# Designed to run as a cron job every 4 hours so the CC widget never goes dark
# when prepaid credits are exhausted. Claude Code auto-refreshes its own OAuth
# token internally; this script just syncs the latest token to EC2.
#
# Cron entry (installed automatically on first run):
#   0 */4 * * * /home/ouroborous/code/phronex-test-runner/refresh-cc-oauth-key.sh >> /tmp/cc-oauth-refresh.log 2>&1
#
# RULES:
#   1. Only runs when EC2 contentcompanion is currently using an OAuth token
#      (sk-ant-oat01-...) OR a prepaid key that is exhausted. If the prepaid
#      key is healthy, this script skips the deploy (no unnecessary restarts).
#   2. Forces a claude CLI call first so Claude Code refreshes the OAuth token
#      if it is within 30 minutes of expiry.
#   3. Verifies the token works before deploying.
#   4. Logs all actions to /tmp/cc-oauth-refresh.log for auditability.
#
# Usage:
#   ./refresh-cc-oauth-key.sh          # normal run (smart skip if prepaid OK)
#   ./refresh-cc-oauth-key.sh --force  # always deploy regardless of current key

set -euo pipefail
unset ANTHROPIC_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$HOME/.claude/.credentials.json"
SSH_KEY="$HOME/code/AWSContentCompanion.pem"
EC2_HOST="ubuntu@43.204.79.39"
EC2_ENV="/opt/contentcompanion/.env"
LOG_FILE="/tmp/cc-oauth-refresh.log"
FORCE="${1:-}"

echo ""
echo "=== CC OAuth Key Refresh === $(date '+%Y-%m-%d %H:%M:%S IST')"
echo ""

# ── Step 0: Install cron if not already present ────────────────────────────
CRON_ENTRY="0 */4 * * * ${SCRIPT_DIR}/refresh-cc-oauth-key.sh >> ${LOG_FILE} 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "refresh-cc-oauth-key.sh"; then
  echo "[0/4] Installing cron job (every 4 hours)..."
  (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
  echo "   Cron installed: $CRON_ENTRY"
else
  echo "[0/4] Cron already installed — skipping"
fi

# ── Step 1: Force Claude Code to refresh OAuth token if near expiry ────────
echo "[1/4] Refreshing OAuth token via claude CLI..."
env -u ANTHROPIC_API_KEY claude -p "ok" --model claude-haiku-4-5-20251001 > /dev/null 2>&1 || true
sleep 2

# Read the (now current) access token and expiry
ACCESS_TOKEN=$(python3 -c "
import json
d = json.load(open('$CREDS_FILE'))
print(d['claudeAiOauth']['accessToken'])
" 2>/dev/null)

EXPIRY=$(python3 -c "
import json, datetime
d = json.load(open('$CREDS_FILE'))
exp = datetime.datetime.fromtimestamp(d['claudeAiOauth']['expiresAt']/1000)
print(exp.strftime('%Y-%m-%d %H:%M IST'))
" 2>/dev/null)

echo "   Token prefix: ${ACCESS_TOKEN:0:25}..."
echo "   Expires:      $EXPIRY"

# ── Step 2: Check if EC2 currently needs a refresh ────────────────────────
if [ "$FORCE" != "--force" ]; then
  echo "[2/4] Checking if EC2 prepaid key is healthy..."
  CURRENT_EC2_KEY=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$EC2_HOST" \
    "grep '^ANTHROPIC_API_KEY=' $EC2_ENV | cut -d= -f2-" 2>/dev/null || echo "")

  if [[ "$CURRENT_EC2_KEY" == sk-ant-api03-* ]]; then
    # It's a prepaid key — check if it still has credits
    HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST https://api.anthropic.com/v1/messages \
      -H "x-api-key: $CURRENT_EC2_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
      --max-time 10 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
      echo "   Prepaid key is healthy (HTTP 200) — skipping deploy. Use --force to override."
      echo ""
      echo "✅ No action needed. CC widget running on healthy prepaid key."
      echo ""
      exit 0
    else
      echo "   Prepaid key exhausted (HTTP $HEALTH) — deploying OAuth token..."
    fi
  else
    echo "   EC2 already on OAuth token — refreshing with latest..."
  fi
else
  echo "[2/4] --force flag set — skipping health check"
fi

# ── Step 3: Verify the OAuth token works ──────────────────────────────────
echo "[3/4] Verifying OAuth token against Anthropic API..."
RESULT=$(curl -s \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ACCESS_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  --max-time 15 \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'content' in d else 'FAIL:'+str(d.get('error','')))" 2>/dev/null \
  || echo "FAIL:curl_error")

if [ "$RESULT" != "OK" ]; then
  echo "   ERROR: OAuth token verification failed: $RESULT"
  echo "   The Claude Max subscription may be unavailable or the token is corrupt."
  echo "   Re-authenticate: claude auth login"
  exit 1
fi
echo "   Token verified OK"

# ── Step 4: Deploy to EC2 ─────────────────────────────────────────────────
echo "[4/4] Deploying to EC2 contentcompanion..."
ssh -i "$SSH_KEY" -o ConnectTimeout=15 -o BatchMode=yes "$EC2_HOST" bash << ENDSSH
  # Backup before modifying
  sudo cp $EC2_ENV ${EC2_ENV}.bak-\$(date +%Y%m%d_%H%M%S)
  # Rotate: keep only the 3 most recent backups
  sudo ls -t ${EC2_ENV}.bak-* 2>/dev/null | tail -n +4 | sudo xargs -r rm -f
  # Swap key
  sudo sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ACCESS_TOKEN}|" $EC2_ENV
  # Restart
  sudo systemctl restart contentcompanion
  sleep 5
  STATUS=\$(sudo systemctl is-active contentcompanion)
  echo "   Service status: \$STATUS"
ENDSSH

echo ""
echo "✅ Done. CC widget restored via OAuth token."
echo "   Token expires: $EXPIRY"
echo "   Next auto-refresh: within 4 hours via cron"
echo ""
echo "   To restore permanent prepaid key after topping up credits:"
echo "   1. Go to console.anthropic.com/settings/billing → add credits"
echo "   2. Run: ./refresh-cc-oauth-key.sh --force"
echo "      (or manually: ssh EC2, edit /opt/contentcompanion/.env, restart service)"
echo ""
