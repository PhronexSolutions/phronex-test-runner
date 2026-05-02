"""Export qa_known_defects to a structured JSON seed for P4 RCAEngine.

Run from repo root or strategist-prep/:
    PHRONEX_QA_DATABASE_URL_SYNC=... python export_heuristics_seed.py

Output: qa_known_defects_seed.json (committed for traceability of what P4 was seeded with).

The shape produced here is what the P4 deterministic-first heuristics YAML
will be backfilled from. Severity is normalised to lower-case (the existing
table mixes "critical" and "HIGH" — once we have the seed file we'll know
the canonical set).
"""
from __future__ import annotations

import json
import os
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

import psycopg2
from psycopg2.extras import RealDictCursor

DEFAULT_URL = "postgresql+psycopg2://phronex_qa:phx_qa_local_2026@localhost:5432/phronex_qa"


def _to_psycopg_url(url: str) -> str:
    """Strip SQLAlchemy driver prefix so psycopg2 can consume the URL directly."""
    return url.replace("postgresql+psycopg2://", "postgresql://", 1)


def main() -> int:
    url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC", DEFAULT_URL)
    out_path = Path(__file__).parent / "qa_known_defects_seed.json"

    with psycopg2.connect(_to_psycopg_url(url)) as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    defect_id,
                    product_slug,
                    title,
                    LOWER(severity) AS severity,
                    category,
                    fix_commit_sha,
                    regression_test_ref,
                    first_seen_at,
                    fixed_at,
                    reoccurred_count,
                    (fixed_at IS NOT NULL) AS is_fixed,
                    (reoccurred_count > 0)  AS has_reoccurred
                FROM qa_known_defects
                ORDER BY product_slug, category, severity DESC, defect_id;
                """
            )
            rows = cur.fetchall()

    defects = []
    for row in rows:
        defects.append(
            {
                "defect_id": row["defect_id"],
                "product_slug": row["product_slug"],
                "title": row["title"],
                "severity": row["severity"],
                "category": row["category"],
                "fix_commit_sha": row["fix_commit_sha"],
                "regression_test_ref": row["regression_test_ref"],
                "first_seen_at": row["first_seen_at"].isoformat() if row["first_seen_at"] else None,
                "fixed_at": row["fixed_at"].isoformat() if row["fixed_at"] else None,
                "reoccurred_count": row["reoccurred_count"],
                "is_fixed": row["is_fixed"],
                "has_reoccurred": row["has_reoccurred"],
            }
        )

    by_product = Counter(d["product_slug"] for d in defects)
    by_category = Counter(d["category"] for d in defects)
    by_severity = Counter(d["severity"] for d in defects)
    open_count = sum(1 for d in defects if not d["is_fixed"])
    reoccurred_count = sum(1 for d in defects if d["has_reoccurred"])

    payload = {
        "exported_at": datetime.now(UTC).isoformat(),
        "source_db": "phronex_qa.qa_known_defects",
        "purpose": "P4 RCAEngine deterministic-first heuristics seed corpus",
        "summary": {
            "total_defects": len(defects),
            "open_defects": open_count,
            "fixed_defects": len(defects) - open_count,
            "reoccurred_defects": reoccurred_count,
            "by_product": dict(by_product),
            "by_category": dict(by_category),
            "by_severity": dict(by_severity),
        },
        "defects": defects,
    }

    out_path.write_text(json.dumps(payload, indent=2, default=str))
    print(f"Wrote {len(defects)} defects to {out_path}")
    print(f"  by_product: {dict(by_product)}")
    print(f"  by_category: {dict(by_category)}")
    print(f"  by_severity: {dict(by_severity)}")
    print(f"  open: {open_count} | reoccurred: {reoccurred_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
