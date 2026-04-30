#!/usr/bin/env python3
"""Generate portal-admin-deep.json from adminTabs.ts TAB_GROUPS.

Re-run whenever adminTabs.ts changes — new tab groups auto-appear in the spec.
The generated spec is committed and used by JourneyHawk for the full portal deep audit.

Usage:
    python scripts/generate-portal-admin-deep.py \\
        --admin-tabs ../../phronex-portal/src/app/(dashboard)/admin/adminTabs.ts \\
        --out portal-journeys/portal-admin-deep.json

Credentials are read from environment variables. Set them in .qa.env:
    QA_SUPERADMIN_EMAIL
    QA_SUPERADMIN_PASSWORD
    QA_OWNER_EMAIL
    QA_OWNER_PASSWORD
    QA_USER_EMAIL
    QA_USER_PASSWORD

If variables are missing the script exits with instructions — it never creates accounts.
Use phronex_common.testing.adapters.portal.PortalAdapter to provision missing QA accounts.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Column A actions: the state-mutating step performed in each group journey.
# These are embedded in step 5 of each group's journey.
# Keys must match the group label exactly (case-sensitive).
# ---------------------------------------------------------------------------
COLUMN_A_ACTIONS: dict[str, str] = {
    "CEO View": (
        "Navigate to https://app.phronex.com/admin?tab=accounts. "
        "Verify the CEO Scorecard KPI tiles (Total Users, Active Users, CC Instances, Grants, Subscriptions) "
        "show numeric values — not '--' or blank. At least one tile must show a number > 0. "
        "Then navigate to https://app.phronex.com/admin?tab=backup and verify the backup status badge "
        "is not 'unknown' (it may show 'healthy', 'pending', or a timestamp — any of these is a pass). "
        "Record the actual values seen for both tabs."
    ),
    "Financial": (
        "Navigate to https://app.phronex.com/admin?tab=cost-intelligence. "
        "Read any numeric cost figure visible in the main panel (e.g. a monthly total, an infra line item). "
        "Note the value. Then navigate to https://app.phronex.com/admin?tab=infra-cost. "
        "Verify infra-cost tab shows cost data (not blank or zero). "
        "Cross-reference: if cost-intelligence showed a figure, infra-cost should show the same or a component breakdown. "
        "Report the two figures and whether they are consistent."
    ),
    "Customer": (
        "Navigate to https://app.phronex.com/admin?tab=b2b-users. "
        "Click into the first user row visible in the table (if the table is empty, report empty-state and skip the click). "
        "If a user detail panel opens, verify it contains at least: email address, role badge, and grants list. "
        "Report what fields are populated and whether the panel opened successfully."
    ),
    "Internal Process": (
        "Navigate to https://app.phronex.com/admin?tab=audit. "
        "Use page.evaluate() to intercept the network response: "
        "const resp = await fetch('/api/admin/auth/api/v1/admin/audit-trigger', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'}); "
        "const body = await resp.json(); "
        "Verify the response contains a job_id field (non-empty string). "
        "Report the job_id value and HTTP status code. "
        "Do NOT wait for the audit to complete — just confirm the trigger endpoint returns a job_id."
    ),
    "Learning & Growth": (
        "Navigate to https://app.phronex.com/admin?tab=skill-review. "
        "Verify the skill list renders at least one skill card. "
        "For the first card visible, read its status badge (e.g. 'Active', 'Pending', 'Suspended'). "
        "The badge must be non-empty and one of the known status values. "
        "Report the badge text seen and the number of skill cards visible."
    ),
    "Launchpad": (
        "Navigate to https://app.phronex.com/admin?tab=new-product. "
        "Find the product name input field. Type 'qa-test-launchpad-probe' into it. "
        "Verify the slug field auto-populates from the name (it should become 'qa-test-launchpad-probe' or a slugified version). "
        "Do NOT submit the form. Clear the name field after verifying. "
        "Report whether slug auto-population worked."
    ),
    "Admin Plumbing": (
        "Navigate to https://app.phronex.com/admin?tab=rbac-orgs. "
        "Click the 'Create Organisation' button (or 'Create' if labelled differently). "
        "Verify the inline form opens with at least a Name field and a Slug field. "
        "Type 'qa-probe-org' into the Name field. Verify Slug auto-populates. "
        "Click Cancel (do NOT submit — this is a probe, not a real org creation). "
        "Verify the form closes after Cancel. "
        "Report: form opened (yes/no), slug auto-populated (yes/no), form closed after Cancel (yes/no)."
    ),
}


def parse_tab_groups(ts_path: Path) -> list[dict]:
    """Extract TAB_GROUPS from adminTabs.ts using regex."""
    src = ts_path.read_text()

    # Extract the TAB_GROUPS array literal as a string
    match = re.search(r"export const TAB_GROUPS[^=]*=\s*(\[[\s\S]*?\]);\s*\n", src)
    if not match:
        sys.exit(f"Could not find TAB_GROUPS in {ts_path}")

    raw = match.group(1)

    # Extract each group block: { label: '...', tabs: [...] }
    group_pattern = re.compile(
        r"\{\s*label:\s*'([^']+)'[^{]*?tabs:\s*\[([\s\S]*?)\]\s*\}",
        re.MULTILINE,
    )
    tab_pattern = re.compile(r"\{\s*id:\s*'([^']+)'[^}]*?label:\s*'([^']+)'[^}]*?\}")

    groups = []
    for gm in group_pattern.finditer(raw):
        group_label = gm.group(1)
        tabs_raw = gm.group(2)
        tabs = [{"id": m.group(1), "label": m.group(2)} for m in tab_pattern.finditer(tabs_raw)]
        if tabs:
            groups.append({"label": group_label, "tabs": tabs})

    if not groups:
        sys.exit("No groups parsed — regex may need updating if adminTabs.ts format changed.")

    return groups


def slug(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")


def make_group_journey(group: dict, email: str, password: str) -> dict:
    label = group["label"]
    tabs = group["tabs"]
    first_tab = tabs[0]["id"]
    remaining = [t["id"] for t in tabs[1:]]
    tab_list = ", ".join(remaining) if remaining else "(only one tab in this group)"
    column_a = COLUMN_A_ACTIONS.get(label, f"Verify the {label} group panels render real data, not placeholder values.")

    return {
        "id": f"portal-admin-deep-{slug(label)}",
        "description": f"Deep audit: {label} group ({len(tabs)} tab{'s' if len(tabs) != 1 else ''}) — tab render + Column A state mutation",
        "steps": [
            {
                "id": 1,
                "description": "BROWSER RESET FIRST: Use browser_tabs to list all open tabs. Close all tabs except one. Clear localStorage for app.phronex.com to avoid stale session state from previous runs.",
            },
            {
                "id": 2,
                "description": f"Navigate to https://app.phronex.com/auth/login. Log in with email '{email}' and password '{password}'. Wait until the URL no longer contains /auth/login before proceeding.",
            },
            {
                "id": 3,
                "description": f"Navigate to https://app.phronex.com/admin?tab={first_tab}. Verify the panel loads — no ErrorBoundary crash, no blank white body, no permanent loading spinner. Take a screenshot.",
            },
            {
                "id": 4,
                "description": f"For each of the following admin tabs in the {label} group: {tab_list} — navigate to https://app.phronex.com/admin?tab={{tab_id}} for each one. Verify each tab renders panel content. Do not stop at the first failure — visit all tabs. For each tab record: PASS (content visible), FAIL (error type: 404/500/ErrorBoundary/blank), or EMPTY-STATE (panel renders but shows no data).",
            },
            {
                "id": 5,
                "description": column_a,
            },
            {
                "id": 6,
                "description": "Take a final screenshot of the last tab visited. Report: (a) tabs that PASSed, (b) tabs that FAILed with error type, (c) tabs in EMPTY-STATE, (d) Column A action result (PASS/FAIL/EMPTY-STATE with observed values), (e) any JavaScript console errors seen.",
            },
        ],
    }


def make_rbac_journey(role: str, email: str, password: str) -> dict:
    return {
        "id": f"portal-admin-rbac-{role}",
        "description": f"RBAC gate: {role} role must be redirected away from /admin (server-side requireSuperadmin guard)",
        "steps": [
            {
                "id": 1,
                "description": "BROWSER RESET FIRST: Close all extra tabs, clear cookies and localStorage for app.phronex.com.",
            },
            {
                "id": 2,
                "description": f"Navigate to https://app.phronex.com/auth/login. Log in with email '{email}' and password '{password}'. Wait for redirect away from /auth/login.",
            },
            {
                "id": 3,
                "description": "Navigate directly to https://app.phronex.com/admin. Note the resulting URL after any redirects settle.",
            },
            {
                "id": 4,
                "description": "Confirm the page did NOT render admin panel content — no tab group pills ('CEO VIEW', 'FINANCIAL', etc.) should be visible, no admin heading. Confirm the URL redirected away from /admin (expected destination: /products or /dashboard).",
            },
            {
                "id": 5,
                "description": "Also navigate to https://app.phronex.com/admin?tab=auth-config — this must also redirect, not render admin content.",
            },
            {
                "id": 6,
                "description": "Screenshot the final URL. Report PASS if all /admin paths redirected without rendering admin content, FAIL if any admin content was visible.",
            },
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate portal-admin-deep.json from adminTabs.ts")
    parser.add_argument("--admin-tabs", required=True, help="Path to adminTabs.ts")
    parser.add_argument("--out", required=True, help="Output JSON path")
    args = parser.parse_args()

    admin_tabs_path = Path(args.admin_tabs)
    if not admin_tabs_path.exists():
        sys.exit(f"adminTabs.ts not found at: {admin_tabs_path}")

    # Resolve QA credentials from env
    missing = []
    superadmin_email = os.environ.get("QA_SUPERADMIN_EMAIL", "")
    superadmin_password = os.environ.get("QA_SUPERADMIN_PASSWORD", "")
    owner_email = os.environ.get("QA_OWNER_EMAIL", "")
    owner_password = os.environ.get("QA_OWNER_PASSWORD", "")
    user_email = os.environ.get("QA_USER_EMAIL", "")
    user_password = os.environ.get("QA_USER_PASSWORD", "")

    for name, val in [
        ("QA_SUPERADMIN_EMAIL", superadmin_email),
        ("QA_SUPERADMIN_PASSWORD", superadmin_password),
        ("QA_OWNER_EMAIL", owner_email),
        ("QA_OWNER_PASSWORD", owner_password),
        ("QA_USER_EMAIL", user_email),
        ("QA_USER_PASSWORD", user_password),
    ]:
        if not val:
            missing.append(name)

    if missing:
        print("ERROR: Missing QA credential env vars:", ", ".join(missing), file=sys.stderr)
        print("Set them in .qa.env and source it before running.", file=sys.stderr)
        print("To provision missing QA accounts:", file=sys.stderr)
        print("  python -c \"from phronex_common.testing.adapters.portal import PortalAdapter; PortalAdapter().provision_personas()\"", file=sys.stderr)
        sys.exit(1)

    groups = parse_tab_groups(admin_tabs_path)
    print(f"Parsed {len(groups)} groups from {admin_tabs_path.name}:")
    for g in groups:
        print(f"  {g['label']}: {len(g['tabs'])} tabs")

    journeys = []

    # 7 superadmin group journeys
    for group in groups:
        journeys.append(make_group_journey(group, superadmin_email, superadmin_password))

    # 2 RBAC journeys
    journeys.append(make_rbac_journey("owner", owner_email, owner_password))
    journeys.append(make_rbac_journey("user", user_email, user_password))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(journeys, indent=2))

    print(f"\nGenerated {len(journeys)} journeys → {out_path}")
    print("Re-run this script whenever adminTabs.ts changes.")


if __name__ == "__main__":
    main()
