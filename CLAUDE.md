# phronex-test-runner — Repo-Specific Guidance

> Global Phronex bootstrap is in `~/.claude/CLAUDE.md` (loaded automatically). This file adds **only** what's specific to this repo.

## What this repo is

Internal QA tooling — fork of `firstloophq/claude-code-test-runner`, hosting the JourneyHawk browser-test harness for all Phronex products. Not a product. No users. No PRD. No internal roadmap.

## Roadmap lives elsewhere

This repo's evolution is driven entirely by **phronex-common milestone roadmaps**, currently `v18.0 — Test Strategist Layer`. Authoritative sources:

- `/home/ouroborous/code/phronex-common/.planning/ROADMAP.md` — Phase 80/81/82
- `/home/ouroborous/code/phronex-common/.planning/REQUIREMENTS.md` — STRAT-01..18

If you're about to plan something new in this repo, **first check whether it belongs in phronex-common**. Cross-product runner-side concerns belong here; runner-internal mechanics that other QA tools could reuse belong in `phronex-common.testing`.

## GSD scope (minimal)

GSD is initialized scaffold-only. Allowed:
- `/gsd:quick BRIEF.md` — one-shot deliverables driven by external briefs
- `/gsd:plan-phase N` — only if phronex-common assigns a phase number to runner-side work, and `N` MUST match the phronex-common phase number

Not used here:
- `/gsd:new-project`, `/gsd:new-milestone`, `/gsd:audit-milestone`, `/gsd:complete-milestone` — no internal milestones to audit/complete
- Research subagents — no greenfield work
- Plan-checker, verifier, nyquist — operator handles judgment

`config.json` reflects this: `mode:yolo`, `granularity:coarse`, all workflow agents `false`.

## The JourneyHawk skill is the runtime contract

`~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md` defines what the runner MUST satisfy:

- **PHASE 0 (DocChain Gate)** — refuse to run if `.docs/USER-SPEC.html` is missing/stale on the target product
- **PHASE 1 (Intelligence Load)** — query `phronex_qa` for active defects, wiki articles, patterns, history before any journey
- **Run Filter** — three-reason table (A: known broken + fix landed, B: DocChain changed + journey covers area, C: new journey)
- **Product scope lock** — one product per session, hard-blocked otherwise
- **No cron** — runs only when invoked by skill

When changing runner code, re-read the skill section that owns the contract you're touching. Do not unilaterally relax a gate.

## Persistence

All persistence goes to `phronex_qa` on DevServer (192.168.1.250:5432). NEVER to EC2. Schema:
- `qa_known_defects` — every defect found
- `qa_wiki_articles` — cross-product lessons (NOT scoped to one product)
- `qa_patterns` — promoted patterns (seen 2+)
- `qa_evidence` — SHA256-keyed evidence bundles
- `qa_journeys` — run archive
- `qa_docchain_snapshots` — per-product `.docs/` SHA256 history
- `qa_ethos_rules` — governance (UUID-keyed, distinct from testing-side string-keyed shape — adapter-translate, never unify)
- `entity_memory.*` — tester EntityBrain (per-tester, per-product `PastDecision` rows)

## Jira integration

**Active.** Project key `PHX` (renamed from `CC` on 2026-04-30). Site: `https://phronex.atlassian.net/`. Two paths:
1. Automatic via `runner.py:open_jira_tickets()` (controlled by `PHRONEX_QA_JIRA_SINK_ENABLED=true` in `.qa.env`)
2. Manual via Atlassian MCP (`mcp__plugin_atlassian_atlassian__createJiraIssue`)

After creating a ticket via path 2, update `qa_known_defects.jira_ticket_url` with the returned URL.

## Untracked files of note

- `.qa.env` — secrets, must stay untracked
- `STRATEGIST-ARCHITECTURE.md`, `STRATEGIST-IMPLEMENTATION-PLAN.md` — drafts for v18.0; commit when ready
- `strategist-prep/BLOCK-A-QUICK-BRIEF.md` — feeds the next `/gsd:quick` invocation
- `portal-journeys/results-*/` — run output, should be gitignored if not already

## Hard "do not"s

- Do not write a v1 product roadmap for this repo. There isn't one.
- Do not unilaterally remove or relax a JourneyHawk skill gate. Propose first; wait for approval.
- Do not run journeys against EC2 production data without explicit operator approval.
- Do not commit `.qa.env` or any file containing `JIRA_API_TOKEN`, `PHRONEX_QA_DATABASE_URL_SYNC`, or OAuth tokens.
- Do not add features to `runner.py` that bypass the run filter — the filter is the audit trail.

---
*Last updated: 2026-05-01 — repo-specific addendum to global Phronex CLAUDE.md*
