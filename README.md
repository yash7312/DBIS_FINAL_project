# DBIS_Assignment
Temporal Indexing 	
	Create a temporal index on data with an extra valid-time dimension.  Make sure to efficiently index tuples where the end time is infinity, and to support temporal queries where the time can be a range or a point.  (See 7th ed of DB Concepts, Chapter 14/24 for details).  You can use the existing B+/R-tree implementation in PostgreSQL underneath.

    Implement the temporal + other attribute index  described in  advanced indexing chapter slides online.  Spatial is optional, it can be an ordinary ordered attribute such as string or numeric.
    
Our project should now be framed as:

Use PostgreSQL’s existing range + GiST framework for temporal indexing, then analyze or improve handling of open-ended intervals and temporal+attribute workloads.

Most likely file to modify
    rangetypes_gist.c

This is where our actual project contribution should go if we make source-level changes.

Possibly modify later
    rangetypes_selfuncs.c

Only if experiments show the planner is not choosing the temporal index properly.

