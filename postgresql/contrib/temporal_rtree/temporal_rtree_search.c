#include "postgres.h"
#include "fmgr.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/itup.h"
#include "access/sdir.h"
#include "storage/bufmgr.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

IndexScanDesc
temporal_rtree_beginscan(Relation r, int nkeys, int norderbys)
{
    IndexScanDesc scan = RelationGetIndexScan(r, nkeys, norderbys);
    RTreeScanOpaque opaque;

    opaque = (RTreeScanOpaque) palloc(sizeof(RTreeScanOpaqueData));
    opaque->cur_buf = InvalidBuffer;
    opaque->cur_offset = InvalidOffsetNumber;
    opaque->level = 0;
    opaque->cur_blkno = InvalidBlockNumber;
    opaque->items = (RTreeScanItemData *) palloc(sizeof(RTreeScanItemData) * 16);
    opaque->nitems = 0;
    opaque->items_size = 16;
    opaque->next_item = 0;
    opaque->first_call = true;
    opaque->direction = ForwardScanDirection;

    scan->opaque = opaque;

    elog(DEBUG1, "temporal_rtree: beginscan initialized with buffer pin management");
    return scan;
}

bool
temporal_rtree_gettuple(IndexScanDesc scan, ScanDirection dir)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return false;

    /* Release previous pin if held (correct concurrent behavior) */
    if (BufferIsValid(opaque->cur_buf))
    {
        RTREE_UNLOCK(opaque->cur_buf);
        ReleaseBuffer(opaque->cur_buf);
        opaque->cur_buf = InvalidBuffer;
    }

    /* For this scaffold: no more tuples to return */
    scan->xs_recheck = false;
    return false;
}

void
temporal_rtree_rescan(IndexScanDesc scan, ScanKey key, int nkeys, ScanKey orderbys, int norderbys)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return;

    /* Reset traversal state */
    opaque->first_call = true;
    opaque->next_item = 0;
    opaque->nitems = 0;

    /* Release any held buffer */
    if (BufferIsValid(opaque->cur_buf))
    {
        RTREE_UNLOCK(opaque->cur_buf);
        ReleaseBuffer(opaque->cur_buf);
        opaque->cur_buf = InvalidBuffer;
    }
}

void
temporal_rtree_endscan(IndexScanDesc scan)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return;

    /* Release buffer and free scan state */
    if (BufferIsValid(opaque->cur_buf))
    {
        RTREE_UNLOCK(opaque->cur_buf);
        ReleaseBuffer(opaque->cur_buf);
    }

    if (opaque->items != NULL)
        pfree(opaque->items);
    pfree(opaque);
    scan->opaque = NULL;
}
