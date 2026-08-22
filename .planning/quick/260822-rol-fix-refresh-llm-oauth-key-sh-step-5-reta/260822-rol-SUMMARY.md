---
phase: 260822-rol
plan: 01
subsystem: infra-automation
tags: [oauth, lxd, cron, command-centre, phronex-main]
requires:
  - svc-command-centre LXD container (RUNNING) with /opt/command-centre/.env
  - container-side systemd unit command-centre.service
  - phronex user NOPASSWD sudo (already assumed by the script)
provides:
  - Step 5 OAuth token deploy retargeted at the svc-command-centre container
affects:
  - refresh-llm-oauth-key.sh (cron, every 20 min)
tech-stack:
  added: []
  patterns:
    - "sudo lxc exec <ctr> -- env VAR=... bash -s <<'QUOTED_HEREDOC' — secret crosses the host/container boundary via argv, never via heredoc text"
key-files:
  created: []
  modified:
    - refresh-llm-oauth-key.sh
decisions:
  - "Quoted heredoc delimiter (CONTAINER_SCRIPT) instead of the unquoted ENDSSH idiom used by Steps 3-4 — removes every backslash-dollar escape and guarantees the token never appears in the heredoc source text"
  - "Token passed via `env TOKEN=` on the exec argv rather than interpolated into the script body (T-rol-01 accepted, T-rol-02 mitigated)"
  - "python3 rotation pipeline preserved verbatim rather than substituted with rm — probe confirmed python3 exists in the container"
  - "Container existence/LXD-down errors deliberately NOT redirected to /dev/null, so they stay visible in the cron log instead of being silently reclassified as 'ComC not installed'"
metrics:
  duration: ~12 min
  completed: 2026-08-22
  tasks: 2
  commits: 1
---

# Phase 260822-rol Plan 01: Retarget Step 5 at svc-command-centre Container Summary

Step 5 of the 20-minute OAuth refresh cron now deploys and reloads inside the `svc-command-centre`
LXD container instead of restarting the retired host `command-centre.service` that could no longer
bind port 8004 — killing the 246-restart-per-20-minute crash loop at its source.

## What Was Done

**Task 1 — Retarget Step 5** (commit `1287544`)

- Header ComC bullet corrected to state the `.env` lives inside the `svc-command-centre` LXD
  container, with an explicit note that the retired host unit is never touched.
- Host `[ -f "$COMC_ENV" ]` existence test replaced with
  `sudo lxc exec svc-command-centre -- test -f "$COMC_ENV"` (stderr deliberately not suppressed).
- Entire deploy body moved into a single container exec:
  `sudo lxc exec svc-command-centre -- env TOKEN="$ACCESS_TOKEN" FORCE_FLAG="$FORCE" COMC_ENV="$COMC_ENV" bash -s <<'CONTAINER_SCRIPT'`
- All three `sudo systemctl` calls became unprefixed container-side `systemctl` calls (`lxc exec`
  already runs as root inside the container).
- `else`-branch warning reworded to say the file was not found *inside the container*.
- `COMC_ENV="/opt/command-centre/.env"` assignment left untouched — the container uses the same
  relative path, and that line sits inside the byte-identical asserted region.

**Task 2 — Static regression verification** (no code changes, therefore no commit)

Verification-only task. The script was **never executed** at any point.

## Verification Results

| Gate | Result |
|---|---|
| `bash -n` | PASS |
| Prelude + Steps 0-4 region sha256 | `2ad54a1d…21c10` — **matches baseline exactly** |
| Summary region sha256 | `f5d0fa47…818e9` — **matches baseline exactly** |
| Shellcheck 0.9.0 codes emitted | `SC2034`, `SC2087` — strict subset of baseline `{SC2012, SC2034, SC2087}`; **zero new codes** |
| `git diff --name-only origin/main` (excl. `.planning`) | exactly `refresh-llm-oauth-key.sh` |
| File mode | `100755`, still executable (unchanged) |
| `TASK1_GATES_PASS` | emitted |
| `TASK2_GATES_PASS` | emitted |

`SC2012` dropped out exactly as the plan predicted — its `ls -t` line moved inside a quoted heredoc
that shellcheck does not parse. Disappearing codes are expected and permitted; no baseline finding in
the untouched region was "fixed" (doing so would have broken the region-identity gate).

