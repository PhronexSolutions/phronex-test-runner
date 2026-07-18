#!/usr/bin/env bash
# refresh-ec2-oauth-key.sh
# Reads the Claude Max OAuth access token from ~/.claude/.credentials.json and
# deploys it as ANTHROPIC_API_KEY to all Phronex services that need it:
#
#   EC2 services (43.204.79.39):
#     - contentcompanion  → /opt/contentcompanion/.env
#     - jobportal         → /opt/jobportal/.env
#     - praxis            → /opt/praxis/.env
#
#   DevServer services (this machine):
#     - command-centre    → /opt/command-centre/.env
#
# Designed to run as a cron job every 20 minutes so services never go dark
# when prepaid API credits are exhausted. Claude Code auto-refreshes its own
# OAuth token internally; this script just syncs the latest token to each service.
#
# Cron entry (installed automatically on first run):
#   */20 * * * * /home/ouroborous/code/phronex-test-runner/refresh-ec2-oauth-key.sh >> /tmp/ec2-oauth-refresh.log 2>&1
#
# RULES:
#   1. One shared health check: all three EC2 services use the same prepaid key.
#      If that key is healthy, skip all EC2 deploys (no unnecessary restarts).
#   2. If the prepaid key is exhausted or an OAuth token is already in place,
#      deploy the OAuth token to all three EC2 services and restart each.
#   3. DevServer ComC always gets the latest token (no prepaid key to protect).
#   4. Forces a claude CLI call first so Claude Code refreshes the OAuth token
#      if it is within 30 minutes of expiry.
#   5. Verifies the token works before deploying to any target.
#   6. Logs all actions to /tmp/ec2-oauth-refresh.log for auditability.
#
# Usage:
#   ./refresh-ec2-oauth-key.sh          # normal run (smart skip if prepaid key OK)
#   ./refresh-ec2-oauth-key.sh --force  # always deploy to all targets

set -euo pipefail
unset ANTHROPIC_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$HOME/.claude/.credentials.json"
# AWSContentCompanion.pem was the Windows-machine key path; on Linux machines
# (this one included) the working key is $PHRONEX_SSH_KEY from
# ~/.phronex-machine.env. Fall back to the old .pem path for compatibility
# with machines that still use it.
SSH_KEY="${PHRONEX_SSH_KEY:-$HOME/code/AWSContentCompanion.pem}"
EC2_HOST="ubuntu@43.204.79.39"
COMC_ENV="/opt/command-centre/.env"
LOG_FILE="/tmp/ec2-oauth-refresh.log"
FORCE="${1:-}"

echo ""
echo "=== EC2 OAuth Key Refresh === $(date '+%Y-%m-%d %H:%M:%S IST')"
echo ""

# ── Step 0: Install cron if not already present ────────────────────────────
# Step 0: Cron entry is managed manually (or via systemd timer).
# Do NOT auto-reinstall here. This script is called by _invoke_refresh_script()
# on every OAuthCredentialsExpired, which would re-arm the cron after Phase 0 disabled it.
# To install: crontab -e and add the desired schedule manually.
echo "[0/5] Cron self-install removed — managed manually (see PLAN.md Step 1.1)"

# ── Step 1: Force Claude Code to refresh OAuth token if near expiry ────────
echo "[1/5] Refreshing OAuth token via claude CLI..."
env -u ANTHROPIC_API_KEY claude -p "ok" --model claude-haiku-4-5-20251001 > /dev/null 2>&1 || true
sleep 2

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
# Claude Max OAuth tokens route through Claude.ai's rate buckets — calling
# api.anthropic.com/v1/messages directly returns rate_limit_error even when
# the token is valid. Use `claude -p` (subprocess) which honours the OAuth
# routing correctly. Fall back to expiry-check only if claude CLI unavailable.
echo "[2/5] Verifying OAuth token via claude CLI..."
RESULT=$(env -u ANTHROPIC_API_KEY claude -p "respond with the single word OK" \
  --model claude-haiku-4-5-20251001 --max-turns 1 2>/dev/null | tr -d '\n' | head -c 10 || echo "")

if echo "$RESULT" | grep -qi "OK"; then
  echo "   Token verified OK (via claude CLI)"
elif [ -n "$ACCESS_TOKEN" ] && python3 -c "
import json, datetime, sys
d = json.load(open('$CREDS_FILE'))
exp_ms = d['claudeAiOauth'].get('expiresAt', 0)
exp = datetime.datetime.fromtimestamp(exp_ms / 1000)
now = datetime.datetime.now()
remaining = (exp - now).total_seconds()
if remaining > 300:
    print(f'Token valid for {int(remaining/60)} more minutes')
    sys.exit(0)
else:
    print(f'Token expires in {int(remaining/60)} min — too close')
    sys.exit(1)
" 2>/dev/null; then
  echo "   Token verified OK (expiry check — CLI gave: '${RESULT:0:50}')"
else
  echo "   ERROR: OAuth token appears expired or invalid."
  echo "   Re-authenticate: claude auth login"
  exit 1
fi

# ── Step 3: EC2 health check (one check covers all three EC2 services) ─────
echo ""
echo "[3/5] EC2 services health check..."
DEPLOY_EC2=true

