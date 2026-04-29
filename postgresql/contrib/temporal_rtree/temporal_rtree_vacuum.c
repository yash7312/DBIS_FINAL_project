#include "postgres.h"
#include "fmgr.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/itup.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/elog.h"
#include "utils/rel.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

static bool rtree_vacuum_page(Relation rel, BlockNumber blkno,
                              IndexBulkDeleteCallback callback,
                              void *callback_state,
                              IndexBulkDeleteResult *stats,
                              RTreeTemporalBox *page_box);

static void
rtree_add_tuple_copy(Page page, IndexTuple itup)
{
    if (PageAddItem(page, (Item) itup, IndexTupleSize(itup), InvalidOffsetNumber, false, false) == InvalidOffsetNumber)
        elog(ERROR, "failed to rebuild index page during vacuum");
}

static bool
rtree_vacuum_page(Relation rel, BlockNumber blkno,
                  IndexBulkDeleteCallback callback,
                  void *callback_state,
                  IndexBulkDeleteResult *stats,
                  RTreeTemporalBox *page_box)
{
    Buffer buf;
    Page page;
    RTreePageOpaqueData *opaque;
    IndexTuple tuples[MaxHeapTuplesPerPage];
    RTreeTemporalBox boxes[MaxHeapTuplesPerPage];
    int nitems = 0;
    OffsetNumber offset;
    OffsetNumber maxoff;
    bool leaf;
    bool page_empty = false;
    BlockNumber rightlink;
    uint16 flags;
    uint16 level;
    uint64 nsn;

    buf = ReadBufferExtended(rel, MAIN_FORKNUM, blkno, RBM_NORMAL, NULL);
    LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
    page = BufferGetPage(buf);
    opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
    leaf = (opaque->flags & TRTREE_PAGE_LEAF) != 0;
    rightlink = opaque->rightlink;
    flags = opaque->flags;
    level = opaque->level;
    nsn = opaque->nsn;

    maxoff = PageGetMaxOffsetNumber(page);

    if (leaf)
    {
        for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
        {
            ItemId itemid = PageGetItemId(page, offset);
            IndexTuple itup;
            RTreeTemporalBox box;

            if (!ItemIdIsUsed(itemid))
                continue;

            itup = (IndexTuple) PageGetItem(page, itemid);
            if (callback(&itup->t_tid, callback_state))
            {
                stats->tuples_removed += 1.0;
            }
            else
            {
                if (!rtree_index_tuple_box(rel, itup, &box))
                    continue;

                tuples[nitems] = CopyIndexTuple(itup);
                boxes[nitems] = box;
                stats->num_index_tuples += 1.0;
                nitems++;
            }
        }
    }
    else
    {
        for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
        {
            ItemId itemid = PageGetItemId(page, offset);
            IndexTuple itup;
            RTreeTemporalBox child_box;
            BlockNumber childblk;
            bool child_empty;
            ItemPointerData child_tid;

            if (!ItemIdIsUsed(itemid))
                continue;

            itup = (IndexTuple) PageGetItem(page, itemid);
            childblk = ItemPointerGetBlockNumber(&itup->t_tid);
            child_empty = rtree_vacuum_page(rel, childblk, callback, callback_state, stats, &child_box);
            if (child_empty)
            {
                continue;
            }

            ItemPointerSetBlockNumber(&child_tid, childblk);
            ItemPointerSetOffsetNumber(&child_tid, FirstOffsetNumber);
            tuples[nitems] = rtree_form_tuple(rel, &child_box, &child_tid);
            boxes[nitems] = child_box;
            stats->num_index_tuples += 1.0;
            nitems++;
        }
    }

    {
        RTreeTemporalBox aggregate;
        int i;

        MemSet(&aggregate, 0, sizeof(aggregate));
        aggregate.flags = TRTREE_FLAG_EMPTY;

        rtree_init_datapage(page, flags, level);
        opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
        opaque->rightlink = rightlink;
        opaque->nsn = nsn;

        for (i = 0; i < nitems; i++)
        {
            rtree_add_tuple_copy(page, tuples[i]);
            pfree(tuples[i]);
            aggregate = (aggregate.flags & TRTREE_FLAG_EMPTY) ? boxes[i] : tr_union(&aggregate, &boxes[i]);
        }

        if (nitems == 0)
            page_empty = true;
        else
            *page_box = aggregate;

        MarkBufferDirty(buf);
        if (RelationNeedsWAL(rel))
            rtree_wal_vacuum(rel, buf, NULL, 0);
    }

    LockBuffer(buf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(buf);
    if (page_empty)
        stats->pages_deleted += 1;
    return page_empty;
}

IndexBulkDeleteResult *
temporal_rtree_bulkdelete(IndexVacuumInfo *info,
                          IndexBulkDeleteResult *stats,
                          IndexBulkDeleteCallback callback,
                          void *callback_state)
{
    BlockNumber blkno;
    BlockNumber nblocks;
    RTreeMetaPageData meta;

    if (stats == NULL)
        stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

    stats->num_pages = RelationGetNumberOfBlocks(info->index);
    stats->estimated_count = false;
    stats->num_index_tuples = 0;
    stats->tuples_removed = 0;
    stats->pages_newly_deleted = 0;
    stats->pages_deleted = 0;
    stats->pages_free = 0;

    nblocks = RelationGetNumberOfBlocks(info->index);
    if (nblocks < 2)
        return stats;

    {
        Buffer metabuf;
        Page metapage;

        metabuf = ReadBufferExtended(info->index, MAIN_FORKNUM, 0, RBM_NORMAL, NULL);
        LockBuffer(metabuf, BUFFER_LOCK_SHARE);
        metapage = BufferGetPage(metabuf);
        meta = *(RTreeMetaPageData *) PageGetSpecialPointer(metapage);
        LockBuffer(metabuf, BUFFER_LOCK_UNLOCK);
        ReleaseBuffer(metabuf);
    }

    if (meta.magic != TRTREE_META_MAGIC)
        return stats;

    blkno = meta.root;
    if (BlockNumberIsValid(blkno))
    {
        RTreeTemporalBox root_box;
        (void) rtree_vacuum_page(info->index, blkno, callback, callback_state, stats, &root_box);
    }

    return stats;
}

IndexBulkDeleteResult *
temporal_rtree_vacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
    BlockNumber nblocks;

    if (stats == NULL)
        stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

    nblocks = RelationGetNumberOfBlocks(info->index);
    stats->num_pages = nblocks;
    stats->estimated_count = false;

    return stats;
}
