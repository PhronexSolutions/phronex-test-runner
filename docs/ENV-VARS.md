# Environment Variables Reference

All set in `~/code/.qa.env` on DevServer. Loaded by `run-journeyhawk.sh` via `source ../.qa.env`.

| Variable | Required | Purpose |
|----------|----------|---------|
| `PHRONEX_QA_DATABASE_URL_SYNC` | **YES** | psycopg2 connection string to phronex_qa on DevServer |
| `PHRONEX_QA_DATABASE_URL` | YES | Async variant (same DB, `asyncpg` format) |
| `PORTAL_URL` | YES | Target portal URL. Default: `https://app.phronex.com` |
| `PHRONEX_JP_TEST_URL` | product-specific | JP backend test URL (e.g. `http://43.204.79.39:8001`) |
| `PHRONEX_CC_TEST_URL` | product-specific | CC backend test URL (e.g. `http://43.204.79.39:8000`) |
| `QA_USER_PASSWORD` | YES | Standard QA test user password |
| `QA_OWNER_PASSWORD` | YES | Admin/owner QA test user password |
| `PHRONEX_PORTAL_TEST_PASSWORD` | YES | Portal superadmin test password |
| `JP_TEST_CLEANUP_SDK_KEY` | optional | Enables pre-run cleanup for JP (already set) |
| `CC_TEST_CLEANUP_SDK_KEY` | optional | Enables pre-run cleanup for CC (already set) |
| `PHRONEX_QA_JIRA_SINK_ENABLED` | optional | `true` enables auto Jira ticket creation |
| `PHRONEX_QA_JIRA_PROJECT` | optional | Jira project key (currently `PHX`) |
| `PHRONEX_ATLASSIAN_CLOUD_ID` | optional | Atlassian cloud ID for API calls |
| `JIRA_API_TOKEN` | optional | Jira API token for ticket creation |
| `JIRA_USER` | optional | Jira user email (vivek@phronex.com) |
| `PHRONEX_QA_ALLOWED_HOSTS` | optional | Comma-separated hostnames to bypass isolation denylist |
| `PHRONEX_CODE_ROOT` | YES | Workspace root for cross-repo operations |
| `PHRONEX_QA_PROBE_ENABLED` | optional | Enables QA probe router in product backends |
| `PHRONEX_QA_LLM_BUDGET` | optional | Budget cap in USD for strategist LLM assessor per run (default: 0.50) |
| `JWT_SECRET` | YES | Shared JWT secret for QA test tokens |
