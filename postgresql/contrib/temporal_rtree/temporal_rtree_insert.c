#include "postgres.h"
#include "fmgr.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/itup.h"
#include "access/reloptions.h"
#include "catalog/index.h"
#include "miscadmin.h"
#include "storage/bufpage.h"
#include "storage/bufmgr.h"
#include "nodes/execnodes.h"
#include "utils/elog.h"
#include "utils/rel.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

#include <float.h>

/* Normalized penalty helper (forward declare or include from split.c) */
extern double tr_penalty_normalized(const RTreeTemporalBox *child, const RTreeTemporalBox *newb);

extern void temporal_rtree_buildempty(Relation indexRelation);

typedef struct RTreeInsertResult
{
    bool split;
    BlockNumber right_blkno;
    RTreeTemporalBox left_box;
    RTreeTemporalBox right_box;
} RTreeInsertResult;

static RTreeInsertResult rtree_insert_page(Relation rel, BlockNumber blkno,
                                           uint16 level, IndexTuple itup,
                                           const RTreeTemporalBox *box);
static BlockNumber choose_subtree_insert(Relation rel, Page page, const RTreeTemporalBox *newbox);

static BlockNumber
choose_subtree_insert(Relation rel, Page page, const RTreeTemporalBox *newbox)
{
    OffsetNumber offset;
    OffsetNumber maxoff = PageGetMaxOffsetNumber(page);
    BlockNumber best_child = InvalidBlockNumber;
    double best_penalty = DBL_MAX;
    bool new_is_current = (newbox->flags & TRTREE_FLAG_UPPER_INF) != 0;

    for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
    {
        ItemId itemid = PageGetItemId(page, offset);
        IndexTuple itup;
        RTreeTemporalBox child_box;
        double penalty;
        BlockNumber child_blkno;
        bool child_is_current;

        if (!ItemIdIsUsed(itemid))
            continue;

        itup = (IndexTuple) PageGetItem(page, itemid);
        child_blkno = ItemPointerGetBlockNumber(&itup->t_tid);

        if (!rtree_index_tuple_box(rel, itup, &child_box))
            continue;

        child_is_current = (child_box.flags & TRTREE_FLAG_UPPER_INF) != 0;

        /* Use normalized penalty */
        penalty = tr_penalty_normalized(&child_box, newbox);

        /* Prefer inserting into same "side" (current vs history) */
        if (child_is_current == new_is_current)
            penalty *= 0.8; /* reward same-family */
        else
            penalty *= 1.2; /* penalize mixing families */

        if (penalty < best_penalty)
        {
            best_penalty = penalty;
            best_child = child_blkno;
        }
    }

    /* Fallback: pick first child if nothing chosen */
    if (best_child == InvalidBlockNumber && maxoff >= FirstOffsetNumber)
    {
        ItemId itemid = PageGetItemId(page, FirstOffsetNumber);
        IndexTuple itup = (IndexTuple) PageGetItem(page, itemid);
        best_child = ItemPointerGetBlockNumber(&itup->t_tid);
    }

    return best_child;
}
static RTreeInsertResult rtree_insert_leaf(Relation rel, Buffer buf,
                                           IndexTuple itup,
                                           const RTreeTemporalBox *box);
static RTreeTemporalBox rtree_page_tuple_box(Relation rel, Page page,
                                            OffsetNumber offnum);
static void rtree_replace_tuple(Page page, OffsetNumber offnum,
                                IndexTuple itup);
static void rtree_page_collect(Relation rel, Page page, IndexTuple *items,
                               RTreeTemporalBox *boxes, int *nitems);
static RTreeInsertResult rtree_split_page(Relation rel, Buffer buf,
                                          IndexTuple newitup,
                                          const RTreeTemporalBox *newbox,
                                          uint16 level,
                                          uint16 flags);
static void rtree_root_promote(Relation rel, BlockNumber leftblk,
                               const RTreeInsertResult *split,
                               uint16 old_level, BlockNumber *new_rootblk);


static RTreeTemporalBox
rtree_page_tuple_box(Relation rel, Page page, OffsetNumber offnum)
{
    ItemId itemid = PageGetItemId(page, offnum);
    IndexTuple itup = (IndexTuple) PageGetItem(page, itemid);
    RTreeTemporalBox box;

    if (!rtree_index_tuple_box(rel, itup, &box))
        MemSet(&box, 0, sizeof(box));
    return box;
}

