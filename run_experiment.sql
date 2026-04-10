\if :{?log_dir}
\else
\set log_dir /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/experiment_logs
\endif
\! mkdir -p /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/experiment_logs

\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/indexes.sql

CREATE EXTENSION IF NOT EXISTS btree_gist;

CALL create_no_index();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_no_index.txt
\qecho 'Experiment: no_index'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\o

CALL create_btree_baseline();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_btree.txt
\qecho 'Experiment: btree'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\o

CALL create_gist_period();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_gist_period.txt
\qecho 'Experiment: gist_period'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\o

CALL create_gist_attr_period();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_gist_attr_period.txt
\qecho 'Experiment: gist_attr_period'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\o

CALL create_brin_lower();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_brin.txt
\qecho 'Experiment: brin'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\o

