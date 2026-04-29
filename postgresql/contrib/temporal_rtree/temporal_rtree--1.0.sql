-- SQL install file for temporal_rtree extension
-- Creates the C handler and registers the access method

-- Handler function (required by AM contract)
CREATE FUNCTION temporal_rtree_handler(internal)
RETURNS index_am_handler
AS 'MODULE_PATHNAME', 'temporal_rtree_handler'
LANGUAGE C STRICT;

-- Register the access method
CREATE ACCESS METHOD temporal_rtree TYPE INDEX HANDLER temporal_rtree_handler;

CREATE OPERATOR FAMILY temporal_cube_ops USING temporal_rtree;

CREATE OPERATOR CLASS temporal_cube_ops
DEFAULT FOR TYPE cube USING temporal_rtree
FAMILY temporal_cube_ops AS
  OPERATOR 1 && (cube, cube),
  OPERATOR 2 @> (cube, cube),
  OPERATOR 3 <@ (cube, cube);

COMMENT ON OPERATOR FAMILY temporal_cube_ops USING temporal_rtree
  IS 'Temporal R-tree access method family for cube';
COMMENT ON OPERATOR CLASS temporal_cube_ops USING temporal_rtree
  IS 'Temporal R-tree access method for temporal cube boxes';

-- Hook statistics functions (C1 Testing)

CREATE FUNCTION temporal_rtree_hook_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'temporal_rtree_hook_reset'
LANGUAGE C STRICT;

COMMENT ON FUNCTION temporal_rtree_hook_reset()
  IS 'Reset all temporal_rtree hook hit counters to zero';

CREATE FUNCTION temporal_rtree_hook_stats()
RETURNS TABLE (
  planner_hits bigint,
  planner_rtree_eligible_hits bigint,
  executor_dml_hits bigint,
  executor_target_with_rtree_hits bigint
)
AS 'MODULE_PATHNAME', 'temporal_rtree_hook_stats'
LANGUAGE C STRICT;

COMMENT ON FUNCTION temporal_rtree_hook_stats()
  IS 'Return current hook statistics counters';
