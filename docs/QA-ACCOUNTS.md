# QA Test Account Setup

Before running a product's journey suite, verify these accounts exist in the test environment.

## Account Provisioning

All QA test account credentials are stored in `~/code/.qa.env` on DevServer. Never hardcode passwords in spec files or skill files.

**Required env vars per product:**
- `QA_USER_PASSWORD` — standard QA test user password
- `QA_OWNER_PASSWORD` — admin/owner QA test user password
- `PHRONEX_PORTAL_TEST_PASSWORD` — portal superadmin test password
- Product-specific test user passwords (see `.qa.env`)

## JobPortal Test Accounts

Three tiered accounts provisioned on production phronex-auth (as of 2026-04-29). Credentials in `.qa.env`.

- `qa-jp-free@phronex.com` — tier=free
- `qa-jp-standard@phronex.com` — tier=standard
- `qa-jp-pro@phronex.com` — tier=pro

These accounts exist in phronex-auth production (`access_grants` table with complimentary grants). If any account is missing or has the wrong tier, re-provision via `POST /admin/accounts/{id}/complimentary-grant` (superadmin token required) with `{"tier": "<tier>", "duration_days": 3650, "reason": "qa-test"}`.

## Pre-Run Cleanup

**JP cleanup is active:** `JP_TEST_CLEANUP_SDK_KEY` is already set in DevServer's `.qa.env`. Before each run, Step 0 in `run-journeyhawk.sh` wipes test users, jobs, and applications so journeys start from a known clean state. The three QA accounts above are NOT cleaned — only data they create during the run is removed.

**CC cleanup is active:** `CC_TEST_CLEANUP_SDK_KEY` is already set in DevServer's `.qa.env`.

## Resource Verification CLI

```bash
python -m phronex_common.testing.resources verify --product <slug>
python -m phronex_common.testing.resources seed --product <slug>
```