static void
rtree_replace_tuple(Page page, OffsetNumber offnum, IndexTuple itup)
{
    PageIndexTupleDelete(page, offnum);
    if (PageAddItem(page, (Item) itup, IndexTupleSize(itup), offnum, false, false) == InvalidOffsetNumber)
        elog(ERROR, "failed to replace index tuple on page");
}

static void
rtree_page_collect(Relation rel, Page page, IndexTuple *items,
                   RTreeTemporalBox *boxes, int *nitems)
{
    OffsetNumber offset;
    OffsetNumber maxoff = PageGetMaxOffsetNumber(page);
    int count = 0;

    for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
    {
        ItemId itemid = PageGetItemId(page, offset);
        IndexTuple itup;

        if (!ItemIdIsUsed(itemid))
            continue;

        itup = (IndexTuple) PageGetItem(page, itemid);
        items[count] = CopyIndexTuple(itup);
        boxes[count] = rtree_page_tuple_box(rel, page, offset);
        count++;
    }

    *nitems = count;
}

static RTreeInsertResult
rtree_split_page(Relation rel, Buffer buf, IndexTuple newitup,
                 const RTreeTemporalBox *newbox, uint16 level, uint16 flags)
{
    Page page = BufferGetPage(buf);
    RTreePageOpaqueData *opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
    IndexTuple items[MaxHeapTuplesPerPage + 1];
    RTreeTemporalBox boxes[MaxHeapTuplesPerPage + 1];
    RTreeTemporalBox split_boxes[MaxHeapTuplesPerPage + 1];
    int left_idxs[MaxHeapTuplesPerPage + 1];
    int right_idxs[MaxHeapTuplesPerPage + 1];
    int nitems;
    int nleft;
    int nright;
    int i;
    Buffer rightbuf;
    Page rightpage;
    RTreePageOpaqueData *rightopaque;
    RTreeInsertResult result;
    BlockNumber old_rightlink;
    bool was_root;
    uint16 child_flags;

    old_rightlink = opaque->rightlink;
    was_root = (opaque->flags & TRTREE_PAGE_ROOT) != 0;
    child_flags = flags & ~TRTREE_PAGE_ROOT;

    rtree_page_collect(rel, page, items, boxes, &nitems);
    items[nitems] = newitup;
    boxes[nitems] = *newbox;
    nitems++;

    for (i = 0; i < nitems; i++)
        split_boxes[i] = boxes[i];

    tr_picksplit(split_boxes, nitems, left_idxs, &nleft, right_idxs, &nright);

    rightbuf = ReadBufferExtended(rel, MAIN_FORKNUM, P_NEW, RBM_ZERO_AND_LOCK, NULL);
    rightpage = BufferGetPage(rightbuf);

    rtree_init_datapage(page, child_flags, level);
    rtree_init_datapage(rightpage, child_flags, level);

    opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
    rightopaque = (RTreePageOpaqueData *) PageGetSpecialPointer(rightpage);
    rightopaque->rightlink = old_rightlink;
    opaque->rightlink = BufferGetBlockNumber(rightbuf);
    if (was_root)
        opaque->flags &= ~TRTREE_PAGE_ROOT;

    for (i = 0; i < nleft; i++)
    {
        IndexTuple copy = items[left_idxs[i]];
        PageAddItem(page, (Item) copy, IndexTupleSize(copy), InvalidOffsetNumber, false, false);
    }

    for (i = 0; i < nright; i++)
    {
        IndexTuple copy = items[right_idxs[i]];
        PageAddItem(rightpage, (Item) copy, IndexTupleSize(copy), InvalidOffsetNumber, false, false);
    }

    MarkBufferDirty(buf);
    MarkBufferDirty(rightbuf);
    if (RelationNeedsWAL(rel))
        rtree_wal_split(rel, buf, rightbuf, BufferGetBlockNumber(rightbuf));

    START_CRIT_SECTION();
    END_CRIT_SECTION();

    result.split = true;
    result.right_blkno = BufferGetBlockNumber(rightbuf);
    result.left_box = rtree_page_mbr(rel, page, level == 0);
    result.right_box = rtree_page_mbr(rel, rightpage, level == 0);

    UnlockReleaseBuffer(rightbuf);
    return result;
}

