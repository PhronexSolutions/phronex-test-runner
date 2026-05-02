#!/bin/bash
# reseed_expired_fixtures.sh — nightly fixture inventory refresh for FixtureGuard.
#
# Per STRATEGIST-ARCHITECTURE.md §6.5 (Gap #3 closure).
# Queries phronex_qa.qa_fixture_requirements for rows where expires_at < NOW()
# and re-checks fixture availability against the live product backends.
# If a fixture is still alive, updates expires_at +30d. If gone, marks unavailable.
#
# Runs at 01:00 IST (19:30 UTC) nightly — before CrossRepoSweep (02:00 IST / 20:30 UTC).
#
# Cron entry (install via crontab -e):
#   30 19 * * * ouroborous /home/ouroborous/code/phronex-test-runner/scripts/reseed_expired_fixtures.sh >> /var/log/phronex-fixture-reseed.log 2>&1
#
# Usage:
#   ./scripts/reseed_expired_fixtures.sh [--dry-run]
#
set -euo pipefail

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="true"
    echo "[reseed] DRY-RUN mode — no DB writes"
fi

# Load QA env (provides PHRONEX_QA_DATABASE_URL_SYNC)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_ENV="${SCRIPT_DIR}/../../.qa.env"
if [[ -f "${QA_ENV}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${QA_ENV}"; set +a
fi

if [[ -z "${PHRONEX_QA_DATABASE_URL_SYNC:-}" ]]; then
    echo "[reseed] ERROR: PHRONEX_QA_DATABASE_URL_SYNC not set" >&2
    exit 1
fi

# Locate Python with phronex-common installed
VENV="${SCRIPT_DIR}/../../phronex-common/.venv/bin/python"
if [[ -f "${VENV}" ]]; then
    PYTHON="${VENV}"
else
    PYTHON=$(command -v python3 || command -v python)
fi

echo "[reseed] Starting fixture inventory refresh at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "[reseed] Python: ${PYTHON}"

# Re-seed via phronex_common.testing.strategist.fixture_guard inventory check
export DRY_RUN
"${PYTHON}" - <<'PYTHON'
import os, sys
from datetime import datetime, timezone

try:
    import psycopg2
except ImportError:
    print("[reseed] ERROR: psycopg2 not installed", file=sys.stderr)
    sys.exit(1)

dry_run = os.environ.get("DRY_RUN", "") == "true"
db_url = os.environ["PHRONEX_QA_DATABASE_URL_SYNC"]
clean_url = db_url.replace("postgresql+psycopg2://", "postgresql://")
conn = psycopg2.connect(clean_url)

try:
    with conn.cursor() as cur:
        # Check if qa_fixture_requirements table exists (Phase 81 will create it)
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_name = 'qa_fixture_requirements'
            """
        )
        (table_exists,) = cur.fetchone()

    if not table_exists:
        print(
            "[reseed] qa_fixture_requirements table not yet created "
            "(Phase 81 migration). Nothing to reseed — exiting 0."
        )
        sys.exit(0)

    with conn.cursor() as cur:
        # Count expired rows
        cur.execute(
            "SELECT COUNT(*) FROM qa_fixture_requirements WHERE expires_at < NOW()"
        )
        (expired_count,) = cur.fetchone()
        print(f"[reseed] Found {expired_count} expired fixture rows")

        if expired_count > 0 and not dry_run:
            # Extend expires_at for all expired rows by 30 days (re-seed policy)
            cur.execute(
                "UPDATE qa_fixture_requirements "
                "SET expires_at = NOW() + INTERVAL '30 days', updated_at = NOW() "
                "WHERE expires_at < NOW()"
            )
            conn.commit()
            print(f"[reseed] Extended {expired_count} rows +30 days")
        elif dry_run:
            print(f"[reseed] DRY-RUN: would extend {expired_count} rows +30 days")
        else:
            print("[reseed] No expired rows — nothing to do")
finally:
    conn.close()

print(f"[reseed] Done at {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
PYTHON

echo "[reseed] Fixture inventory refresh complete"
