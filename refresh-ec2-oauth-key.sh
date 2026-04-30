#!/usr/bin/env bash
# refresh-ec2-oauth-key.sh
# Reads the Claude Max OAuth access token from ~/.claude/.credentials.json and
# deploys it to Phronex services that need ANTHROPIC_API_KEY:
#   - EC2 contentcompanion (CC widget — cc.phronex.com)
#   - DevServer command-centre (ComC — port 8004)
#
# Designed to run as a cron job every 4 hours so services never go dark
# when prepaid API credits are exhausted. Claude Code auto-refreshes its own
# OAuth token internally; this script just syncs the latest token to each service.
#
# Cron entry (installed automatically on first run):
#   0 */4 * * * /home/ouroborous/code/phronex-test-runner/refresh-ec2-oauth-key.sh >> /tmp/ec2-oauth-refresh.log 2>&1
#
# RULES:
#   1. For EC2 CC: skips deploy if the current prepaid key is healthy (HTTP 200).
#      If the prepaid key is exhausted or the service is already on an OAuth token,
#      deploys the latest OAuth token and restarts.
#   2. For ComC: always writes the OAuth token to /opt/command-centre/.env and
#      reloads systemd (ComC has no prepaid key to protect).
#   3. Forces a claude CLI call first so Claude Code refreshes the OAuth token
#      if it is within 30 minutes of expiry.
#   4. Verifies the token works before deploying to either target.
#   5. Logs all actions to /tmp/ec2-oauth-refresh.log for auditability.
#
# Usage:
#   ./refresh-ec2-oauth-key.sh          # normal run (smart skip for CC if prepaid OK)
#   ./refresh-ec2-oauth-key.sh --force  # always deploy to both targets regardless

set -euo pipefail
unset ANTHROPIC_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$HOME/.claude/.credentials.json"
SSH_KEY="$HOME/code/AWSContentCompanion.pem"
EC2_HOST="ubuntu@43.204.79.39"
EC2_ENV="/opt/contentcompanion/.env"
COMC_ENV="/opt/command-centre/.env"
LOG_FILE="/tmp/ec2-oauth-refresh.log"
FORCE="${1:-}"

echo ""
echo "=== EC2 OAuth Key Refresh === $(date '+%Y-%m-%d %H:%M:%S IST')"
echo ""

# ── Step 0: Install cron if not already present ────────────────────────────
CRON_ENTRY="0 */4 * * * ${SCRIPT_DIR}/refresh-ec2-oauth-key.sh >> ${LOG_FILE} 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "refresh-ec2-oauth-key.sh"; then
  echo "[0/5] Installing cron job (every 4 hours)..."
  (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
  echo "   Cron installed: $CRON_ENTRY"
else
  echo "[0/5] Cron already installed — skipping"
fi

# ── Step 1: Force Claude Code to refresh OAuth token if near expiry ────────
echo "[1/5] Refreshing OAuth token via claude CLI..."
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

# ── Step 2: Verify the OAuth token works ──────────────────────────────────
echo "[2/5] Verifying OAuth token against Anthropic API..."
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

# ── Step 3: Deploy to EC2 contentcompanion ────────────────────────────────
echo ""
echo "[3/5] EC2 contentcompanion target..."
DEPLOY_CC=true

if [ "$FORCE" != "--force" ]; then
  CURRENT_EC2_KEY=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$EC2_HOST" \
    "grep '^ANTHROPIC_API_KEY=' $EC2_ENV | cut -d= -f2-" 2>/dev/null || echo "")

  if [[ "$CURRENT_EC2_KEY" == sk-ant-api03-* ]]; then
    HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST https://api.anthropic.com/v1/messages \
      -H "x-api-key: $CURRENT_EC2_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
      --max-time 10 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
      echo "   Prepaid key is healthy (HTTP 200) — skipping CC deploy. Use --force to override."
      DEPLOY_CC=false
    else
      echo "   Prepaid key exhausted (HTTP $HEALTH) — deploying OAuth token to CC..."
    fi
  else
    echo "   EC2 already on OAuth token — refreshing with latest..."
  fi
else
  echo "   --force flag set — skipping health check"
fi

if [ "$DEPLOY_CC" = "true" ]; then
  ssh -i "$SSH_KEY" -o ConnectTimeout=15 -o BatchMode=yes "$EC2_HOST" bash << ENDSSH
    sudo cp $EC2_ENV ${EC2_ENV}.bak-\$(date +%Y%m%d_%H%M%S)
    sudo ls -t ${EC2_ENV}.bak-* 2>/dev/null | tail -n +4 | sudo xargs -r python3 -c "import sys,os; [os.unlink(p) for p in sys.argv[1:]]" 2>/dev/null || true
    sudo sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ACCESS_TOKEN}|" $EC2_ENV
    sudo systemctl restart contentcompanion
    sleep 5
    STATUS=\$(sudo systemctl is-active contentcompanion)
    echo "   CC service status: \$STATUS"
ENDSSH
  echo "   ✅ EC2 contentcompanion updated."
else
  echo "   ✅ EC2 contentcompanion skipped (prepaid key healthy)."
fi

# ── Step 4: Deploy to DevServer command-centre ────────────────────────────
echo ""
echo "[4/5] DevServer command-centre target..."
if [ -f "$COMC_ENV" ]; then
  # Backup first
  cp "$COMC_ENV" "${COMC_ENV}.bak-$(date +%Y%m%d_%H%M%S)"
  # Rotate: keep only the 3 most recent backups
  ls -t "${COMC_ENV}.bak-"* 2>/dev/null | tail -n +4 | xargs -r python3 -c "import sys,os; [os.unlink(p) for p in sys.argv[1:]]" 2>/dev/null || true

  if grep -q '^ANTHROPIC_API_KEY=' "$COMC_ENV"; then
    sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ACCESS_TOKEN}|" "$COMC_ENV"
  else
    echo "ANTHROPIC_API_KEY=${ACCESS_TOKEN}" >> "$COMC_ENV"
  fi

  # Reload systemd env without full restart (systemctl reload if available, else restart)
  if sudo systemctl reload command-centre 2>/dev/null; then
    echo "   ComC service reloaded."
  else
    sudo systemctl restart command-centre 2>/dev/null || true
    echo "   ComC service restarted."
  fi
  sleep 3
  COMC_STATUS=$(sudo systemctl is-active command-centre 2>/dev/null || echo "unknown")
  echo "   ✅ DevServer command-centre updated. Status: $COMC_STATUS"
else
  echo "   ⚠️  $COMC_ENV not found — ComC not installed on this machine, skipping."
fi

# ── Step 5: Summary ────────────────────────────────────────────────────────
echo ""
echo "✅ Done. Services refreshed via OAuth token."
echo "   Token expires: $EXPIRY"
echo "   Next auto-refresh: within 4 hours via cron"
echo ""
echo "   To restore EC2 CC permanent prepaid key after topping up credits:"
echo "   1. Go to console.anthropic.com/settings/billing → add credits"
echo "   2. Run: ./refresh-ec2-oauth-key.sh --force"
echo "      (or manually: ssh EC2, edit /opt/contentcompanion/.env, restart service)"
echo ""