static RTreeInsertResult
rtree_insert_leaf(Relation rel, Buffer buf, IndexTuple itup,
                  const RTreeTemporalBox *box)
{
    Page page = BufferGetPage(buf);
    RTreePageOpaqueData *opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
    RTreeInsertResult result;

    if (PageGetFreeSpace(page) >= MAXALIGN(IndexTupleSize(itup)) + sizeof(ItemIdData))
    {
        OffsetNumber offnum = PageAddItem(page, (Item) itup, IndexTupleSize(itup), InvalidOffsetNumber, false, false);

        if (offnum == InvalidOffsetNumber)
            return rtree_split_page(rel, buf, itup, box, opaque->level, opaque->flags);

        MarkBufferDirty(buf);
        if (RelationNeedsWAL(rel))
            rtree_wal_insert(rel, buf, offnum, (RTreeTemporalBox *) box, &itup->t_tid);

        result.split = false;
        result.left_box = rtree_page_mbr(rel, page, true);
        return result;
    }

    return rtree_split_page(rel, buf, itup, box, opaque->level, opaque->flags);
}

static RTreeInsertResult
rtree_insert_page(Relation rel, BlockNumber blkno, uint16 level, IndexTuple itup,
                  const RTreeTemporalBox *box)
{
    Buffer buf;
    Page page;
    RTreePageOpaqueData *opaque;
    RTreeInsertResult result;

    buf = ReadBufferExtended(rel, MAIN_FORKNUM, blkno, RBM_NORMAL, NULL);
    LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
    page = BufferGetPage(buf);
    opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);

    if (level == 0 || (opaque->flags & TRTREE_PAGE_LEAF))
    {
        result = rtree_insert_leaf(rel, buf, itup, box);
        UnlockReleaseBuffer(buf);
        return result;
    }

    {
        OffsetNumber offset;
        OffsetNumber maxoff = PageGetMaxOffsetNumber(page);
        OffsetNumber bestoff = InvalidOffsetNumber;
        BlockNumber childblk = InvalidBlockNumber;
        RTreeTemporalBox bestbox;

        /* Choose child using normalized penalty and temporal-side awareness */
        childblk = choose_subtree_insert(rel, page, box);

        if (!BlockNumberIsValid(childblk))
        {
            UnlockReleaseBuffer(buf);
            ereport(ERROR, (errmsg("temporal_rtree: internal page without downlinks")));
        }

        /* Find the offset for the selected child block */
        for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
        {
            ItemId itemid = PageGetItemId(page, offset);
            IndexTuple childitup;

            if (!ItemIdIsUsed(itemid))
                continue;

            childitup = (IndexTuple) PageGetItem(page, itemid);
            if (ItemPointerGetBlockNumber(&childitup->t_tid) == childblk)
            {
                bestoff = offset;
                rtree_index_tuple_box(rel, childitup, &bestbox);
                break;
            }
        }

        if (bestoff == InvalidOffsetNumber)
        {
            UnlockReleaseBuffer(buf);
            ereport(ERROR, (errmsg("temporal_rtree: could not locate chosen child on page")));
        }

        {
            RTreeInsertResult childres;
            ItemId itemid = PageGetItemId(page, bestoff);
            IndexTuple childitup = (IndexTuple) PageGetItem(page, itemid);
            IndexTuple updated;

            childres = rtree_insert_page(rel,
                                         childblk,
                                         level - 1,
                                         itup,
                                         box);

            updated = rtree_form_tuple(rel,
                                       childres.split ? &childres.left_box : &childres.left_box,
                                       &childitup->t_tid);
            rtree_replace_tuple(page, bestoff, updated);
            pfree(updated);

            if (childres.split)
            {
                ItemPointerData right_tid;
                IndexTuple righttuple;

                ItemPointerSetBlockNumber(&right_tid, childres.right_blkno);
                ItemPointerSetOffsetNumber(&right_tid, FirstOffsetNumber);
                righttuple = rtree_form_tuple(rel, &childres.right_box, &right_tid);
                if (PageGetFreeSpace(page) < MAXALIGN(IndexTupleSize(righttuple)) + sizeof(ItemIdData))
                {
                    result = rtree_split_page(rel, buf, righttuple, &childres.right_box, level, opaque->flags);
                    pfree(righttuple);
                    UnlockReleaseBuffer(buf);
                    return result;
                }

                PageAddItem(page, (Item) righttuple, IndexTupleSize(righttuple), InvalidOffsetNumber, false, false);
                pfree(righttuple);
            }

            MarkBufferDirty(buf);
            if (RelationNeedsWAL(rel))
                rtree_wal_insert(rel, buf, bestoff, &bestbox, &childitup->t_tid);

            result.split = false;
            result.left_box = rtree_page_mbr(rel, page, false);
            UnlockReleaseBuffer(buf);
            return result;
        }
    }
}

