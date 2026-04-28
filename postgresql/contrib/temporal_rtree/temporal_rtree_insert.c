#include "postgres.h"
#include "fmgr.h"
#include "access/relscan.h"
#include "access/itup.h"
#include "access/reloptions.h"
#include "nodes/execnodes.h"
#include "utils/elog.h"
#include "utils/rel.h"
#include "temporal_rtree.h"

/* Public insert API matching other AMs (signature mirrors btree) */
bool
temporal_rtree_insert(Relation rel, Datum *values, bool *isnull,
                      ItemPointer ht_ctid, Relation heapRel,
                      IndexUniqueCheck checkUnique,
                      bool indexUnchanged,
                      IndexInfo *indexInfo)
{
    /* For this prototype, we form a simple index tuple and leave it to the
     * storage-level insertion to be added later. Here we perform key
     * normalization and compute the in-memory MBR for demonstration.
     */
    IndexTuple itup = index_form_tuple(RelationGetDescr(rel), values, isnull);
    itup->t_tid = *ht_ctid;

    /* Example: normalize temporal key if present in first attribute */
    /* In real implementation we'd extract tsrange and set flags/convert */
    elog(DEBUG1, "temporal_rtree_insert: prepared tuple for rel %s",
         RelationGetRelationName(rel));

    /* Placeholder: do not actually write pages in this scaffold */
    pfree(itup);
    return true;
}
