\if :{?log_dir}
\else
\set log_dir /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/experiment_logs
\endif
\! mkdir -p /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/experiment_logs

CREATE EXTENSION IF NOT EXISTS cube;
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/postgresql/contrib/temporalbox/temporalbox--1.0.sql

\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/indexes.sql

CREATE EXTENSION IF NOT EXISTS btree_gist;

\set current_config 'no_index'
CALL create_no_index();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_no_index.txt
\qecho 'Experiment: no_index'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'btree'
CALL create_btree_baseline();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_btree.txt
\qecho 'Experiment: btree'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'gist_period'
CALL create_gist_period();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_gist_period.txt
\qecho 'Experiment: gist_period'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'gist_attr_period'
CALL create_gist_attr_period();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_gist_attr_period.txt
\qecho 'Experiment: gist_attr_period'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'brin'
CALL create_brin_lower();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_brin.txt
\qecho 'Experiment: brin'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'hybrid_current_history'
CALL create_hybrid_current_history();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_hybrid_current_history.txt
\qecho 'Experiment: hybrid_current_history'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

\set current_config 'hst_gist'
CALL create_hst_gist();
VACUUM ANALYZE temporal_data;
\o :log_dir/results_hst_gist.txt
\qecho 'Experiment: hst_gist'
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/queries.sql
\i /home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/data_generation/metrics_snapshot.sql
\o

