# Jira Integration — Setup & Configuration

**Jira IS active.** The Atlassian MCP is connected and API keys are configured. Site: `https://phronex.atlassian.net/`.

## Confirmed Jira Project

`PHX` (renamed from `CC` on 2026-04-30). Name: "Phronex QA". URL: `https://phronex.atlassian.net/jira/software/projects/PHX/boards`.

## Path A — Automatic via `open_jira_tickets()` (runner.py pipeline)

- Called after every run for BROKEN and HALF_BUILT findings the operator defers
- Controlled by env var `PHRONEX_QA_JIRA_SINK_ENABLED=true` (already set in `.qa.env`)
- Project key: `PHRONEX_QA_JIRA_PROJECT=PHX` (already set in `.qa.env`)
- Cloud ID: `PHRONEX_ATLASSIAN_CLOUD_ID=b6329a4b-542e-42bb-b2f8-9001079d9a49` (set)
- API token: `JIRA_API_TOKEN=<token>` (already set in `.qa.env`)
- User: `JIRA_USER=vivek@phronex.com` (already set in `.qa.env`)
- Ticket URLs written back to `qa_known_defects.jira_ticket_url`
- Severity mapping: CRITICAL→Blocker, HIGH→Critical, MEDIUM→Major, LOW→Minor

## Path B — Direct via Atlassian MCP (manual or when runner path not available)

```
mcp__plugin_atlassian_atlassian__createJiraIssue
  summary: "[JourneyHawk] {defect title}"
  description: "{defect body from qa_known_defects}"
  issueType: "Task"
  projectKey: "PHX"
```
Use `defect_id` from `qa_known_defects` as the ticket reference. After creating, update `qa_known_defects.jira_ticket_url` with the returned issue URL.

## Verify Jira env vars are live

```bash
grep -E "JIRA|PHRONEX_QA_JIRA|PHRONEX_ATLASSIAN" ~/code/.qa.env
# Expected output:
# JIRA_USER=vivek@phronex.com
# PHRONEX_QA_JIRA_SINK_ENABLED=true
# PHRONEX_QA_JIRA_PROJECT=PHX
# PHRONEX_ATLASSIAN_CLOUD_ID=b6329a4b-542e-42bb-b2f8-9001079d9a49
# JIRA_API_TOKEN=<token>
```
