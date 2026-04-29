#include "postgres.h"
#include "fmgr.h"
#include "access/genam.h"
#include "access/generic_xlog.h"
#include "access/itup.h"
#include "access/relscan.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/elog.h"
#include "utils/rel.h"
#include "commands/vacuum.h"
#include "miscadmin.h"
#include <string.h>
#include "storage/lmgr.h"
#include "access/xlog.h"
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

    vacuum_delay_point();

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
            if (callback != NULL && callback(&itup->t_tid, callback_state))
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
                continue;

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
        {
            page_empty = true;
            stats->pages_deleted += 1;
            stats->pages_newly_deleted += 1;
        }
        else
            *page_box = aggregate;

        MarkBufferDirty(buf);
        if (RelationNeedsWAL(rel))
            rtree_wal_vacuum(rel, buf, NULL, 0);
    }

    LockBuffer(buf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(buf);
    return page_empty;
}

bool
rtree_vacuum_shrink_root(Relation rel, BlockNumber rootblk,
                         uint16 root_level, IndexBulkDeleteResult *stats)
{
    Buffer metabuf;
    Buffer rootbuf;
    Page metapage;
    Page rootpage;
    RTreeMetaPageData *meta;
    RTreePageOpaqueData *rootopaque;
    BlockNumber childblk;
    bool changed = false;

    if (!BlockNumberIsValid(rootblk))
        return false;

    metabuf = ReadBufferExtended(rel, MAIN_FORKNUM, 0, RBM_NORMAL, NULL);
    LockBuffer(metabuf, BUFFER_LOCK_EXCLUSIVE);
    metapage = BufferGetPage(metabuf);
    meta = (RTreeMetaPageData *) PageGetSpecialPointer(metapage);
    if (meta->magic != TRTREE_META_MAGIC || meta->root != rootblk)
    {
        LockBuffer(metabuf, BUFFER_LOCK_UNLOCK);
        ReleaseBuffer(metabuf);
        return false;
    }

    rootbuf = ReadBufferExtended(rel, MAIN_FORKNUM, rootblk, RBM_NORMAL, NULL);
    LockBuffer(rootbuf, BUFFER_LOCK_EXCLUSIVE);
    rootpage = BufferGetPage(rootbuf);
    rootopaque = (RTreePageOpaqueData *) PageGetSpecialPointer(rootpage);

    if ((rootopaque->flags & TRTREE_PAGE_LEAF) != 0 || root_level == 0)
    {
        LockBuffer(rootbuf, BUFFER_LOCK_UNLOCK);
        ReleaseBuffer(rootbuf);
        LockBuffer(metabuf, BUFFER_LOCK_UNLOCK);
        ReleaseBuffer(metabuf);
        return false;
    }

    if (PageGetMaxOffsetNumber(rootpage) == 0)
    {
        rtree_init_datapage(rootpage, TRTREE_PAGE_LEAF | TRTREE_PAGE_ROOT, 0);
        meta->root_level = 0;
        changed = true;
    }
    else if (PageGetMaxOffsetNumber(rootpage) == 1)
    {
        IndexTuple childitup;
        Buffer childbuf;
        Page childpage;
        RTreePageOpaqueData *childopaque;
        GenericXLogState *state = NULL;

        childitup = (IndexTuple) PageGetItem(rootpage, PageGetItemId(rootpage, FirstOffsetNumber));
        childblk = ItemPointerGetBlockNumber(&childitup->t_tid);
        childbuf = ReadBufferExtended(rel, MAIN_FORKNUM, childblk, RBM_NORMAL, NULL);
        LockBuffer(childbuf, BUFFER_LOCK_SHARE);
        childpage = BufferGetPage(childbuf);
        childopaque = (RTreePageOpaqueData *) PageGetSpecialPointer(childpage);

        START_CRIT_SECTION();
        memcpy(rootpage, childpage, BLCKSZ);
        rootopaque = (RTreePageOpaqueData *) PageGetSpecialPointer(rootpage);
        rootopaque->flags |= TRTREE_PAGE_ROOT;
        rootopaque->level = childopaque->level;
        meta->root_level = childopaque->level;
        MarkBufferDirty(rootbuf);
        MarkBufferDirty(metabuf);
        if (RelationNeedsWAL(rel))
        {
            state = GenericXLogStart(rel);
            GenericXLogRegisterBuffer(state, rootbuf, GENERIC_XLOG_FULL_IMAGE);
            GenericXLogRegisterBuffer(state, metabuf, GENERIC_XLOG_FULL_IMAGE);
            GenericXLogFinish(state);
        }
        END_CRIT_SECTION();

        UnlockReleaseBuffer(childbuf);
        changed = true;
    }

    LockBuffer(rootbuf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(rootbuf);
    LockBuffer(metabuf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(metabuf);
    return changed;
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
        (void) rtree_vacuum_shrink_root(info->index, blkno, meta.root_level, stats);
    }

    return stats;
}

IndexBulkDeleteResult *
temporal_rtree_vacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
    if (info->analyze_only)
        return stats;

    if (stats == NULL)
    {
        stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
        (void) temporal_rtree_bulkdelete(info, stats, NULL, NULL);
        stats->estimated_count = true;
    }

    if (!info->estimated_count)
    {
        if (stats->num_index_tuples > info->num_heap_tuples)
            stats->num_index_tuples = info->num_heap_tuples;
    }

    stats->num_pages = RelationGetNumberOfBlocks(info->index);
    return stats;
}
