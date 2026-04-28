-- Temporal Data Schema for R-tree Benchmarking
-- Represents records with valid_period (temporal validity) and attr (attribute for 2D indexing)

-- Drop if exists (for development)
DROP TABLE IF EXISTS temporal_data CASCADE;
DROP SEQUENCE IF EXISTS temporal_data_id_seq CASCADE;

-- Create table
CREATE TABLE temporal_data (
    id           bigserial PRIMARY KEY,
    attr         integer NOT NULL CHECK (attr >= 1 AND attr <= 100),
    valid_period tsrange NOT NULL,
    payload      text,
    created_at   timestamp DEFAULT now()
);

-- Table statistics & partitioning comments
COMMENT ON TABLE temporal_data IS
    'Benchmarking table for temporal R-tree AM. Rows represent entities with '
    'temporal validity periods (current vs. history) and attributes for 2D queries.';

COMMENT ON COLUMN temporal_data.id IS
    'Unique record identifier (surrogate key).';

COMMENT ON COLUMN temporal_data.attr IS
    'Attribute value [1,100] for 2D index testing (attr × time).';

COMMENT ON COLUMN temporal_data.valid_period IS
    'Time range [lower, upper) representing row validity. Upper=NULL = currently active (open-ended).';

COMMENT ON COLUMN temporal_data.payload IS
    'Dummy data payload for realistic I/O.';
