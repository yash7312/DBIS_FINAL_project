\qecho 'Q1 — Point query (mid selectivity)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

\qecho 'Q2 — Point query (low selectivity)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

\qecho 'Q3 — Short overlap (tight interval)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

\qecho 'Q4 — Medium overlap'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

\qecho 'Q5 — Large overlap (stress test)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

\qecho 'Q6 — Containment query'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

\qecho 'Q7 — Contained-by query'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');

-- \qecho 'Q8 — Open-ended rows'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE upper_inf(valid_period);

-- \qecho 'Q9 — Valid now query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE valid_period @> timestamp '2024-01-01';

-- \qecho 'Q10 — Attribute + point query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE attr = 10
--   AND valid_period @> timestamp '2023-06-01';

-- \qecho 'Q11 — Attribute + overlap query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE attr = 10
--   AND valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- \qecho 'Q12 — Attribute + current rows'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE attr = 10
--   AND upper_inf(valid_period);

-- \qecho 'Q13 — Fetch actual rows (point)'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT id, attr, valid_period
-- FROM temporal_data
-- WHERE valid_period @> timestamp '2023-06-01'
-- LIMIT 100;

-- \qecho 'Q14 — Fetch actual rows (attr + overlap)'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT id, attr, valid_period
-- FROM temporal_data
-- WHERE attr = 10
--   AND valid_period && tsrange('2023-01-01','2023-06-01','[)')
-- LIMIT 100;

-- \qecho 'Q15 — Hybrid current rows (current index)'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE upper_inf(valid_period)
--   AND attr = 10
--   AND lower(valid_period) <= timestamp '2024-01-01';

\qecho 'Query A — Attribute + point containment (indexed expression)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period) @> temporalbox_point(10, timestamp '2023-06-01');

\qecho 'Query B — Attribute + interval overlap (indexed expression)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period) && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

\qecho 'Query C — Fetch rows for point containment'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, attr, valid_period
FROM temporal_data
WHERE temporalbox(attr, valid_period) @> temporalbox_point(10, timestamp '2023-06-01')
LIMIT 100;

\qecho 'Query D — Current rows for one attribute'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE upper_inf(valid_period)
	AND attr = 10
	AND lower(valid_period) <= timestamp '2024-01-01';

\qecho 'Query E — Current rows without attribute'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE upper_inf(valid_period)
	AND lower(valid_period) <= timestamp '2024-01-01';

\qecho 'Query F — Fetch current rows'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, attr, valid_period
FROM temporal_data
WHERE upper_inf(valid_period)
	AND attr = 10
	AND lower(valid_period) <= timestamp '2024-01-01'
LIMIT 100;

\qecho 'Query G — True hybrid UNION ALL query'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM (
		SELECT id
		FROM temporal_data
		WHERE NOT upper_inf(valid_period)
			AND temporalbox(attr, valid_period) @> temporalbox_point(10, timestamp '2023-06-01')

		UNION ALL

		SELECT id
		FROM temporal_data
		WHERE upper_inf(valid_period)
			AND attr = 10
			AND lower(valid_period) <= timestamp '2023-06-01'
) s;

-- \qecho 'Q16 — Hybrid historical overlap'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE NOT upper_inf(valid_period)
--   AND attr = 10
--   AND valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- \qecho 'Q17 — Hybrid combined union query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM (
--     SELECT id
--     FROM temporal_data
--     WHERE upper_inf(valid_period)
--       AND attr = 10
--       AND lower(valid_period) <= timestamp '2024-01-01'
--     UNION ALL
--     SELECT id
--     FROM temporal_data
--     WHERE NOT upper_inf(valid_period)
--       AND attr = 10
--       AND valid_period @> timestamp '2024-01-01'
-- ) hybrid_query;

-- \qecho 'Q18 — HST-GiST history point query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE NOT upper_inf(valid_period)
--   AND temporalbox(attr, valid_period) @> temporalbox_point(10, timestamp '2023-06-01');

-- \qecho 'Q19 — HST-GiST history overlap query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE NOT upper_inf(valid_period)
--   AND temporalbox(attr, valid_period) && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

-- \qecho 'Q20 — HST-GiST current-row query'
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*)
-- FROM temporal_data
-- WHERE upper_inf(valid_period)
--   AND attr = 10
--   AND lower(valid_period) <= timestamp '2024-01-01';

