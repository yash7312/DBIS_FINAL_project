#include "postgres.h"
#include "fmgr.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/itup.h"
#include "access/skey.h"
#include "access/sdir.h"
#include "storage/bufpage.h"
#include "storage/bufmgr.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

static bool rtree_parse_query(IndexScanDesc scan, RTreeTemporalBox *query,
                              StrategyNumber *strategy);
static void rtree_collect_matches(Relation indexRel, BlockNumber blkno,
                                  uint16 level, const RTreeTemporalBox *query,
                                  StrategyNumber strategy,
                                  ItemPointerData **matches, int *nmatches,
                                  int *matches_size);
static RTreeMetaPageData rtree_read_meta(Relation indexRel);

static RTreeMetaPageData
rtree_read_meta(Relation indexRel)
{
    Buffer buf;
    Page page;
    RTreeMetaPageData meta;

    buf = ReadBufferExtended(indexRel, MAIN_FORKNUM, 0, RBM_NORMAL, NULL);
    LockBuffer(buf, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buf);
    meta = *(RTreeMetaPageData *) PageGetSpecialPointer(page);
    LockBuffer(buf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(buf);
    return meta;
}

static bool
rtree_parse_query(IndexScanDesc scan, RTreeTemporalBox *query, StrategyNumber *strategy)
{
    int i;

    for (i = 0; i < scan->numberOfKeys; i++)
    {
        ScanKey key = &scan->keyData[i];

        if (key->sk_flags & SK_ISNULL)
            continue;

        if (key->sk_strategy < TRTREE_STRATEGY_OVERLAP ||
            key->sk_strategy > TRTREE_STRATEGY_CONTAINED)
            continue;

        *query = rtree_cube_to_box(DatumGetNDBOXP(key->sk_argument));
        *strategy = key->sk_strategy;
        return true;
    }

    return false;
}

static void
rtree_collect_matches(Relation indexRel, BlockNumber blkno, uint16 level,
                      const RTreeTemporalBox *query, StrategyNumber strategy,
                      ItemPointerData **matches, int *nmatches,
                      int *matches_size)
{
    Buffer buf;
    Page page;
    OffsetNumber offset;
    OffsetNumber maxoff;

    buf = ReadBufferExtended(indexRel, MAIN_FORKNUM, blkno, RBM_NORMAL, NULL);
    LockBuffer(buf, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buf);
    maxoff = PageGetMaxOffsetNumber(page);

    for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
    {
        ItemId itemid = PageGetItemId(page, offset);
        IndexTuple itup;
        RTreeTemporalBox box;
        bool leaf = (level == 0);

        if (!ItemIdIsUsed(itemid))
            continue;

        itup = (IndexTuple) PageGetItem(page, itemid);
        if (!rtree_index_tuple_box(indexRel, itup, &box))
            continue;

        if (leaf)
        {
            if (rtree_box_matches_strategy(&box, query, strategy))
            {
                if (*nmatches >= *matches_size)
                {
                    *matches_size *= 2;
                    *matches = repalloc(*matches, sizeof(ItemPointerData) * (*matches_size));
                }
                (*matches)[*nmatches] = itup->t_tid;
                (*nmatches)++;
            }
        }
        else if (rtree_box_overlaps(&box, query))
        {
            BlockNumber childblk = ItemPointerGetBlockNumber(&itup->t_tid);

            rtree_collect_matches(indexRel, childblk, level - 1, query, strategy,
                                  matches, nmatches, matches_size);
        }
    }

    LockBuffer(buf, BUFFER_LOCK_UNLOCK);
    ReleaseBuffer(buf);
}

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
    opaque->have_query = false;
    opaque->matches = NULL;
    opaque->nmatches = 0;
    opaque->matches_size = 32;
    opaque->next_match = 0;
    opaque->matches_built = false;

    scan->opaque = opaque;

    elog(DEBUG1, "temporal_rtree: beginscan initialized with buffer pin management");
    return scan;
}

bool
temporal_rtree_gettuple(IndexScanDesc scan, ScanDirection dir)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;
    RTreeMetaPageData meta;

    if (opaque == NULL)
        return false;

    if (!opaque->matches_built)
    {
        if (opaque->matches == NULL)
            opaque->matches = (ItemPointerData *) palloc(sizeof(ItemPointerData) * opaque->matches_size);

        meta = rtree_read_meta(scan->indexRelation);
        if (meta.magic != TRTREE_META_MAGIC || !opaque->have_query)
            return false;

        rtree_collect_matches(scan->indexRelation, meta.root, meta.root_level,
                              &opaque->query_box, opaque->strategy,
                              &opaque->matches, &opaque->nmatches,
                              &opaque->matches_size);
        opaque->matches_built = true;
    }

    if (opaque->next_match >= opaque->nmatches)
        return false;

    scan->xs_heaptid = opaque->matches[opaque->next_match++];
    scan->xs_recheck = true;
    return true;
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
    opaque->nmatches = 0;
    opaque->next_match = 0;
    opaque->matches_built = false;

    if (rtree_parse_query(scan, &opaque->query_box, &opaque->strategy))
        opaque->have_query = true;
    else
        opaque->have_query = false;

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
    if (opaque->matches != NULL)
        pfree(opaque->matches);
    pfree(opaque);
    scan->opaque = NULL;
}
