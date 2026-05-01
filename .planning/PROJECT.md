---
project: phronex-test-runner
type: internal-tooling
created: 2026-05-01
status: scaffold-only
---

# phronex-test-runner

## What This Is

Internal QA tooling repository — fork of [`firstloophq/claude-code-test-runner`](https://github.com/firstloophq/claude-code-test-runner) — hosting the **JourneyHawk** browser-test harness for all Phronex products (CC, JP, Praxis, Portal, ComC, Phronex.com).

This is **not a product** — it has no users, no revenue path, no roadmap of its own. It is a tool. Its purpose is to:

1. Execute browser journeys defined in `portal-journeys/*.json` and `*-journeys/*.json`
2. Capture evidence (screenshots, DOM traces, network logs)
3. Feed results into the JourneyHawk intelligence pipeline (`phronex_qa` DB on DevServer)
4. Surface defects, half-built features, and friction back to product owners via Jira + ComC

## Why GSD Init

This repo's roadmap is defined externally — by the **phronex-common v18.0 Strategist Layer** milestone (`/home/ouroborous/code/phronex-common/.planning/ROADMAP.md` Phase 80/81/82). Several v18.0 deliverables (Block A in particular: P1 RunArbiter + P2 Fixture Guard) live in this repo because they are runner-side concerns.

GSD is initialized **only** so that:
- `/gsd:quick` works for one-shot deliverables defined by external briefs (e.g. `BLOCK-A-QUICK-BRIEF.md`)
- `/gsd:plan-phase N` works if any future v18.x phase needs a longer plan in this repo
- Atomic commits and `STATE.md` tracking apply to runner-side work

There is **no PRD, no requirements milestone, no v1 roadmap for this repo itself**. Treat its lifecycle as a service to phronex-common milestones.

## Core Value

JourneyHawk is the only system that catches "feature exists in code but is broken in the browser" defects. Without it, every Phronex product ships with a thin smoke-test net and undetected user-facing failures. The runner must be:
- **Deterministic** — same journey, same result (no flake)
- **Honest** — empty result data fails the test (HALF_BUILT detection)
- **Cheap to extend** — adding a new product or journey takes <1 hour

## Requirements

### Validated (existing in repo)

- ✓ JourneyHawk runner orchestrates browser journeys via Playwright + Claude Code
- ✓ Per-product journey specs in `portal-journeys/`, `cc-journeys/`, `jp-journeys/`, etc.
- ✓ Results posted to `phronex_qa` DB on DevServer
- ✓ Evidence bundles (screenshots, DOM traces) keyed by SHA256
- ✓ DocChain artefact gate (Phase 0) — refuses to run if `.docs/USER-SPEC.html` is stale
- ✓ Product scope lock — one product per session, hard-blocked otherwise
- ✓ Cross-product wiki articles consolidate lessons (`qa_wiki_articles`)
- ✓ Jira sink (`PHRONEX_QA_JIRA_SINK_ENABLED=true`, project `PHX`)

### Active (driven by phronex-common v18.0 Block A)

- [ ] **P1 RunArbiter** — central run-eligibility decision (replaces ad-hoc filter logic in `runner.py:484`)
- [ ] **P2 Fixture Guard** — validate `qa_test_fixtures` table state before run; refuse if pollution detected

(Both deliverables defined in `strategist-prep/BLOCK-A-QUICK-BRIEF.md`. Not yet started.)

### Out of Scope

- A roadmap of this repo's own evolution — owned by phronex-common milestones
- Public-facing features — internal tool, no marketing surface
- Multi-tenant runner isolation — single operator, single machine
- Replacing Playwright or Claude Code — both are foundational dependencies

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| GSD scaffold-only init | Roadmap lives in phronex-common, not here | — Active 2026-05-01 |
| Skip research/requirements/roadmap GSD phases | No greenfield work; all deliverables come from external briefs | — Active 2026-05-01 |
| Use `/gsd:quick` for Block A | One-shot deliverable, scope locked by brief | — Pending Block A spike |
| `commit_docs: true` | Planning docs version-controlled with runner code | — Active |
| YOLO mode + no plan-checker / verifier | Tooling repo, operator handles judgment calls | — Active |

## Cross-Repo Dependencies

| Repo | Relationship |
|------|--------------|
| `phronex-common` | Imports `phronex_common.testing.docchain`, `phronex_common.testing.adapters`, `phronex_common.product_registry`, `phronex_common.governance` |
| `phronex_qa` (DB on DevServer 192.168.1.250:5432) | Persistence layer for `qa_known_defects`, `qa_wiki_articles`, `qa_patterns`, `qa_evidence`, `qa_journeys`, `qa_docchain_snapshots`, `qa_ethos_rules`, `entity_memory.*` |
| `~/.claude/skills/Phronex_Internal_QA_JourneyHawk/SKILL.md` | The runtime contract — runner must satisfy what the skill expects (PHASE 0 gate, intelligence load, run filter) |
| All Phronex product repos | Each consumed via DocChain artefacts in `.docs/` and via JourneyHawk journey specs |

## Operational Notes

- **Single operator** — Vivek runs JourneyHawk manually via the skill
- **Cron-blocked** — runs only when invoked by the skill, never on a schedule (per skill invariant)
- **Devserver-only execution** — runner needs network access to DevServer's `phronex_qa` DB
- **Cost** — ~$6.60/month at v18.0 Strategist Layer baseline (per `.planning/research/ai-eval.md` in phronex-common)

## Evolution

This document evolves only when:
1. The repo's relationship to phronex-common milestones changes
2. A new product joins the JourneyHawk surface
3. A core dependency (Playwright, Claude Code, `phronex_qa` schema) shifts in a way that changes operational invariants

It does NOT evolve per phase or per Block — those are tracked in phronex-common's STATE.md and the relevant `BLOCK-*-BRIEF.md` files.

---
*Last updated: 2026-05-01 after scaffold-only initialization*
