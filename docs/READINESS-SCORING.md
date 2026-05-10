# Readiness Dimensions (10 Dimensions, Weighted Composite)

The readiness scorer computes a single composite score from 10 independently-calculated dimensions. JourneyHawk's goal is to reach SHIP (>=0.85). Understanding each dimension helps diagnose what's holding a product back.

| # | Dimension | Weight | Source table | What it measures |
|---|-----------|--------|--------------|-----------------|
| 1 | defect_density | 0.15 | qa_known_defects | Ratio of open defects to total journeys. Lower = better |
| 2 | defect_severity | 0.12 | qa_known_defects | Weighted severity of open defects (CRITICAL=4, HIGH=3, MEDIUM=2, LOW=1) |
| 3 | pass_rate | 0.15 | qa_confidence_scores | % of journeys classified STABLE. FLAKY excluded (quarantined) |
| 4 | ux_health | 0.08 | qa_ux_signals | UX fatigue metrics: 6 sub-signals averaged |
| 5 | confidence_coverage | 0.10 | qa_confidence_scores | % of journeys with sufficient data for Wilson classification |
| 6 | velocity_trend | 0.10 | qa_velocity_metrics | Defect creation rate trend (decreasing = positive) |
| 7 | feature_coverage | 0.10 | qa_feature_coverage | % of USER-SPEC features with at least one passing journey |
| 8 | propagation_risk | 0.05 | qa_propagation_alerts | Unresolved cross-product propagation alerts count |
| 9 | prevention_effectiveness | 0.08 | qa_prevention_rules | % of prevention rules that successfully prevented repeat defects |
| 10 | proposal_staleness | 0.07 | qa_proposed_heuristics | % of proposed heuristics still `pending_apply` for >7 days |

## Readiness Levels

- **SHIP** (>=0.85): Product is ready for production deployment or customer demo
- **DEMO** (>=0.70): Suitable for internal demo; some defects remain but nothing critical
- **DEVELOP** (>=0.50): Active development; significant defects exist
- **HOLD** (<0.50): Not ready for any external exposure; fundamental issues

## Cold-start Handling

When a product has <3 completed runs, the scorer applies minimum-data floor weights. Dimensions without data get a neutral 0.50 instead of 0.0, preventing artificially low scores on first runs.