Step 5 code-region counts (comments filtered): `lxc exec svc-command-centre` = 2, `sudo systemctl` = 0,
`<<'CONTAINER_SCRIPT'` present, `${ACCESS_TOKEN}` = 0, `TOKEN="$ACCESS_TOKEN"` = 1, host `[ -f ` = 0,
`systemctl reload command-centre` = 1, `systemctl restart command-centre` = 1,
`systemctl is-active command-centre` = 1, backslash-dollar = 0.

## Container `python3` Probe (Task 2 step 4)

**Result: `python3` is PRESENT at `/usr/bin/python3` inside `svc-command-centre`.**
**Backup rotation is therefore fully functional — not a silent no-op.** The 3-backup cap will be
enforced inside the container exactly as it was on the host. No residual to flag for the PR body.

> Probe note: the plan's literal command `sudo lxc exec svc-command-centre -- command -v python3`
> returns `Error: Command not found` (exit 127) because `command` is a *shell builtin* and `lxc exec`
> execs the binary directly with no shell — a probe artifact, **not** evidence of absence. Re-probed
> correctly as `sudo lxc exec svc-command-centre -- sh -c 'command -v python3'` → `/usr/bin/python3`.
> Anyone re-running this check must use the `sh -c` form or they will misread it as absent.

Container confirmed `RUNNING` via `sudo lxc list svc-command-centre`. Extending the probe to every
command the relocated script body depends on — `grep cut printf sha256sum cp ls tail xargs sed date
sleep systemctl python3` — returned **OK for all 13**. No missing-dependency risk from the relocation.

## Read-Through Diff Assertions (Task 2 step 5)

1. **All nine former host operations now execute inside the container, none dropped** — env read
   (`grep`/`cut`), hash compare (`printf`/`sha256sum`/`cut` ×2), `cp` backup, `ls`/`tail`/`xargs`
   rotation, `grep -q`/`sed -i`/append write, `systemctl reload`, `systemctl restart` fallback,
   `sleep 3`, `systemctl is-active` — all present inside `CONTAINER_SCRIPT`.
2. **Skip-on-unchanged idempotency branch and its message are intact** — the sha256 comparison and the
   byte-identical string `   Token unchanged - skipping ComC restart.` are preserved, and the original
   IF/ELSE nesting (skip in `then`, deploy in `else`) was kept rather than converted to an early exit.
3. **The `--force` bypass still reaches the deploy body** — host `$FORCE` is passed through as
   `FORCE_FLAG`; the guard `[ hashes equal ] && [ "$FORCE_FLAG" != "--force" ]` evaluates false under
   `--force`, falling through to the deploy `else` branch.
4. **Reload-then-restart fallback ordering is unchanged** — `if systemctl reload … ; then` … `else
   systemctl restart … || true`.
5. **No code path writes the host `/opt/command-centre/.env`** — Step 5's host-side code is only
   `echo`, the `lxc exec test -f` guard, the `lxc exec … bash -s` invocation, and the `else` warning.
   Zero `>`, `>>`, `sed -i`, `cp`, or `tee` on the host; zero host `systemctl`.
6. **No backslash-dollar escapes inside the quoted heredoc** — scoped scan of the 27-line heredoc body
   returns 0 occurrences of `\$` (they would have become literal backslashes in the container script
   and silently corrupted every variable reference).
7. **The diff touches only the header ComC bullet and the Step 5 block** — two hunks total, and both
   region-identity hashes match baseline, proving Steps 0-4 and the Summary are byte-identical.

Additionally: the heredoc body contains 0 occurrences of `ACCESS_TOKEN` and 0 occurrences of `sudo`,
confirming the token reaches the container solely via the `env TOKEN=` argv (T-rol-02) and that no
inner command carries a redundant privilege prefix.

## Threat Model Compliance

