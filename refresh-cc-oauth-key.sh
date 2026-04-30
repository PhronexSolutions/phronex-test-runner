#!/usr/bin/env bash
# refresh-cc-oauth-key.sh
# Refreshes the Claude OAuth access token and deploys it to EC2 contentcompanion.
# Run this when the token approaches expiry OR when CC widget goes dark again.
#
# Usage: ./refresh-cc-oauth-key.sh
#
# Requirements:
#   - Claude Code logged in via OAuth (claude auth status shows loggedIn: true)
#   - SSH key at ~/code/AWSContentCompanion.pem
#   - ANTHROPIC_API_KEY must NOT be set (or will be unset automatically)

set -euo pipefail
unset ANTHROPIC_API_KEY

CREDS_FILE="$HOME/.claude/.credentials.json"
SSH_KEY="$HOME/code/AWSContentCompanion.pem"
EC2_HOST="ubuntu@43.204.79.39"
EC2_ENV="/opt/contentcompanion/.env"

echo ""
echo "=== CC OAuth Key Refresh ==="
echo ""

# Step 1: Force token refresh by making a real API call via claude CLI
echo "[1/3] Refreshing OAuth token via claude CLI..."
env -u ANTHROPIC_API_KEY claude -p "ok" --model claude-haiku-4-5-20251001 > /dev/null 2>&1 || true
sleep 2

# Step 2: Read the (possibly refreshed) access token
ACCESS_TOKEN=$(python3 -c "
import json
d = json.load(open('$CREDS_FILE'))
o = d['claudeAiOauth']
import datetime
exp = datetime.datetime.fromtimestamp(o['expiresAt']/1000)
print(o['accessToken'])
" 2>/dev/null)

EXPIRY=$(python3 -c "
import json, datetime
d = json.load(open('$CREDS_FILE'))
exp = datetime.datetime.fromtimestamp(d['claudeAiOauth']['expiresAt']/1000)
print(exp.strftime('%Y-%m-%d %H:%M IST'))
" 2>/dev/null)

echo "   Token prefix: ${ACCESS_TOKEN:0:25}..."
echo "   Expires: $EXPIRY"

# Step 3: Verify the token works against Anthropic API
echo "[2/3] Verifying token against Anthropic API..."
RESULT=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ACCESS_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'content' in d else 'FAIL:'+str(d.get('error','')))" 2>/dev/null)

if [ "$RESULT" != "OK" ]; then
  echo "   ERROR: Token verification failed: $RESULT"
  echo "   Run: claude auth login  (to re-authenticate)"
  exit 1
fi
echo "   Token verified OK"

# Step 4: Deploy to EC2
echo "[3/3] Deploying to EC2 contentcompanion..."
ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$EC2_HOST" bash << ENDSSH
  sudo cp $EC2_ENV ${EC2_ENV}.bak-\$(date +%Y%m%d_%H%M%S)
  sudo sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ACCESS_TOKEN}|" $EC2_ENV
  echo "   Key updated. Restarting service..."
  sudo systemctl restart contentcompanion
  sleep 4
  STATUS=\$(sudo systemctl is-active contentcompanion)
  echo "   Service status: \$STATUS"
ENDSSH

echo ""
echo "✅ Done. CC widget restored. Token expires: $EXPIRY"
echo "   Remember to top up prepaid credits and run this again to restore the permanent key:"
echo "   sudo sed -i 's|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=sk-ant-api03-ThNH...|' $EC2_ENV"
echo ""
