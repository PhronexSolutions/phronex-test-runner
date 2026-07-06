#!/usr/bin/env bash
# =============================================================================
# setup-qa-env.sh — Idempotent JourneyHawk QA-environment provisioner
# =============================================================================
#
# PURPOSE
#   Capture, in one repeatable script, every piece of QA-environment state that
#   was previously provisioned ad-hoc on the JourneyHawk box. Running this on a
#   fresh (or drifted) machine brings the box to a known-good QA state so that
#   `run-journeyhawk.sh` can execute without manual per-box surgery.
#
#   This script is ADDITIVE and IDEMPOTENT: it only ensures things exist / are
#   aligned. It never drops, narrows, or overwrites unrelated state. Re-running
#   it is always safe.
#
# SECRETS POLICY (hard rule)
#   This script NEVER inlines a secret value. Every credential is read at run
#   time from an existing source of truth:
#     - the product/service `.env` files already on the box, or
#     - environment variables the operator exports before running, or
#     - the canonical KEYS.md vault (PhronexSolutions/PhronexSolutions →
#       secrets/KEYS.md), referenced by path — never copied into this file.
#   No secret is ever echoed to stdout/stderr.
#
# WHAT IT PROVISIONS (four sections)
#   1. .qa.env        — ensures required QA env keys exist (values pulled from
#                       env/vault, NOT inlined). Runner loads this at startup.
#   2. phronex_qa DB  — grants + table/sequence ownership so the runner's
#                       ensure_*() CREATE/ALTER calls succeed as role phronex_qa.
#   3. QA accounts    — box-local phronex_auth: superadmin QA account + a
#                       command-centre cc_ceo/premium grant on a qa-comc-org
#                       instance, PLUS a non-admin manager account
#                       (qa-comc-manager@phronex.com, is_superadmin=false) with a
#                       cc_manager/premium grant on the same instance — used by
#                       JourneyHawk's permission-boundary journeys (idempotent).
#   4. Auth↔ComC align — ensures auth JWT_SECRET == ComC CC_INTERNAL_TOKEN so
#                        grant tokens minted by auth validate at ComC.
#
# USAGE
#   ./scripts/setup-qa-env.sh            # provision everything (idempotent)
#   ./scripts/setup-qa-env.sh --dry-run  # show what would change, write nothing
#   ./scripts/setup-qa-env.sh --check    # alias for --dry-run
#
# PREREQUISITES
#   - PostgreSQL running locally with databases: phronex_qa, phronex_auth
#   - phronex-auth venv present (for canonical bcrypt hash_password)
#   - The following secret sources present on the box (values, not this script):
#       ~/code/.qa.env                       (or exported env)  — QA DSNs, creds
#       ~/code/phronex-auth/.env             — JWT_SECRET
#       ~/code/phronex-command-centre/.env   — CC_INTERNAL_TOKEN
#     If a secret is missing, its owning step is skipped with a clear WARNING
#     and a KEYS.md pointer — the script never fabricates or prints a value.
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=0
case "${1:-}" in
  --dry-run|--check) DRY_RUN=1; echo "[setup-qa-env] DRY-RUN — no writes will be made" ;;
  "") : ;;
  *) echo "Unknown arg: ${1}. Use --dry-run or no args." >&2; exit 2 ;;
esac

