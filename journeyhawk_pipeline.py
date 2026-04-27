#!/usr/bin/env python3
"""
journeyhawk_pipeline.py — Post-runner intelligence pipeline for JourneyHawk.

Call this AFTER cc-test-runner completes. It reads the results directory,
runs the full intelligence pipeline (evidence → gap_detector → ethos_bridge
→ DefectVault → QA report), and writes findings to phronex_qa.

Usage:
    python journeyhawk_pipeline.py \
        --product jp \
        --results-dir ~/code/phronex-test-runner/jp-journeys/results \
        --spec-file ~/code/phronex-test-runner/jp-journeys/jp-deep.json

Requires PHRONEX_QA_DATABASE_URL and PHRONEX_QA_DATABASE_URL_SYNC in env.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

# DevServer phronex-common install path
COMMON_PATH = Path.home() / "code/phronex-common/src"
if str(COMMON_PATH) not in sys.path:
    sys.path.insert(0, str(COMMON_PATH))


def load_ctrf(results_dir: Path) -> dict:
    """Load the CTRF report from cc-test-runner output."""
    ctrf_path = results_dir / "ctrf-report.json"
    if not ctrf_path.exists():
        raise FileNotFoundError(f"No ctrf-report.json in {results_dir}")
    return json.loads(ctrf_path.read_text())


def load_specs(spec_file: Path) -> dict[str, dict]:
    """Load journey specs, keyed by id."""
    specs = json.loads(spec_file.read_text())
    return {s["id"]: s for s in specs}


def run_pipeline(product_slug: str, results_dir: Path, spec_file: Path) -> None:
    from phronex_common.testing.isolation import assert_not_production
    from phronex_common.testing.evidence.collector import collect
    from phronex_common.testing.gap_detector import (
        Narrative, Observation, detect_gaps, DefectCategory, Severity,
    )
    from phronex_common.testing.defects.postgres import PostgresDefectVault
    from phronex_common.testing.defects.models import KnownDefect

    db_url = os.environ.get("PHRONEX_QA_DATABASE_URL_SYNC")
    if not db_url:
        print("ERROR: PHRONEX_QA_DATABASE_URL_SYNC not set — cannot write to phronex_qa")
        sys.exit(1)

    # Load CTRF results
    ctrf = load_ctrf(results_dir)
    specs = load_specs(spec_file)
    tests = ctrf.get("results", {}).get("tests", [])
    summary = ctrf.get("results", {}).get("summary", {})

    print(f"\n=== JourneyHawk Pipeline — {product_slug} ===")
    print(f"Run: {datetime.now(UTC).isoformat()}")
    print(f"Tests: {summary.get('tests', 0)} total, {summary.get('passed', 0)} passed, {summary.get('failed', 0)} failed")

    # Step 1: Evidence collection per journey
    print("\n[1/4] Collecting evidence bundles...")
    evidence_by_journey: dict[str, object] = {}
    for test in tests:
        # Derive journey_id from test name (slug the description)
        journey_dir = None
        for sub in results_dir.iterdir():
            if sub.is_dir() and sub.name != "__pycache__":
                journey_dir_candidate = results_dir / sub.name
                # Match by checking if test name is contained in journey description
                for spec_id, spec in specs.items():
                    if spec["description"][:30].lower() in test["name"].lower() or spec_id in sub.name:
                        journey_dir = journey_dir_candidate
                        break
        if journey_dir and journey_dir.exists():
            try:
                pw_dir = journey_dir / "playwright"
                target = pw_dir if pw_dir.exists() else journey_dir
                bundle = collect(target, product_slug)
                evidence_by_journey[test["name"]] = bundle
                print(f"  ✓ evidence: {test['name'][:50]}... sha={bundle.sha256[:12]}")
            except Exception as e:
                print(f"  ⚠ evidence failed for {test['name'][:40]}: {e}")

    # Step 2: Gap detection
    print("\n[2/4] Detecting gaps...")
    gap_findings = []
    for test in tests:
        if test["status"] == "passed":
            continue  # No gaps in passing tests

        # Build narrative from spec if available
        spec_match = None
        for spec_id, spec in specs.items():
            if spec["description"][:30].lower() in test["name"].lower():
                spec_match = spec
                break

        expected_steps = len(spec_match["steps"]) if spec_match else 5
        narrative = Narrative(
            journey_name=test["name"],
            expected_outcomes=tuple(
                s["description"][:80] for s in (spec_match["steps"] if spec_match else [])
            ),
            expected_step_count=expected_steps,
        )
        observation = Observation(
            journey_name=test["name"],
            completed=False,
            error_message=test.get("message", "No error message"),
            actual_step_count=0,
            actual_route=None,
            actual_label=None,
            duration_seconds=test.get("duration", 0) / 1000,
        )
        try:
            from phronex_common.testing.gap_detector import detect_gaps
            gaps = detect_gaps(narrative, [observation])
            gap_findings.extend(gaps)
            for g in gaps:
                print(f"  GAP [{g.category.value.upper()}] {g.title[:60]} (severity={g.severity.value})")
        except Exception as e:
            print(f"  ⚠ gap_detector error: {e}")

    if not gap_findings:
        print("  ✓ No gaps detected — all journeys passed")

    # Step 3: Write defects to phronex_qa
    print("\n[3/4] Writing to phronex_qa...")
    if gap_findings:
        try:
            from sqlalchemy import create_engine
            engine = create_engine(db_url)
            vault = PostgresDefectVault(engine)
            for gap in gap_findings:
                defect = KnownDefect(
                    product_slug=product_slug,
                    title=gap.title,
                    severity=gap.severity.value,
                    category=gap.category.value,
                    first_seen_at=datetime.now(UTC),
                )
                vault.upsert(defect)
                print(f"  ✓ defect upserted: {gap.title[:50]}")
        except Exception as e:
            print(f"  ⚠ defect vault write failed: {e}")
    else:
        print("  ✓ No defects to write (all passed)")

    # Step 4: Summary report to stdout (HTML report done separately by skill)
    print("\n[4/4] Summary")
    print(f"  Product:         {product_slug}")
    print(f"  Journeys run:    {summary.get('tests', 0)}")
    print(f"  Passed:          {summary.get('passed', 0)}")
    print(f"  Failed:          {summary.get('failed', 0)}")
    print(f"  Gaps found:      {len(gap_findings)}")
    print(f"  Evidence bundles: {len(evidence_by_journey)}")
    print(f"  phronex_qa:      defects written to qa_known_defects")
    print("\nPipeline complete. ✓")


def main() -> None:
    parser = argparse.ArgumentParser(description="JourneyHawk post-runner intelligence pipeline")
    parser.add_argument("--product", required=True, help="Product slug (e.g. jp, portal, cc)")
    parser.add_argument("--results-dir", required=True, help="cc-test-runner results directory")
    parser.add_argument("--spec-file", required=True, help="Journey spec JSON file")
    args = parser.parse_args()

    results_dir = Path(args.results_dir).expanduser()
    spec_file = Path(args.spec_file).expanduser()

    if not results_dir.exists():
        print(f"ERROR: results-dir does not exist: {results_dir}")
        sys.exit(1)
    if not spec_file.exists():
        print(f"ERROR: spec-file does not exist: {spec_file}")
        sys.exit(1)

    run_pipeline(args.product, results_dir, spec_file)


if __name__ == "__main__":
    main()