if [ "$FORCE" != "--force" ]; then
  # Read the current key from contentcompanion (representative — all three share it)
  CURRENT_EC2_KEY=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$EC2_HOST" \
    "grep '^ANTHROPIC_API_KEY=' /opt/contentcompanion/.env | cut -d= -f2-" 2>/dev/null || echo "")

  if [[ "$CURRENT_EC2_KEY" == sk-ant-api03-* ]]; then
    HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST https://api.anthropic.com/v1/messages \
      -H "x-api-key: $CURRENT_EC2_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
      --max-time 10 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
      echo "   Prepaid key is healthy (HTTP 200) — skipping all EC2 deploys. Use --force to override."
      DEPLOY_EC2=false
    else
      echo "   Prepaid key exhausted (HTTP $HEALTH) — deploying OAuth token to all EC2 services..."
    fi
  else
    echo "   EC2 already on OAuth token — refreshing all services with latest..."
  fi
else
  echo "   --force flag set — deploying to all EC2 services"
fi

# ── Step 4: Deploy to EC2 (contentcompanion + jobportal + praxis) ──────────
if [ "$DEPLOY_EC2" = "true" ]; then
  echo ""
  echo "[4/5] Deploying to EC2 (contentcompanion, jobportal, praxis)..."
  ssh -i "$SSH_KEY" -o ConnectTimeout=15 -o BatchMode=yes "$EC2_HOST" bash << ENDSSH
    set -e
    TOKEN="${ACCESS_TOKEN}"
    FORCE_FLAG="${FORCE}"
    TS=\$(date +%Y%m%d_%H%M%S)

    deploy_service() {
      local ENV_FILE="\$1"
      local SERVICE="\$2"

      # Idempotency: skip backup+restart if the deployed token already matches (unless --force)
      local CURRENT_KEY NEW_HASH CUR_HASH
      CURRENT_KEY=\$(sudo grep '^ANTHROPIC_API_KEY=' "\$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")
      NEW_HASH=\$(printf '%s' "\$TOKEN" | sha256sum | cut -d' ' -f1)
      CUR_HASH=\$(printf '%s' "\$CURRENT_KEY" | sha256sum | cut -d' ' -f1)
      if [ "\$NEW_HASH" = "\$CUR_HASH" ] && [ "\$FORCE_FLAG" != "--force" ]; then
        echo "  [skip] \$SERVICE - token unchanged, no restart"
        return 0
      fi

      echo ""
      echo "  → \$SERVICE"
      sudo cp "\$ENV_FILE" "\${ENV_FILE}.bak-\${TS}"
      # Rotate: keep only the 3 most recent backups
      sudo ls -t "\${ENV_FILE}.bak-"* 2>/dev/null | tail -n +4 | sudo xargs -r python3 -c "import sys,os; [os.unlink(p) for p in sys.argv[1:]]" 2>/dev/null || true
      sudo sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=\${TOKEN}|" "\$ENV_FILE"
      sudo systemctl restart "\$SERVICE"
      sleep 4
      STATUS=\$(sudo systemctl is-active "\$SERVICE")
      echo "     Status: \$STATUS"
    }

    deploy_service /opt/contentcompanion/.env contentcompanion
    deploy_service /opt/jobportal/.env jobportal
    deploy_service /opt/praxis/.env praxis
ENDSSH
  echo ""
  echo "   ✅ EC2 services updated: contentcompanion, jobportal, praxis"
else
  echo "[4/5] EC2 deploy skipped (prepaid key healthy)."
fi

# ── Step 5: Deploy to DevServer command-centre ────────────────────────────
echo ""
echo "[5/5] DevServer command-centre target..."
if [ -f "$COMC_ENV" ]; then
  # Idempotency: skip backup+restart if the token already matches (unless --force)
  CURRENT_COMC_KEY=$(grep '^ANTHROPIC_API_KEY=' "$COMC_ENV" 2>/dev/null | cut -d= -f2- || echo "")
  COMC_NEW_HASH=$(printf '%s' "$ACCESS_TOKEN" | sha256sum | cut -d' ' -f1)
  COMC_CUR_HASH=$(printf '%s' "$CURRENT_COMC_KEY" | sha256sum | cut -d' ' -f1)
  if [ "$COMC_NEW_HASH" = "$COMC_CUR_HASH" ] && [ "$FORCE" != "--force" ]; then
    echo "   Token unchanged - skipping ComC restart."
  else
  cp "$COMC_ENV" "${COMC_ENV}.bak-$(date +%Y%m%d_%H%M%S)"
  ls -t "${COMC_ENV}.bak-"* 2>/dev/null | tail -n +4 | xargs -r python3 -c "import sys,os; [os.unlink(p) for p in sys.argv[1:]]" 2>/dev/null || true

  if grep -q '^ANTHROPIC_API_KEY=' "$COMC_ENV"; then
    sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ACCESS_TOKEN}|" "$COMC_ENV"
  else
    echo "ANTHROPIC_API_KEY=${ACCESS_TOKEN}" >> "$COMC_ENV"
  fi

  if sudo systemctl reload command-centre 2>/dev/null; then
    echo "   ComC service reloaded."
  else
    sudo systemctl restart command-centre 2>/dev/null || true
    echo "   ComC service restarted."
  fi
  sleep 3
  COMC_STATUS=$(sudo systemctl is-active command-centre 2>/dev/null || echo "unknown")
  echo "   ✅ DevServer command-centre updated. Status: $COMC_STATUS"
  fi
else
  echo "   ⚠️  $COMC_ENV not found — ComC not installed on this machine, skipping."
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "✅ Done. All services refreshed via OAuth token."
echo "   Token expires: $EXPIRY"
echo "   Next auto-refresh: within 20 minutes via cron"
echo ""
echo "   To restore EC2 permanent prepaid key after topping up credits:"
echo "   1. Go to console.anthropic.com/settings/billing → add credits"
echo "   2. Run: ./refresh-ec2-oauth-key.sh --force"
echo ""
