-- SQL install file for temporal_rtree extension
-- Creates the C handler and registers the access method

-- Handler function (required by AM contract)
CREATE FUNCTION temporal_rtree_handler(internal)
RETURNS index_am_handler
AS 'MODULE_PATHNAME', 'temporal_rtree_handler'
LANGUAGE C STRICT;

-- Register the access method
CREATE ACCESS METHOD temporal_rtree TYPE INDEX HANDLER temporal_rtree_handler;

-- Operator family for temporal range indexing
CREATE OPERATOR FAMILY temporal_tsrange_ops USING temporal_rtree;

-- Operator class for tsrange (time only)
CREATE OPERATOR CLASS temporal_tsrange_ops
DEFAULT FOR TYPE tsrange USING temporal_rtree
FAMILY temporal_tsrange_ops AS
  OPERATOR 3 && (anyrange, anyrange),
  OPERATOR 7 @> (anyrange, anyrange),
  OPERATOR 8 <@ (anyrange, anyrange),
  OPERATOR 20 << (anyrange, anyrange),
  OPERATOR 21 >> (anyrange, anyrange),
  OPERATOR 22 &< (anyrange, anyrange),
  OPERATOR 23 &> (anyrange, anyrange);

COMMENT ON OPERATOR FAMILY temporal_tsrange_ops USING temporal_rtree
  IS 'Temporal R-tree access method family for tsrange';
COMMENT ON OPERATOR CLASS temporal_tsrange_ops USING temporal_rtree
  IS 'Temporal R-tree access method for tsrange (time only)';

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
