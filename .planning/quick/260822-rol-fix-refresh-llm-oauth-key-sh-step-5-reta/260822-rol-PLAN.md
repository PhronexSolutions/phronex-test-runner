---
phase: 260822-rol
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - refresh-llm-oauth-key.sh
autonomous: true
requirements: [ROL-01, ROL-02, ROL-03]
branch: chore/comc-oauth-refresh-container-target

must_haves:
  truths:
    - "Step 5 no longer issues any systemctl command against the phronex-main HOST - the retired host command-centre.service can never be restarted by this cron script again."
    - "Step 5 reads, backs up, rotates and rewrites /opt/command-centre/.env INSIDE the svc-command-centre LXD container."
    - "Step 5 reloads (falling back to restart) the command-centre.service unit INSIDE the container, and reports its post-deploy is-active status from inside the container."
    - "The refreshed OAuth token is passed into the container as an environment variable on the lxc exec invocation, never interpolated into the heredoc script text."
    - "Idempotency (sha256 compare, skip when unchanged unless --force), timestamped backup, and 3-backup rotation all behave exactly as before, just relocated into the container."
    - "Steps 0-4 (the EC2 deploy path) and the Summary block are byte-identical to their pre-change content."
    - "No fallback path writes to the stale HOST /opt/command-centre/.env."
  artifacts:
    - path: "refresh-llm-oauth-key.sh"
      provides: "Step 5 retargeted at svc-command-centre container"
      contains: "lxc exec svc-command-centre"
  key_links:
    - from: "refresh-llm-oauth-key.sh Step 5"
      to: "svc-command-centre container /opt/command-centre/.env"
      via: "sudo lxc exec svc-command-centre -- env TOKEN=... bash -s heredoc"
      pattern: "lxc exec svc-command-centre -- env TOKEN="
    - from: "refresh-llm-oauth-key.sh Step 5"
      to: "container command-centre.service"
      via: "systemctl reload/restart executed as root inside the container"
      pattern: "systemctl (reload|restart) command-centre"
---

<objective>
Retarget Step 5 of `refresh-llm-oauth-key.sh` (the phronex-main ComC OAuth token deploy) from the
**retired host** `command-centre.service` to the **live `svc-command-centre` LXD container**.

Purpose: this script runs from cron every 20 minutes. Its current Step 5 restarts a host systemd
unit that can no longer bind port 8004 (an LXD proxy device now owns that port), which put the host
unit into an active crash loop - 246 failed restarts in ~20 minutes, root-caused directly to this
Step 5. The unit was stopped manually this session as a stopgap; Step 5 will re-trigger the crash
loop on its very next cron run unless this change lands.

Output: a single-section, single-file mechanism swap in `refresh-llm-oauth-key.sh`. Steps 0-4 (EC2
deploy) and the Summary block are untouched.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@refresh-llm-oauth-key.sh
@CLAUDE.md

Working branch is already `chore/comc-oauth-refresh-container-target`, branched off origin/main and
already checked out. **Reuse it.** Do not create a worktree, do not create a differently-named
branch, do not merge to main, do not push to origin/main. The calling orchestrator opens the PR.

**This script must never be executed during this task.** It deploys real refreshed OAuth credentials
to production services. Verification is static only: syntax check, shellcheck delta, region-identity
hashes, and a manual read-through diff.

## Ground truth (already verified live this session - do NOT re-derive or re-verify)

- `svc-command-centre` container has `/opt/command-centre/.env` at the **same relative path** as the
  old host layout, and a systemd unit **also named `command-centre.service`** (Type=simple,
  User=command-centre, WorkingDirectory=/opt/command-centre, ExecStart runs
  `/opt/command-centre/.venv/bin/uvicorn command_centre.main:app` on `${CC_HOST}:${CC_SIDECAR_PORT}`
  with `--workers 2`). The unit name does not change - only the execution context moves host to container.
- This script already runs as user `phronex` under cron. `phronex` has unrestricted `NOPASSWD: ALL`
  sudo. `sudo lxc exec` therefore requires **zero new privilege grants** versus what the script
  already assumes today (it already uses bare `sudo systemctl ...`).
- **Bare (non-sudo) `lxc` fails** with an LXD-socket permission error on this box (snap-confined LXD)
  even for lxd-group members. Always prefix outer `lxc` invocations with `sudo`.
- **Inside the container, `lxc exec` already runs as root** - inner commands need NO `sudo` prefix.

## Current Step 5 (lines 200-232) - what is being replaced