run() {
  # Execute a command, or just print it under --dry-run.
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [dry-run] would run: $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Path resolution — no hardcoded home paths (No-Hardcoding invariant).
# SCRIPT_DIR = .../phronex-test-runner/scripts ; CODE_ROOT = its grandparent's
# parent (the workspace root that holds all product repos + .qa.env).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"                 # phronex-test-runner
CODE_ROOT="${PHRONEX_CODE_ROOT:-$(cd "${RUNNER_DIR}/.." && pwd)}"
QA_ENV_FILE="${CODE_ROOT}/.qa.env"                          # runner loads ../.qa.env
AUTH_ENV="${CODE_ROOT}/phronex-auth/.env"
COMC_ENV="${CODE_ROOT}/phronex-command-centre/.env"
AUTH_VENV_PY="${CODE_ROOT}/phronex-auth/.venv/bin/python"

echo "[setup-qa-env] CODE_ROOT     = ${CODE_ROOT}"
echo "[setup-qa-env] QA_ENV_FILE   = ${QA_ENV_FILE}"

# ---------------------------------------------------------------------------
# Small helper: read a KEY's value from a dotenv file WITHOUT printing it.
# Strips optional `export `, surrounding single/double quotes. Echoes value on
# stdout so callers can capture into a variable; never logs it.
# ---------------------------------------------------------------------------
dotenv_get() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 1
  grep -E "^(export[[:space:]]+)?${key}=" "${file}" | head -1 \
    | sed -E "s/^(export[[:space:]]+)?${key}=//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# ===========================================================================
# SECTION 1 — .qa.env: ensure required QA env keys exist
# ===========================================================================
# The runner (run-journeyhawk.sh) sources ${CODE_ROOT}/.qa.env at startup. We
# ensure the file exists and contains the keys the runner references. Values
# come from the operator's environment or the KEYS.md vault — we NEVER inline a
# real secret here. If a required secret is neither in the existing file nor in
# the environment, we write a commented placeholder that points at KEYS.md so a
# human fills it from the vault (the script will not fabricate one).
# ---------------------------------------------------------------------------
echo ""
echo "== Section 1: .qa.env =="

# ensure_qa_env_key KEY  [ENV_VAR_TO_SOURCE_FROM]
#   - If KEY already present in ${QA_ENV_FILE}: leave untouched (idempotent).
#   - Else if a live value is available in the environment (via ENV_VAR or KEY):
#       append `KEY=<value-from-env>` (value never printed to the log).
#   - Else: append a commented KEYS.md pointer so a human supplies it.
ensure_qa_env_key() {
  local key="$1" env_src="${2:-$1}" desc="${3:-}"
  # Create the file on first use with a header (mode 600 — contains secrets).
  if [[ ! -f "${QA_ENV_FILE}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "  [dry-run] would create ${QA_ENV_FILE} (mode 600) with header"
    else
      umask 077
      {
        echo "# .qa.env — JourneyHawk QA environment (secrets; mode 600)."
        echo "# Managed additively by scripts/setup-qa-env.sh."
        echo "# Real values come from KEYS.md (PhronexSolutions/secrets/KEYS.md)"
        echo "# or the operator environment — never committed to git."
        echo ""
      } > "${QA_ENV_FILE}"
      chmod 600 "${QA_ENV_FILE}"
    fi
  fi

  if [[ -f "${QA_ENV_FILE}" ]] && grep -qE "^(export[[:space:]]+)?${key}=" "${QA_ENV_FILE}"; then
    echo "  ok: ${key} already present"
    return 0
  fi

  # Look for a live value in the environment (indirect expansion).
  local live="${!env_src:-}"
  if [[ -n "${live}" ]]; then
    echo "  add: ${key} (value sourced from \$${env_src}; not printed)"
    run bash -c "printf '%s=%s\n' '${key}' \"\${${env_src}}\" >> '${QA_ENV_FILE}'"
  else
    echo "  todo: ${key} not in file or env — writing KEYS.md pointer (fill from vault)"
    run bash -c "printf '# TODO %s — set from KEYS.md / operator env (%s)\n# %s=<from-KEYS.md>\n' '${key}' '${desc}' '${key}' >> '${QA_ENV_FILE}'"
  fi
}

# Non-secret operational defaults — safe to write literally (NOT secrets).
ensure_qa_env_literal() {
  local key="$1" val="$2"
  if [[ -f "${QA_ENV_FILE}" ]] && grep -qE "^(export[[:space:]]+)?${key}=" "${QA_ENV_FILE}"; then
    echo "  ok: ${key} already present"
    return 0
  fi
  echo "  add: ${key}=${val} (non-secret operational default)"
  run bash -c "printf '%s=%s\n' '${key}' '${val}' >> '${QA_ENV_FILE}'"
}

# --- Non-secret operational config -----------------------------------------
# PHRONEX_CODE_ROOT: workspace root the runner + pipeline resolve repos from.
ensure_qa_env_literal "PHRONEX_CODE_ROOT" "${CODE_ROOT}"
# JOURNEYHAWK_STATE_DIR: where JourneyHawk persists cross-run state. Non-secret
# path; default under the runner dir. (Referenced in operator docs; harmless if
# unused by the current runner version.)
ensure_qa_env_literal "JOURNEYHAWK_STATE_DIR" "${RUNNER_DIR}/.jh-state"

# PORTAL_URL guidance — intentionally COMMENTED. PORTAL_URL is passed inline
# per-run (e.g. `PORTAL_URL=http://localhost:3002 ./run-journeyhawk.sh ...`) so
# that QA never accidentally pins production. The runner defaults it to
# https://app.phronex.com only when unset; keep it out of .qa.env so each run
# is explicit about its target.
if [[ -f "${QA_ENV_FILE}" ]] && ! grep -qE '^#[[:space:]]*PORTAL_URL guidance' "${QA_ENV_FILE}"; then
  echo "  add: PORTAL_URL guidance comment (passed inline per-run, not stored)"
  run bash -c "cat >> '${QA_ENV_FILE}' <<'EOF'

# PORTAL_URL guidance: DO NOT set PORTAL_URL here. Pass it inline per run so QA
# never silently targets production, e.g.:
#   PORTAL_URL=http://localhost:3002 ./run-journeyhawk.sh comc <spec>
# The runner (run-journeyhawk.sh) rewrites both localhost:3002 AND any hardcoded
# https://app.phronex.com in a spec to \${PORTAL_URL} before the run.
EOF"
fi

# --- Secret-bearing keys the runner references (values from env / KEYS.md) ---
# Primary QA database DSN (sync driver) — the pipeline + runner both read this.
ensure_qa_env_key "PHRONEX_QA_DATABASE_URL_SYNC" "PHRONEX_QA_DATABASE_URL_SYNC" \
  "local phronex_qa DSN, e.g. postgresql://phronex_qa:<pw>@localhost:5432/phronex_qa"
# Async variant (some readers use it) — keep in sync if present in env/vault.
ensure_qa_env_key "PHRONEX_QA_DATABASE_URL" "PHRONEX_QA_DATABASE_URL" \
  "local phronex_qa async DSN"
# Portal QA superadmin login (used by portal preflight + credential injection).
ensure_qa_env_key "PHRONEX_PORTAL_TEST_EMAIL"    "PHRONEX_PORTAL_TEST_EMAIL"    "portal QA superadmin email"
ensure_qa_env_key "PHRONEX_PORTAL_TEST_PASSWORD" "PHRONEX_PORTAL_TEST_PASSWORD" "portal QA superadmin password (KEYS.md)"
# Cleanup-SDK sentinels the runner references for pre-run test-data wipes.
# Each must match QA_TEST_CLEANUP_SDK_KEY in the matching product's .env.
ensure_qa_env_key "JP_TEST_CLEANUP_SDK_KEY"            "JP_TEST_CLEANUP_SDK_KEY"            "matches /opt/jobportal/.env QA_TEST_CLEANUP_SDK_KEY"
ensure_qa_env_key "CC_TEST_CLEANUP_SDK_KEY"            "CC_TEST_CLEANUP_SDK_KEY"            "matches /opt/contentcompanion/.env QA_TEST_CLEANUP_SDK_KEY"
ensure_qa_env_key "PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY" "PHRONEX_AUTH_TEST_CLEANUP_SDK_KEY" "matches /opt/phronex-auth/.env QA_TEST_CLEANUP_SDK_KEY"
# Allowed-hosts denylist bypass — only while Phronex has zero paying customers.
ensure_qa_env_key "PHRONEX_QA_ALLOWED_HOSTS" "PHRONEX_QA_ALLOWED_HOSTS" \
  "comma list of permitted target hosts (production denylist bypass)"

# ===========================================================================
# SECTION 2 — phronex_qa DB: grants + ownership so ensure_*() works
# ===========================================================================
# The runner + pipeline call ensure_schema()/ensure_*() which issue CREATE TABLE
# and ALTER TABLE against phronex_qa as role `phronex_qa`. For those to succeed,
# role phronex_qa needs:
#   - DML on every existing qa_* table + USAGE/UPDATE on their sequences
#   - CREATE/USAGE on schema public (to create new qa_* tables)
#   - OWNERSHIP of existing qa_* tables (so ALTER ... ADD COLUMN works)
#   - default privileges so future qa_* objects inherit the same grants
# All of this is expressed idempotently via DO-block loops.
# ---------------------------------------------------------------------------
echo ""
echo "== Section 2: phronex_qa DB grants + ownership =="

# We run this section as a Postgres superuser (peer auth via `sudo -u postgres`)
# because ALTER ... OWNER TO and GRANT on public schema require superuser/owner.
# Nothing here reads a secret — it operates on the local cluster by DB name.
PSQL_SUPER=(sudo -u postgres psql -v ON_ERROR_STOP=1 -d phronex_qa)

QA_GRANTS_SQL=$(cat <<'SQL'
-- All statements below are idempotent (safe to re-run).

-- 1. Schema-level: role can create + use objects in public.
GRANT CREATE, USAGE ON SCHEMA public TO phronex_qa;

-- 2. Existing qa_* tables: DML + ownership so ensure_*() ALTERs succeed.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename LIKE 'qa_%'
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO phronex_qa', r.tablename);
    EXECUTE format('ALTER TABLE public.%I OWNER TO phronex_qa', r.tablename);
  END LOOP;
END $$;

-- 3. Existing qa_* sequences: USAGE + UPDATE + ownership (for nextval / SERIAL).
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT sequencename FROM pg_sequences
    WHERE schemaname = 'public' AND sequencename LIKE 'qa_%'
  LOOP
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON SEQUENCE public.%I TO phronex_qa', r.sequencename);
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO phronex_qa', r.sequencename);
  END LOOP;
END $$;

-- 4. Default privileges: future qa_* objects created by ANY role inherit the
--    same grants for phronex_qa. (Ownership of NEW objects is handled by the
--    creating role; this covers cases where another role seeds tables.)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO phronex_qa;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO phronex_qa;
SQL
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "  [dry-run] would apply idempotent GRANT/ALTER OWNER block to phronex_qa:"
  echo "${QA_GRANTS_SQL}" | sed 's/^/      /'
else
  echo "${QA_GRANTS_SQL}" | "${PSQL_SUPER[@]}"
  echo "  ok: grants + ownership applied to all qa_* tables/sequences"
fi

# ===========================================================================
# SECTION 3 — QA accounts in box-local phronex_auth
# ===========================================================================
# Ensure the JourneyHawk QA superadmin account exists, plus a command-centre
# cc_ceo/premium grant tied to a qa-comc-org instance. This is the box-local
# NON-PROD phronex_auth DB (never production). All upserts are idempotent.
#
# The account password is read from the environment (QA_SUPERADMIN_PASSWORD or
# PHRONEX_PORTAL_TEST_PASSWORD) and hashed with the CANONICAL bcrypt helper
# phronex_common.auth.password.hash_password. The plaintext is NEVER printed and
# NEVER stored anywhere but the resulting bcrypt hash in the DB.
# ---------------------------------------------------------------------------
echo ""
echo "== Section 3: QA accounts (box-local phronex_auth) =="

# Resolve the QA superadmin password from env or the already-loaded .qa.env.
# We do NOT inline it. If both unset, skip account upsert with a KEYS.md pointer.
QA_ACCOUNT_EMAIL="${PHRONEX_PORTAL_TEST_EMAIL:-qa-test-journeyhawk@phronex.com}"
QA_ACCOUNT_PW="${QA_SUPERADMIN_PASSWORD:-${PHRONEX_PORTAL_TEST_PASSWORD:-}}"

# If the password isn't in the current env, try sourcing the .qa.env we just
# ensured (it may hold PHRONEX_PORTAL_TEST_PASSWORD). Done in a subshell so we
# never leak it into this shell's logged environment.
if [[ -z "${QA_ACCOUNT_PW}" && -f "${QA_ENV_FILE}" ]]; then
  QA_ACCOUNT_PW="$(dotenv_get "${QA_ENV_FILE}" "PHRONEX_PORTAL_TEST_PASSWORD" || true)"
  [[ -z "${QA_ACCOUNT_PW}" ]] && QA_ACCOUNT_PW="$(dotenv_get "${QA_ENV_FILE}" "QA_SUPERADMIN_PASSWORD" || true)"
fi

if [[ -z "${QA_ACCOUNT_PW}" ]]; then
  echo "  WARNING: QA superadmin password not found in env or .qa.env."
  echo "           Set QA_SUPERADMIN_PASSWORD / PHRONEX_PORTAL_TEST_PASSWORD from"
  echo "           KEYS.md (PhronexSolutions/secrets/KEYS.md) and re-run."
  echo "           Skipping account upsert (no fabricated password)."
elif [[ ! -x "${AUTH_VENV_PY}" ]]; then
  echo "  WARNING: auth venv python not found at ${AUTH_VENV_PY} — cannot hash password."
  echo "           Skipping account upsert."
else
  # Compute the bcrypt hash in the auth venv; capture ONLY the hash (never the pw).
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [dry-run] would hash QA password via phronex_common.auth.password.hash_password"
    echo "  [dry-run] would upsert account ${QA_ACCOUNT_EMAIL} (is_superadmin=true)"
    echo "  [dry-run] would upsert instance qa-comc-org (command-centre) + cc_ceo/premium grant"
  else
    QA_PW_HASH="$(QA_PW="${QA_ACCOUNT_PW}" "${AUTH_VENV_PY}" - <<'PYEOF'
import os
from phronex_common.auth.password import hash_password
print(hash_password(os.environ["QA_PW"]), end="")
PYEOF
)"
    # Idempotent upserts. Uses gen_random_uuid() (pgcrypto/pg13+) for new rows.
    # cc_ceo role_id is resolved by slug so we don't hardcode a UUID.
    QA_PW_HASH="${QA_PW_HASH}" QA_EMAIL="${QA_ACCOUNT_EMAIL}" \
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d phronex_auth \
        -v qa_email="'${QA_ACCOUNT_EMAIL}'" -v qa_hash="'${QA_PW_HASH}'" <<'SQL'
-- 3a. Upsert the QA superadmin account (idempotent on email).
INSERT INTO accounts (id, email, password_hash, full_name, is_active, is_superadmin,
                      created_at, updated_at, consent_purposes, rate_limit_exempt)
VALUES (gen_random_uuid(), :qa_email, :qa_hash, 'JourneyHawk QA',
        true, true, now(), now(), '{}'::jsonb, true)
ON CONFLICT (email) DO UPDATE
  SET password_hash = EXCLUDED.password_hash,
      is_active     = true,
      is_superadmin = true,
      updated_at    = now();

-- 3b. Upsert the qa-comc-org command-centre instance owned by that account.
WITH acct AS (SELECT id FROM accounts WHERE email = :qa_email)
INSERT INTO instances (id, product_slug, owner_account_id, slug, display_name,
                       tier_config, widget_config, is_active, created_at, updated_at)
SELECT gen_random_uuid(), 'command-centre', acct.id, 'qa-comc-org', 'QA ComC Org',
       '{}'::jsonb, '{}'::jsonb, true, now(), now()
FROM acct
ON CONFLICT (slug) DO UPDATE
  SET is_active  = true,
      updated_at = now();

-- 3c. Upsert the cc_ceo / premium grant on that instance (idempotent).
--     role_id resolved by slug 'cc_ceo' so no UUID is hardcoded.
WITH acct AS (SELECT id FROM accounts WHERE email = :qa_email),
     inst AS (SELECT id FROM instances WHERE slug = 'qa-comc-org'),
     rl   AS (SELECT id FROM roles WHERE slug = 'cc_ceo')
INSERT INTO access_grants (id, account_id, product_slug, instance_id, tier,
                           is_active, granted_at, updated_at, role_id)
SELECT gen_random_uuid(), acct.id, 'command-centre', inst.id, 'premium',
       true, now(), now(), rl.id
FROM acct, inst, rl
WHERE NOT EXISTS (
  SELECT 1 FROM access_grants g
  WHERE g.account_id = acct.id
    AND g.product_slug = 'command-centre'
    AND g.instance_id = inst.id
);

-- 3d. If the grant already existed, ensure it is active + correctly roled/tiered.
UPDATE access_grants g
SET is_active = true, tier = 'premium', updated_at = now(),
    role_id = (SELECT id FROM roles WHERE slug = 'cc_ceo')
FROM accounts a, instances i
WHERE g.account_id = a.id AND a.email = :qa_email
  AND g.instance_id = i.id AND i.slug = 'qa-comc-org'
  AND g.product_slug = 'command-centre';
SQL
    echo "  ok: account + qa-comc-org instance + cc_ceo/premium grant ensured"
  fi
fi

# ---------------------------------------------------------------------------
# Section 3b — QA MANAGER (non-admin) account for permission-boundary journeys
# ---------------------------------------------------------------------------
# JourneyHawk's comc-trunk-manager trunk + comc-perm-boundary-non-admin-dashboard
# -access leaf need a NON-ADMIN manager session: a cc_manager-role grant with
# is_superadmin=false. This proves a manager is correctly BLOCKED from admin-only
# ComC pages. Mirrors Section 3 exactly (canonical bcrypt hash_password, no
# inlined/printed secret, fully idempotent). Reuses the same qa-comc-org instance.
#
# The manager password is read from QA_MANAGER_PASSWORD or PHRONEX_QA_MANAGER_
# PASSWORD (env or .qa.env / KEYS.md) — never inlined here. If absent, this
# section is skipped with a KEYS.md pointer (no fabricated password).
# ---------------------------------------------------------------------------
echo ""
echo "== Section 3b: QA manager (non-admin) account =="

QA_MANAGER_EMAIL="${PHRONEX_QA_MANAGER_EMAIL:-qa-comc-manager@phronex.com}"
QA_MANAGER_PW="${QA_MANAGER_PASSWORD:-${PHRONEX_QA_MANAGER_PASSWORD:-}}"

# Fall back to .qa.env (subshell read; never leaked into this shell's env log).
if [[ -z "${QA_MANAGER_PW}" && -f "${QA_ENV_FILE}" ]]; then
  QA_MANAGER_PW="$(dotenv_get "${QA_ENV_FILE}" "PHRONEX_QA_MANAGER_PASSWORD" || true)"
  [[ -z "${QA_MANAGER_PW}" ]] && QA_MANAGER_PW="$(dotenv_get "${QA_ENV_FILE}" "QA_MANAGER_PASSWORD" || true)"
fi

if [[ -z "${QA_MANAGER_PW}" ]]; then
  echo "  WARNING: QA manager password not found in env or .qa.env."
  echo "           Set QA_MANAGER_PASSWORD / PHRONEX_QA_MANAGER_PASSWORD from"
  echo "           KEYS.md (PhronexSolutions/secrets/KEYS.md) and re-run."
  echo "           Skipping manager account upsert (no fabricated password)."
elif [[ ! -x "${AUTH_VENV_PY}" ]]; then
  echo "  WARNING: auth venv python not found at ${AUTH_VENV_PY} — cannot hash password."
  echo "           Skipping manager account upsert."
else
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [dry-run] would ensure cc_manager role exists (is_system=false, QA-seeded)"
    echo "  [dry-run] would hash QA manager password via phronex_common.auth.password.hash_password"
    echo "  [dry-run] would upsert account ${QA_MANAGER_EMAIL} (is_superadmin=false)"
    echo "  [dry-run] would upsert cc_manager/premium grant on qa-comc-org (command-centre)"
  else
    # Canonical bcrypt hash; capture ONLY the hash (never the plaintext).
    QA_MGR_PW_HASH="$(QA_PW="${QA_MANAGER_PW}" "${AUTH_VENV_PY}" - <<'PYEOF'
import os
from phronex_common.auth.password import hash_password
print(hash_password(os.environ["QA_PW"]), end="")
PYEOF
)"
    # Idempotent upserts. cc_manager role is ensured by slug (created if absent,
    # mirroring how cc_ceo was QA-seeded: is_system=false). No UUID hardcoded.
    QA_MGR_PW_HASH="${QA_MGR_PW_HASH}" \
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d phronex_auth \
        -v qa_email="'${QA_MANAGER_EMAIL}'" -v qa_hash="'${QA_MGR_PW_HASH}'" <<'SQL'
-- 3b-i. Ensure the cc_manager ComC role exists (QA-seeded, non-system).
--       role_id is later resolved by slug so no UUID is ever hardcoded.
INSERT INTO roles (id, slug, name, description, is_system, created_at)
VALUES (gen_random_uuid(), 'cc_manager', 'ComC Manager',
        'Command Centre manager role (QA-seeded, non-admin)', false, now())
ON CONFLICT (slug) DO NOTHING;

-- 3b-ii. Upsert the NON-ADMIN manager account (idempotent on email).
--        is_superadmin=false is the whole point of this account.
INSERT INTO accounts (id, email, password_hash, full_name, is_active, is_superadmin,
                      created_at, updated_at, consent_purposes, rate_limit_exempt)
VALUES (gen_random_uuid(), :qa_email, :qa_hash, 'JourneyHawk QA Manager',
        true, false, now(), now(), '{}'::jsonb, true)
ON CONFLICT (email) DO UPDATE
  SET password_hash = EXCLUDED.password_hash,
      is_active     = true,
      is_superadmin = false,
      updated_at    = now();

-- 3b-iii. Ensure the shared qa-comc-org instance exists even if Section 3
--         (superadmin) was skipped — so the manager account is usable stand-
--         alone. If it already exists (created in Section 3), this is a no-op
--         and its existing owner is preserved. Owned by the manager account
--         only when it must be freshly created here.
WITH acct AS (SELECT id FROM accounts WHERE email = :qa_email)
INSERT INTO instances (id, product_slug, owner_account_id, slug, display_name,
                       tier_config, widget_config, is_active, created_at, updated_at)
SELECT gen_random_uuid(), 'command-centre', acct.id, 'qa-comc-org', 'QA ComC Org',
       '{}'::jsonb, '{}'::jsonb, true, now(), now()
FROM acct
ON CONFLICT (slug) DO UPDATE
  SET is_active  = true,
      updated_at = now();

-- 3b-iv. Upsert the cc_manager / premium grant on the shared qa-comc-org
--         instance. Idempotent.
WITH acct AS (SELECT id FROM accounts WHERE email = :qa_email),
     inst AS (SELECT id FROM instances WHERE slug = 'qa-comc-org'),
     rl   AS (SELECT id FROM roles WHERE slug = 'cc_manager')
INSERT INTO access_grants (id, account_id, product_slug, instance_id, tier,
                           is_active, granted_at, updated_at, role_id)
SELECT gen_random_uuid(), acct.id, 'command-centre', inst.id, 'premium',
       true, now(), now(), rl.id
FROM acct, inst, rl
WHERE NOT EXISTS (
  SELECT 1 FROM access_grants g
  WHERE g.account_id = acct.id
    AND g.product_slug = 'command-centre'
    AND g.instance_id = inst.id
);

-- 3b-v. If the manager grant already existed, ensure it is active + correctly
--        roled/tiered as cc_manager/premium.
UPDATE access_grants g
SET is_active = true, tier = 'premium', updated_at = now(),
    role_id = (SELECT id FROM roles WHERE slug = 'cc_manager')
FROM accounts a, instances i
WHERE g.account_id = a.id AND a.email = :qa_email
  AND g.instance_id = i.id AND i.slug = 'qa-comc-org'
  AND g.product_slug = 'command-centre';
SQL
    echo "  ok: manager account + cc_manager role + cc_manager/premium grant ensured (is_superadmin=false)"
  fi
fi

# ===========================================================================
# SECTION 4 — Auth ↔ ComC secret alignment
# ===========================================================================
# ComC validates grant tokens minted by phronex-auth using a shared secret:
# auth's JWT_SECRET must equal ComC's CC_INTERNAL_TOKEN. If they diverge, grant
# tokens fail validation at ComC and every ComC journey breaks.
#
# We read BOTH values from their .env files (never from this script), compare
# them, and only if they DIFFER do we align auth's JWT_SECRET to ComC's
# CC_INTERNAL_TOKEN (ComC is treated as the source of truth for this token).
# The value is NEVER printed. Alignment rewrites only the JWT_SECRET line in the
# auth .env, preserving everything else.
# ---------------------------------------------------------------------------
echo ""
echo "== Section 4: auth JWT_SECRET ↔ ComC CC_INTERNAL_TOKEN alignment =="

if [[ ! -f "${AUTH_ENV}" ]]; then
  echo "  WARNING: ${AUTH_ENV} not found — cannot check/align JWT_SECRET. Skipping."
elif [[ ! -f "${COMC_ENV}" ]]; then
  echo "  WARNING: ${COMC_ENV} not found — cannot read CC_INTERNAL_TOKEN. Skipping."
else
  AUTH_JWT="$(dotenv_get "${AUTH_ENV}" "JWT_SECRET" || true)"
  COMC_TOK="$(dotenv_get "${COMC_ENV}" "CC_INTERNAL_TOKEN" || true)"
  if [[ -z "${COMC_TOK}" ]]; then
    echo "  WARNING: CC_INTERNAL_TOKEN empty/missing in ComC .env — nothing to align to. Skipping."
  elif [[ "${AUTH_JWT}" == "${COMC_TOK}" ]]; then
    echo "  ok: auth JWT_SECRET already equals ComC CC_INTERNAL_TOKEN (no change)"
  else
    echo "  MISMATCH detected: auth JWT_SECRET != ComC CC_INTERNAL_TOKEN"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "  [dry-run] would align auth JWT_SECRET to ComC CC_INTERNAL_TOKEN (value not printed)"
    else
      # Rewrite ONLY the JWT_SECRET line in the auth .env, value passed via env
      # so it never appears in the process args / logs. Preserve file mode.
      cp -p "${AUTH_ENV}" "${AUTH_ENV}.bak-$(date +%Y%m%d%H%M%S)"
      NEW_SECRET="${COMC_TOK}" "${AUTH_VENV_PY:-python3}" - "${AUTH_ENV}" <<'PYEOF'
import os, sys, re
path = sys.argv[1]
new = os.environ["NEW_SECRET"]
with open(path) as f:
    lines = f.readlines()
pat = re.compile(r'^(export\s+)?JWT_SECRET=')
found = False
for i, ln in enumerate(lines):
    if pat.match(ln):
        prefix = ln[:ln.index("JWT_SECRET")]
        lines[i] = f"{prefix}JWT_SECRET={new}\n"
        found = True
        break
if not found:
    lines.append(f"JWT_SECRET={new}\n")
with open(path, "w") as f:
    f.writelines(lines)
PYEOF
      echo "  ok: auth JWT_SECRET aligned to ComC CC_INTERNAL_TOKEN (backup written)"
      echo "  NOTE: restart phronex-auth to pick up the new JWT_SECRET (not done here)."
    fi
  fi
fi

echo ""
echo "[setup-qa-env] Done${DRY_RUN:+ (dry-run)}. QA environment is provisioned/idempotent."
