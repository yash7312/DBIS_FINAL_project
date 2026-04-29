#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/itup.h"
#include "access/relscan.h"
#include "access/tableam.h"
#include "catalog/index.h"
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

typedef struct RTreeBuildState
{
    Relation heapRel;
    IndexInfo *indexInfo;
    double indexTuples;
} RTreeBuildState;

static void rtree_build_callback(Relation index, ItemPointer tid, Datum *values,
                                 bool *isnull, bool tupleIsAlive, void *state);

static void
rtree_meta_and_root_init(Relation index)
{
    Buffer metabuf;
    Buffer rootbuf;
    Page metapage;
    Page rootpage;

    metabuf = ReadBufferExtended(index, MAIN_FORKNUM, P_NEW, RBM_ZERO_AND_LOCK, NULL);
    metapage = BufferGetPage(metabuf);

    rootbuf = ReadBufferExtended(index, MAIN_FORKNUM, P_NEW, RBM_ZERO_AND_LOCK, NULL);
    rootpage = BufferGetPage(rootbuf);

    START_CRIT_SECTION();
    rtree_init_metapage(metapage, BufferGetBlockNumber(rootbuf), 0);
    rtree_init_datapage(rootpage, TRTREE_PAGE_LEAF | TRTREE_PAGE_ROOT, 0);
    MarkBufferDirty(metabuf);
    MarkBufferDirty(rootbuf);
    END_CRIT_SECTION();

    UnlockReleaseBuffer(rootbuf);
    UnlockReleaseBuffer(metabuf);
}

IndexBuildResult *
temporal_rtree_build(Relation heapRelation, Relation indexRelation, IndexInfo *indexInfo)
{
    IndexBuildResult *result;
    RTreeBuildState state;

    rtree_meta_and_root_init(indexRelation);

    state.heapRel = heapRelation;
    state.indexInfo = indexInfo;
    state.indexTuples = 0;

    result = (IndexBuildResult *) palloc(sizeof(IndexBuildResult));
    result->heap_tuples = table_index_build_scan(heapRelation, indexRelation, indexInfo, true, true,
                                                 rtree_build_callback, &state, NULL);
    result->index_tuples = state.indexTuples;

    return result;
}

void
temporal_rtree_buildempty(Relation indexRelation)
{
    rtree_meta_and_root_init(indexRelation);
}

static void
rtree_build_callback(Relation index, ItemPointer tid, Datum *values,
                     bool *isnull, bool tupleIsAlive, void *state)
{
    RTreeBuildState *buildstate = (RTreeBuildState *) state;

    (void) values;
    (void) isnull;
    (void) tupleIsAlive;

    if (temporal_rtree_insert(index,
                              values,
                              isnull,
                              tid,
                              buildstate->heapRel,
                              UNIQUE_CHECK_NO,
                              false,
                              buildstate->indexInfo))
        buildstate->indexTuples += 1;
}