A host-path `[ -f "$COMC_ENV" ]` test, then host-local `grep`/`sha256sum`/`cp`/`ls`/`sed` against
`/opt/command-centre/.env`, then `sudo systemctl reload command-centre` with a
`sudo systemctl restart command-centre` fallback, then `sudo systemctl is-active command-centre`.
Every one of those touches the HOST. All of it moves into the container.

## Baseline facts captured pre-change (used by the Task 2 regression gates)

Content-anchored region hashes (robust to header line-count changes):

| Region | sha256 |
|---|---|
| prelude + Steps 0-4: `awk '/^set -euo pipefail$/,/^# ── Step 5:/'` piped through `head -n -1` | `2ad54a1d909f1f3a556b07b63ea3d5b75fddcc5ef46bed4b7e51e0c688721c10` |
| Summary block to EOF: `awk '/^# ── Summary/,0'` | `f5d0fa478ac272d7f2ce4ef4cb49f4657d5f0d009fe6d83ca792438e23a818e9` |

`bash -n` passes at baseline. `shellcheck` 0.9.0 is installed and **already exits 1 at baseline**
emitting exactly these codes: `SC2012`, `SC2034`, `SC2087`. The gate is therefore "no code outside
that set", NOT "shellcheck exits 0". Expect `SC2012` to disappear after the change (its `ls -t` line
moves inside a quoted heredoc, which shellcheck does not parse) - disappearing codes are fine, new
codes are not.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Retarget Step 5 at the svc-command-centre container</name>
  <files>refresh-llm-oauth-key.sh</files>
  <action>
Replace the block from the `# ── Step 5: Deploy to phronex-main command-centre` banner comment
through its final `fi` (currently lines 200-232), and correct the ComC bullet in the header comment.
Change nothing else in the file.

HEADER CORRECTION (in-scope, minimal): the header's "phronex-main services (this machine)" bullet
currently reads `- command-centre    -> /opt/command-centre/.env`, which is now factually wrong -
that path is inside the container, not on the host. Amend that one bullet so it names the
`svc-command-centre` LXD container as the target. Do not touch any other header line; RULES item 3
("phronex-main's ComC always gets the latest token") makes no mechanism claim and stays as-is.

DO NOT CHANGE the `COMC_ENV="/opt/command-centre/.env"` assignment near the top of the script
(currently line 55) - the container uses that same relative path, and that line sits inside the
byte-identical region asserted by Task 2. Likewise do not add a new top-of-file variable for the
container name; use the literal `svc-command-centre` inline within Step 5 only.

NEW STEP 5 STRUCTURE - OUTER HOST SHELL:

1. Keep the banner comment line and the leading `echo ""`. Amend the `[5/5]` progress echo so it
   names the container target rather than implying a host service.
2. Replace the host `[ -f "$COMC_ENV" ]` existence test with a container-executed test of the form
   `if sudo lxc exec svc-command-centre -- test -f "$COMC_ENV"; then`. `$COMC_ENV` is expanded by the
   host shell into the argv before `lxc exec` runs, which is equivalent to passing the literal path.
   Do NOT redirect this command's stderr to `/dev/null` - a genuine "container missing / LXD down"
   condition must stay visible in the cron log rather than being silently reclassified as
   "not installed".
3. Inside the `then` branch, run the entire deploy body as a SINGLE container exec of the form
   `sudo lxc exec svc-command-centre -- env TOKEN="$ACCESS_TOKEN" FORCE_FLAG="$FORCE" COMC_ENV="$COMC_ENV" bash -s`
   fed by a heredoc whose delimiter is QUOTED - opening `<<'CONTAINER_SCRIPT'`, closing
   `CONTAINER_SCRIPT`. Passing `COMC_ENV` through `env` keeps the path's single source of truth at
   the existing top-of-file assignment.
4. Keep the `else` branch's warning-echo shape, but amend its wording so it states the file was not
   found INSIDE THE svc-command-centre CONTAINER rather than "not installed on this machine".

CRITICAL HEREDOC RULE - DELIBERATELY DIFFERENT FROM STEPS 3-4: Steps 3-4 use an UNQUOTED `ENDSSH`
delimiter and therefore escape inner expansions as backslash-dollar. This heredoc's delimiter is
QUOTED, so the host performs NO expansion inside it. Consequently every dollar sign inside the
container script is a plain, unescaped dollar referring to a container-side variable. Do NOT write
any backslash-dollar sequence anywhere inside `CONTAINER_SCRIPT`, and do NOT interpolate
`${ACCESS_TOKEN}` into the script text - the token reaches the container solely via the `env TOKEN=`
argument, so it never appears in the heredoc body at all.

