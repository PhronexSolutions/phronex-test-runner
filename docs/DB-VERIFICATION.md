# Post-Run DB Verification Queries

After every pipeline run, JourneyHawk uses these queries to confirm data landed correctly. These are the single source of truth. If the report says "3 defects" but the DB shows 2, investigate the pipeline.

## Full State Check (run after every pipeline completion)

```sql
SELECT 'defects' AS t, count(*) FROM qa_known_defects WHERE product_slug='<slug>'
UNION ALL SELECT 'rca', count(*) FROM qa_defect_rca
UNION ALL SELECT 'verdicts', count(*) FROM qa_journey_verdicts WHERE product_slug='<slug>'
UNION ALL SELECT 'confidence', count(*) FROM qa_confidence_scores WHERE product_slug='<slug>'
UNION ALL SELECT 'readiness', count(*) FROM qa_readiness_reports WHERE product_slug='<slug>'
UNION ALL SELECT 'ux_signals', count(*) FROM qa_ux_signals WHERE product_slug='<slug>'
UNION ALL SELECT 'proposals', count(*) FROM qa_proposed_heuristics
UNION ALL SELECT 'wiki', count(*) FROM qa_wiki_articles
UNION ALL SELECT 'patterns', count(*) FROM qa_patterns
UNION ALL SELECT 'journeys', count(*) FROM qa_journeys WHERE product_slug='<slug>'
UNION ALL SELECT 'prevention', count(*) FROM qa_prevention_rules
UNION ALL SELECT 'propagation', count(*) FROM qa_propagation_alerts
UNION ALL SELECT 'coverage', count(*) FROM qa_feature_coverage WHERE product_slug='<slug>'
UNION ALL SELECT 'velocity', count(*) FROM qa_velocity_metrics WHERE product_slug='<slug>'
UNION ALL SELECT 'handoff', count(*) FROM qa_handoff_queue;
```

## Latest Readiness (should match strategist report)

```sql
SELECT composite_score, readiness_level, narrative
FROM qa_readiness_reports WHERE product_slug='<slug>'
ORDER BY created_at DESC LIMIT 1;
```

## Journey Confidence Distribution (should match strategist report)

```sql
SELECT classification, count(*)
FROM qa_confidence_scores WHERE product_slug='<slug>'
GROUP BY classification;
```

## Open Defects with their RCA

```sql
SELECT d.title, d.category, d.severity, r.root_cause, r.classified_by
FROM qa_known_defects d
LEFT JOIN qa_defect_rca r ON d.defect_id = r.defect_id
WHERE d.product_slug='<slug>' AND d.is_false_positive = false
ORDER BY d.first_seen_at DESC LIMIT 10;
```

## Pending Proposals (operator must review)

```sql
SELECT sink, summary, status, created_at
FROM qa_proposed_heuristics
WHERE status = 'pending_apply'
ORDER BY created_at DESC;
```