| Threat ID | Status |
|---|---|
| T-rol-01 (token in host process table) | Accepted as planned — operator-mandated mechanism. |
| T-rol-02 (token in cron log) | Mitigated — Step 5 echoes only status strings; token absent from heredoc source (0 `ACCESS_TOKEN` in body). |
| T-rol-03 (host restart loop) | **Closed** — 0 `sudo systemctl` in Step 5, 0 host writes to the stale `.env`. |
| T-rol-04 (collateral Steps 0-4 edits) | Mitigated — both content-anchored region hashes match baseline byte-for-byte. |
| T-rol-05 (privilege surface) | Accepted — no new grant; `phronex` already holds `NOPASSWD: ALL` and the script already used bare `sudo`. |
| T-rol-SC (supply chain) | N/A — no package installs. |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected the container `python3` probe command**
- **Found during:** Task 2, step 4
- **Issue:** The plan specified `sudo lxc exec svc-command-centre -- command -v python3`. `command` is
  a POSIX shell builtin, and `lxc exec` executes the given argv directly without a shell, so the probe
  returns `Error: Command not found` (exit 127) regardless of whether `python3` exists. Taken at face
  value it would have produced a **false "python3 ABSENT" finding** in this SUMMARY and an incorrect
  "backup rotation is a silent no-op" warning in the PR body.
- **Fix:** Re-ran as `sudo lxc exec svc-command-centre -- sh -c 'command -v python3'`, which returned
  `/usr/bin/python3`. Both the artifact and the corrected form are documented above so the operator
  does not repeat the misreading.
- **Files modified:** none — this was a verification-command correction, not a script change.
- **Commit:** n/a (verification only)

**2. [Rule 3 - Blocking] Verification commands re-rooted at the execution worktree**
- **Found during:** Tasks 1 and 2
- **Issue:** The plan's `<automated>` gates hardcode `cd /home/phronex/code/phronex-test-runner`, but
  execution runs in the isolated worktree
  `/home/phronex/code/phronex-test-runner/.claude/worktrees/agent-ab4a4a39b1b1dc506`. Running the
  gates as written would have validated the **unmodified main checkout** and passed vacuously.
- **Fix:** Ran every gate against the worktree checkout. All assertions are otherwise byte-identical
  to the plan's; both composite gates emitted `TASK1_GATES_PASS` / `TASK2_GATES_PASS`.
- **Files modified:** none
- **Commit:** n/a (verification only)

**3. [Rule 3 - Blocking] Worktree base corrected before any work**
- **Found during:** Startup branch check
- **Issue:** The worktree was created at `7c62e54` (`origin/main`) rather than the instructed base
  `f617673` (the plan's docs commit).
- **Fix:** `git reset --hard f617673…` per the mandated startup procedure, after asserting HEAD was on
  the per-agent branch `worktree-agent-ab4a4a39b1b1dc506`. Verified HEAD afterwards.
- **Files modified:** none
- **Commit:** n/a

### Scope Note

Task 2 is a pure verification task and produced no file changes, so it has **no commit** — the plan's
single behavioural change is entirely contained in `1287544`.

## Known Stubs

None. No placeholder values, TODOs, or unwired code paths were introduced.

## Threat Flags

None. The change introduces no new network endpoint, auth path, or schema; it moves an existing
file-write and service-reload from one execution context to another, and the one new trust boundary
(host → container) is already enumerated in the plan's threat model as T-rol-01/T-rol-02.

## Follow-Up for the Operator (non-blocking)

- The host `command-centre.service` unit was stopped manually earlier this session as a stopgap. This
  change stops the cron script from ever restarting it, but does **not** disable or remove the unit —
  consider `systemctl disable command-centre` on the host so a manual/boot-time start cannot revive
  the port-8004 conflict.
- A stale host `/opt/command-centre/.env` (plus any `.bak-*` files) may still exist and now holds a
  token that nothing consumes. Not touched by this change; worth cleaning up separately since it is a
  credential at rest with no reader.

## Self-Check: PASSED

- `refresh-llm-oauth-key.sh` — FOUND (mode 100755, `bash -n` clean)
- Commit `1287544` — FOUND in `git log`
- Both region-identity baselines — MATCHED
- Script execution — CONFIRMED NEVER RUN (no invocation of `refresh-llm-oauth-key.sh` at any point;
  only `bash -n`, `shellcheck`, `awk`/`grep`/`sha256sum` static reads, and read-only `lxc list` /
  `lxc exec … command -v` probes that mutate nothing)