CONTAINER SCRIPT BODY (executes as root inside the container - no `sudo` anywhere inside):

Open with `set -e`, mirroring the Steps 3-4 heredoc idiom. Then reproduce the existing Step 5 logic
verbatim in shape, substituting `$TOKEN` for the former `$ACCESS_TOKEN` and `$FORCE_FLAG` for the
former `$FORCE`, and keeping the original variable names `CURRENT_COMC_KEY`, `COMC_NEW_HASH`,
`COMC_CUR_HASH`, `COMC_STATUS`:

- Idempotency: read the current key with `grep '^ANTHROPIC_API_KEY=' "$COMC_ENV"` piped to
  `cut -d= -f2-`, guarded by `2>/dev/null` and a trailing `|| echo ""`; sha256 both the new token and
  the current key via `printf '%s' ... | sha256sum | cut -d' ' -f1`; if the hashes match AND
  `$FORCE_FLAG` is not `--force`, echo the existing message
  `   Token unchanged - skipping ComC restart.`
  Preserve the original IF/ELSE NESTING (skip-message in the `then`, full deploy body in the `else`)
  rather than converting to an early `exit 0`, so the diff reads as a pure host-to-container
  relocation with no control-flow change.
- Backup: `cp "$COMC_ENV" "${COMC_ENV}.bak-$(date +%Y%m%d_%H%M%S)"`.
- Rotation, verbatim including the `python3 -c` unlink form and its `2>/dev/null || true` guard:
  `ls -t` of the `.bak-` glob, piped to `tail -n +4`, piped to `xargs -r python3 -c` running the
  existing `import sys,os; [os.unlink(p) for p in sys.argv[1:]]` one-liner. Keep `python3` rather
  than substituting `rm` - Task 2 probes whether `python3` exists in the container and reports it,
  instead of silently changing a command the operator asked to preserve.
- Write: preserve the existing two-branch form - `if grep -q '^ANTHROPIC_API_KEY=' "$COMC_ENV"` then
  `sed -i` the `s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${TOKEN}|` substitution, else append an
  `ANTHROPIC_API_KEY=${TOKEN}` line to the file.
- Reload with restart fallback, WITHOUT `sudo`: `if systemctl reload command-centre 2>/dev/null` then
  echo `   ComC service reloaded.`, else `systemctl restart command-centre 2>/dev/null || true` and
  echo `   ComC service restarted.` The unit name stays `command-centre` - the container's own unit
  is identically named.
- Status: `sleep 3`, then assign `COMC_STATUS` from `systemctl is-active command-centre 2>/dev/null`
  with a `|| echo "unknown"` fallback (no `sudo`), then echo the existing
  `   ✅ phronex-main command-centre updated. Status: $COMC_STATUS` line. Both the sleep and the
  status read run inside this same single container exec.

EXPLICITLY FORBIDDEN: do not add any fallback that also writes the host's `/opt/command-centre/.env`,
and do not leave any `systemctl` call in Step 5 that targets the host. That stale file and that
retired unit are exactly what this change exists to stop touching; writing to either would resurrect
the crash loop this fix eliminates.
  </action>
  <verify>
    <automated>cd /home/phronex/code/phronex-test-runner && bash -n refresh-llm-oauth-key.sh && awk '/^# ── Step 5:/,/^# ── Summary/' refresh-llm-oauth-key.sh | grep -v '^[[:space:]]*#' > /tmp/s5.txt && test $(grep -c 'lxc exec svc-command-centre' /tmp/s5.txt) -ge 2 && test $(grep -c 'sudo systemctl' /tmp/s5.txt) -eq 0 && grep -qF "<<'CONTAINER_SCRIPT'" /tmp/s5.txt && test $(grep -cF '${ACCESS_TOKEN}' /tmp/s5.txt) -eq 0 && test $(grep -cF 'TOKEN="$ACCESS_TOKEN"' /tmp/s5.txt) -eq 1 && test $(grep -cF '[ -f ' /tmp/s5.txt) -eq 0 && test $(grep -cF 'systemctl reload command-centre' /tmp/s5.txt) -eq 1 && test $(grep -cF 'systemctl restart command-centre' /tmp/s5.txt) -eq 1 && test $(grep -cF 'systemctl is-active command-centre' /tmp/s5.txt) -eq 1 && echo TASK1_GATES_PASS</automated>
  </verify>
  <done>
