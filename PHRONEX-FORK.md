# PHRONEX-FORK.md

This file documents the Phronex Solutions fork of `claude-code-test-runner`.
It is intentionally separate from upstream `README.md` so that upstream rebases
do not collide with Phronex-specific operating notes.

## Fork Provenance

- **Upstream repository:** https://github.com/firstloophq/claude-code-test-runner
- **Fork repository:** https://github.com/PhronexSolutions/phronex-test-runner
- **Forked on:** 2026-04-25
- **Pinned upstream SHA:** `717826c66a397efd723191163e4c241de0766e26`
- **Pinned upstream date:** 2025-08-19 13:15:00 -0600
- **Pinned upstream subject:** Migrate to commander CLI (#8)

The pinned SHA is also recorded in `.pinned-upstream.txt` at the repo root for
machine-readable consumers (CI, JourneyHawk skill).

## Why We Forked

- **Freeze a known-good revision.** Upstream changes (CLI flag renames, removed
  features, breaking deps) must not silently break Phronex JourneyHawk runs.
  We advance the pin only after smoke tests pass.
- **Own the CI surface.** The Phronex test stack runs through this binary;
  owning the fork lets us add CI, release tags, and reproducible builds without
  upstream coordination.
- **Allow Phronex-specific operating notes** (this file, future config) without
  polluting upstream PRs or licensing assumptions.

## How JourneyHawk Uses This Repo

- **Build:** `cd cli && ./init.dev.sh && bun run build` — produces `./dist/cc-test-runner`.
- **Invoke:** `./dist/cc-test-runner -t {spec.json} -o results/`.
- **Auth:** subscription mode (verified in Plan 67-04 of v16.0 milestone).
- **Caller:** `~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md` is the
  only consumer. JourneyHawk wraps invocation with isolation guards
  (`phronex_common.testing.isolation.assert_not_production`) and cleanup
  registry registration.

## Re-sync From Upstream

Re-syncing pulls a newer upstream pin into our fork. Procedure:

```
git fetch upstream
git log --oneline upstream/main ^HEAD | head -20   # review changes
git merge upstream/main                            # or rebase if cleaner
# update .pinned-upstream.txt with new SHA + date
# bump pinned-upstream SHA in this file (Provenance section)
# smoke-test against e2e-test-instance per Plan 67-05 procedure
git push origin main
```

Re-sync is **GATED** by JourneyHawk smoke test passing. Never advance the pin
without a green smoke run. If the smoke test fails, revert the merge and file
the divergence under v16+ planning.

## Windows Invocation (MANDATORY — PATH quirk)

The Claude Code SDK detects it is running under Bun (`typeof Bun !== 'undefined'`) and
spawns the Claude Code subprocess using the literal string `"bun"` as the executable.
Bun's Windows installer does **not** add itself to `$PATH`, so the spawn silently hangs
forever — no ENOENT thrown, no output, no timeout.

**Always invoke with `bun` on PATH:**

```bash
export PATH="/c/Users/parma/.bun/bin:$PATH"
cd cli && env -u CLAUDECODE bun run src/index.ts -t <spec.json> -o <results/>
```

The `env -u CLAUDECODE` unsets the outer Claude Code session detection flag (which is
set to `1` when running inside any Claude Code agent). Setting it to empty (`CLAUDECODE=""`)
is NOT sufficient — it must be fully unset.

Discovered: 2026-04-27, Phase 75 smoke validation. Documented after an >1 hour silent hang
was traced to the missing bun in PATH.

## Phronex-Specific Notes

- This fork is consumed exclusively by the
  `Phronex_Internal_QA_JourneyHawk` skill at
  `~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md`.
- **Cost:** subscription quota burn per run; budget must stay within the
  tolerable run-cost ceiling defined in the JourneyHawk Metadata section.
- **No production target ever.** Every run is gated by
  `phronex_common.testing.isolation.assert_not_production()` at the skill
  entry point. The denylist (`phronex.com`, `app.phronex.com`,
  `cc.phronex.com`, `jobc.phronex.com`, `auth.phronex.com`,
  `praxis.phronex.com`, `www.phronex.com`) is enforced at runtime.
- **QA writes go to `phronex_qa` Postgres only** — never a production product DB.

## License

The upstream license carries through unchanged. This fork modifies no
licensing terms; upstream `LICENSE` (if present) governs.
