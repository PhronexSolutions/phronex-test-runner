# Deprecated JP Journey Specs

## Deprecated smoke-only files

- `jp-smoke.json` — DEPRECATED: 7 page-load-only journeys (no state mutations). Superseded by jp-deep.json trunk runs.
- `jp-smoke2.json` — DEPRECATED: 2 isolated retest journeys. Superseded by jp-deep.json `--runJourney` flag.
- `jp-d02-only.json` — DEPRECATED: single-journey isolation file. Use `--runJourney jp-d02` instead.
- `jp-d06-d07-rerun.json` — DEPRECATED: partial rerun file. Use `--runJourney jp-d06` etc. instead.
- `jp-retry.json` — DEPRECATED: ad-hoc retry file. Use `--runJourney <id>` instead.
- `jp-payment.json` — DEPRECATED: moved to jp-deep.json payment leaf nodes.

## Current Spec

| File | Journeys | Purpose |
|------|----------|---------|
| `jp-deep.json` | 26 nodes (tree) | **Active** — full JP test suite with trunk/branch/leaf model |

## Running

```bash
# Full JP run with intelligence pipeline:
./run-journeyhawk.sh jp jp-journeys/jp-deep.json

# Smoke run — main account auth only:
./cli/cc-test-runner -t jp-journeys/jp-deep.json -o results-smoke-jp --runJourney jp-trunk-main

# Single journey with ancestor chain:
./cli/cc-test-runner -t jp-journeys/jp-deep.json -o results-isolated-jp --runJourney jp-verify-job-apply
```