`bash -n` passes. The Step 5 region (code lines only, comments filtered) contains at least two
`sudo lxc exec svc-command-centre` invocations, zero `sudo systemctl` calls, a quoted
`<<'CONTAINER_SCRIPT'` heredoc opener, exactly one `TOKEN="$ACCESS_TOKEN"` env-passing occurrence,
zero `${ACCESS_TOKEN}` interpolations, zero host `[ -f ` tests, and exactly one each of the
reload / restart-fallback / is-active systemctl calls (all unprefixed, i.e. container-side).
  </done>
</task>

<task type="auto">
  <name>Task 2: Prove Steps 0-4 untouched, shellcheck clean-delta, and behavior preserved</name>
  <files>refresh-llm-oauth-key.sh</files>
  <action>
Static regression verification only. Do NOT execute `refresh-llm-oauth-key.sh` - it deploys live
OAuth credentials to production services.

1. REGION IDENTITY: confirm the prelude + Steps 0-4 region and the Summary region still hash to the
   baselines recorded in the plan's context section. Any mismatch means Steps 0-4 or the Summary were
   modified - revert that collateral change and re-run. These are content-anchored (awk between
   markers), so an edit to the header comment's line count does not spuriously trip them.

2. SHELLCHECK DELTA: run `shellcheck -f gcc` and extract the set of distinct `SC` codes. The result
   must be a subset of the baseline set `SC2012 SC2034 SC2087`. Codes disappearing is expected and
   fine (`SC2012` will drop out because its `ls -t` line moved inside a quoted heredoc that
   shellcheck does not parse). Any code NOT in the baseline set is a new finding introduced by this
   change and must be fixed. Do not "fix" the pre-existing baseline findings - they live in the
   untouched region and touching them would break gate 1.

3. SINGLE-FILE DIFF: confirm `git diff --name-only` against the branch point lists exactly one file,
   `refresh-llm-oauth-key.sh`, and that the file is still executable (mode 100755, unchanged).

4. CONTAINER `python3` PROBE (read-only, safe): run `sudo lxc exec svc-command-centre -- command -v python3`.
   This mutates nothing. Record the result in the SUMMARY. If `python3` is ABSENT in the container,
   the backup-rotation pipeline will silently no-op (it is already `|| true`-guarded, so token deploy
   and service reload are unaffected) and `.bak-` files will accumulate unbounded. Do NOT change the
   command to `rm` - the operator asked for that pipeline preserved verbatim. Flag it as a known
   non-blocking residual for the PR body so the operator can decide.

5. MANUAL READ-THROUGH DIFF: read the full `git diff` and assert each of these explicitly in the
   SUMMARY, one line per item:
   - every former host-targeted operation (env read, hash compare, cp backup, ls/tail/xargs rotation,
     grep/sed/append write, reload, restart fallback, sleep, is-active) now executes inside the
     container, and none was dropped;
   - the skip-on-unchanged idempotency branch and its message are intact;
   - the `--force` bypass still reaches the deploy body;
   - the reload-then-restart fallback ordering is unchanged;
   - no code path writes the host `/opt/command-centre/.env`;
   - no backslash-dollar escapes appear inside the quoted heredoc (they would be literal backslashes
     in the container script, silently corrupting the logic);
   - the diff touches only the header ComC bullet and the Step 5 block.
  </action>
  <verify>
    <automated>cd /home/phronex/code/phronex-test-runner && test "$(awk '/^set -euo pipefail$/,/^# ── Step 5:/' refresh-llm-oauth-key.sh | head -n -1 | sha256sum | cut -d' ' -f1)" = "2ad54a1d909f1f3a556b07b63ea3d5b75fddcc5ef46bed4b7e51e0c688721c10" && test "$(awk '/^# ── Summary/,0' refresh-llm-oauth-key.sh | sha256sum | cut -d' ' -f1)" = "f5d0fa478ac272d7f2ce4ef4cb49f4657d5f0d009fe6d83ca792438e23a818e9" && test -z "$(shellcheck -f gcc refresh-llm-oauth-key.sh | grep -oE 'SC[0-9]+' | sort -u | grep -vxE 'SC2012|SC2034|SC2087')" && test "$(git diff --name-only origin/main -- . ':(exclude).planning' | tr -d '[:space:]')" = "refresh-llm-oauth-key.sh" && test -x refresh-llm-oauth-key.sh && echo TASK2_GATES_PASS</automated>
  </verify>
  <done>