static void
rtree_root_promote(Relation rel, BlockNumber leftblk, const RTreeInsertResult *split,
                  uint16 old_level, BlockNumber *new_rootblk)
{
    Buffer leftbuf;
    Buffer rootbuf;
    Page rootpage;
    RTreePageOpaqueData *leftopaque;
    IndexTuple lefttuple;
    IndexTuple righttuple;
    ItemPointerData left_tid;
    ItemPointerData right_tid;

    leftbuf = ReadBufferExtended(rel, MAIN_FORKNUM, leftblk, RBM_NORMAL, NULL);
    LockBuffer(leftbuf, BUFFER_LOCK_EXCLUSIVE);
    rootbuf = ReadBufferExtended(rel, MAIN_FORKNUM, P_NEW, RBM_ZERO_AND_LOCK, NULL);
    rootpage = BufferGetPage(rootbuf);

    ItemPointerSetBlockNumber(&left_tid, BufferGetBlockNumber(leftbuf));
    ItemPointerSetOffsetNumber(&left_tid, FirstOffsetNumber);
    ItemPointerSetBlockNumber(&right_tid, split->right_blkno);
    ItemPointerSetOffsetNumber(&right_tid, FirstOffsetNumber);

    lefttuple = rtree_form_tuple(rel, &split->left_box, &left_tid);
    righttuple = rtree_form_tuple(rel, &split->right_box, &right_tid);

    START_CRIT_SECTION();
    rtree_init_datapage(rootpage, TRTREE_PAGE_ROOT, old_level + 1);
    PageAddItem(rootpage, (Item) lefttuple, IndexTupleSize(lefttuple), InvalidOffsetNumber, false, false);
    PageAddItem(rootpage, (Item) righttuple, IndexTupleSize(righttuple), InvalidOffsetNumber, false, false);
    MarkBufferDirty(rootbuf);
    END_CRIT_SECTION();

    leftopaque = (RTreePageOpaqueData *) PageGetSpecialPointer(BufferGetPage(leftbuf));
    leftopaque->flags &= ~TRTREE_PAGE_ROOT;
    MarkBufferDirty(leftbuf);

    *new_rootblk = BufferGetBlockNumber(rootbuf);
    UnlockReleaseBuffer(rootbuf);
    UnlockReleaseBuffer(leftbuf);
    pfree(lefttuple);
    pfree(righttuple);
}

/* Public insert API matching other AMs (signature mirrors btree) */
bool
temporal_rtree_insert(Relation rel, Datum *values, bool *isnull,
                      ItemPointer ht_ctid, Relation heapRel,
                      IndexUniqueCheck checkUnique,
                      bool indexUnchanged,
                      IndexInfo *indexInfo)
{
    Buffer metabuf;
    Page metapage;
    RTreeMetaPageData *meta;
    IndexTuple itup;
    RTreeTemporalBox box;
    RTreeInsertResult result;
    BlockNumber rootblk;
    uint16 rootlevel;

    (void) heapRel;
    (void) checkUnique;
    (void) indexUnchanged;
    (void) indexInfo;

    if (RelationGetNumberOfBlocks(rel) < 2)
        temporal_rtree_buildempty(rel);

    itup = index_form_tuple(RelationGetDescr(rel), values, isnull);
    itup->t_tid = *ht_ctid;

    if (!rtree_index_tuple_box(rel, itup, &box))
    {
        pfree(itup);
        return true;
    }

    metabuf = ReadBufferExtended(rel, MAIN_FORKNUM, 0, RBM_NORMAL, NULL);
    LockBuffer(metabuf, BUFFER_LOCK_SHARE);
    metapage = BufferGetPage(metabuf);
    meta = (RTreeMetaPageData *) PageGetSpecialPointer(metapage);

    if (meta->magic != TRTREE_META_MAGIC)
        ereport(ERROR, (errmsg("temporal_rtree: missing meta page")));

    rootblk = meta->root;
    rootlevel = meta->root_level;

    LockBuffer(metabuf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(metabuf);

    result = rtree_insert_page(rel, rootblk, rootlevel, itup, &box);

    if (result.split)
    {
        BlockNumber new_rootblk;

        rtree_root_promote(rel, rootblk, &result, rootlevel, &new_rootblk);

        metabuf = ReadBufferExtended(rel, MAIN_FORKNUM, 0, RBM_NORMAL, NULL);
        LockBuffer(metabuf, BUFFER_LOCK_EXCLUSIVE);
        metapage = BufferGetPage(metabuf);
        meta = (RTreeMetaPageData *) PageGetSpecialPointer(metapage);
        meta->root = new_rootblk;
        meta->root_level = rootlevel + 1;
        MarkBufferDirty(metabuf);
        UnlockReleaseBuffer(metabuf);
    }

    pfree(itup);
    return true;
}