Both region hashes match baseline (Steps 0-4 and Summary provably byte-identical). Shellcheck emits
no code outside the baseline set. `git diff --name-only origin/main` lists exactly
`refresh-llm-oauth-key.sh` and the file remains executable. The container `python3` probe result and
all seven read-through assertions are recorded in the SUMMARY.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| host shell -> LXD container | A live Claude Max OAuth access token crosses from the host cron process into the `svc-command-centre` container. |
| script -> container filesystem | The token is written at rest into the container's `/opt/command-centre/.env` and into timestamped `.bak-` copies. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-rol-01 | Information Disclosure | token visible in host process table while `sudo lxc exec ... env TOKEN=...` runs | accept | Operator-mandated mechanism. Exposure is a sub-second argv on a single-operator box where reading another user's argv already requires root-equivalent access - the same access that can read `.credentials.json` directly. The rejected alternative (interpolating the token into the heredoc body) is strictly worse: it would place the token in the script's own stdin stream and in any `set -x` trace. |
| T-rol-02 | Information Disclosure | token echoed into `/tmp/oauth-refresh.log` via cron redirect | mitigate | Preserved from existing behavior: Step 5 echoes only status strings and a skip/updated message - never the token or the key value. The quoted heredoc guarantees the token never appears in the heredoc source text. Task 1 gate asserts zero `${ACCESS_TOKEN}` interpolations in the region. |
| T-rol-03 | Denial of Service | retired host `command-centre.service` restart loop on port 8004 | mitigate | This is the threat the change exists to close. Task 1 gate asserts zero `sudo systemctl` calls remain in Step 5; Task 2 read-through asserts no code path writes the host `.env`. |
| T-rol-04 | Tampering | collateral edits to the EC2 deploy path (Steps 0-4) shipping unreviewed changes to three production services | mitigate | Task 2 gate 1 asserts a content-anchored sha256 identity for the entire prelude + Steps 0-4 region against a pre-change baseline. |
| T-rol-05 | Elevation of Privilege | new sudo/privilege surface introduced by `lxc` | accept | No new grant: `phronex` already holds `NOPASSWD: ALL` and the script already invokes bare `sudo systemctl`. `sudo lxc exec` is within the existing assumed privilege envelope. |
| T-rol-SC | Tampering | npm/pip/cargo installs | n/a | No package installs in this change - no supply-chain surface. |
</threat_model>

<verification>
- `bash -n refresh-llm-oauth-key.sh` passes.
- `shellcheck` emits no `SC` code outside the baseline set `{SC2012, SC2034, SC2087}`.
- Prelude + Steps 0-4 region hash equals `2ad54a1d909f1f3a556b07b63ea3d5b75fddcc5ef46bed4b7e51e0c688721c10`.
- Summary region hash equals `f5d0fa478ac272d7f2ce4ef4cb49f4657d5f0d009fe6d83ca792438e23a818e9`.
- Step 5 code region: >=2 `sudo lxc exec svc-command-centre`, 0 `sudo systemctl`, quoted
  `<<'CONTAINER_SCRIPT'` present, 0 `${ACCESS_TOKEN}` interpolations, exactly 1
  `TOKEN="$ACCESS_TOKEN"`, 0 host `[ -f ` tests, 0 backslash-dollar escapes.
- `git diff --name-only origin/main` lists exactly `refresh-llm-oauth-key.sh`; file stays executable.
- The script is NOT executed at any point.
</verification>

<success_criteria>
Step 5 of `refresh-llm-oauth-key.sh` deploys the refreshed OAuth token to, and reloads, the
`svc-command-centre` LXD container exclusively - with idempotency, timestamped backup, 3-backup
rotation, and reload-then-restart fallback behaviorally identical to before. The retired host
`command-centre.service` is never touched again by this cron script, and the stale host
`/opt/command-centre/.env` is never written. Steps 0-4 and the Summary block are provably
byte-identical. Work stays on `chore/comc-oauth-refresh-container-target` with no push to main.
</success_criteria>

<output>
Create `.planning/quick/260822-rol-fix-refresh-llm-oauth-key-sh-step-5-reta/260822-rol-SUMMARY.md` when done.

The SUMMARY must include, for the orchestrator's PR body:
- the container `python3` probe result from Task 2 step 4, and whether backup rotation is therefore
  functional or a silent no-op;
- the seven read-through assertions from Task 2 step 5;
- confirmation that the script was never executed.
</output>
