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
static bool rtree_ensure_query(IndexScanDesc scan, RTreeScanOpaque opaque);
static RTreeMetaPageData rtree_read_meta(Relation indexRel);
static void rtree_release_current_page(RTreeScanOpaque opaque);
static void rtree_stack_reset(RTreeScanOpaque opaque);
static bool rtree_stack_push(RTreeScanOpaque opaque, BlockNumber blkno,
                             uint16 level, OffsetNumber next_offset);
static bool rtree_initialize_scan(IndexScanDesc scan, RTreeScanOpaque opaque);
static bool rtree_scan_next(IndexScanDesc scan, RTreeScanOpaque opaque);

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
    // elog(NOTICE,
    //  "temporal_rtree parse: numberOfKeys=%d",
    //  scan->numberOfKeys);

    for (i = 0; i < scan->numberOfKeys; i++)
    {
        ScanKey key = &scan->keyData[i];

        if (key->sk_flags & SK_ISNULL)
            continue;

        if (key->sk_strategy < TRTREE_STRATEGY_OVERLAP ||
            key->sk_strategy > TRTREE_STRATEGY_CONTAINED)
            continue;
        
        // elog(NOTICE,
        //     "temporal_rtree parse key: i=%d strategy=%d flags=%d",
        //     i,
        //     key->sk_strategy,
        //     key->sk_flags);

        *query = rtree_cube_to_box(DatumGetNDBOXP(key->sk_argument));
        *strategy = key->sk_strategy;
        return true;
    }

    return false;
}

static bool
rtree_ensure_query(IndexScanDesc scan, RTreeScanOpaque opaque)
{
    if (opaque->have_query)
        return true;

    if (!rtree_parse_query(scan, &opaque->query_box, &opaque->strategy))
        return false;

    opaque->have_query = true;
    return true;
}

static void
rtree_release_current_page(RTreeScanOpaque opaque)
{
    if (BufferIsValid(opaque->cur_buf))
    {
        RTREE_UNLOCK(opaque->cur_buf);
        ReleaseBuffer(opaque->cur_buf);
        opaque->cur_buf = InvalidBuffer;
        opaque->cur_blkno = InvalidBlockNumber;
    }
}

static void
rtree_stack_reset(RTreeScanOpaque opaque)
{
    opaque->stack_top = 0;
}

static bool
rtree_stack_push(RTreeScanOpaque opaque, BlockNumber blkno, uint16 level,
                 OffsetNumber next_offset)
{
    if (opaque->stack_top >= opaque->stack_size)
    {
        int new_size = Max(opaque->stack_size * 2, 16);
        opaque->stack = (RTreeScanFrameData *) repalloc(opaque->stack,
                                                        sizeof(RTreeScanFrameData) * new_size);
        opaque->stack_size = new_size;
    }

    opaque->stack[opaque->stack_top].blkno = blkno;
    opaque->stack[opaque->stack_top].level = level;
    opaque->stack[opaque->stack_top].next_offset = next_offset;
    opaque->stack_top++;
    return true;
}

static bool
rtree_initialize_scan(IndexScanDesc scan, RTreeScanOpaque opaque)
{
    RTreeMetaPageData meta;

    if (!rtree_ensure_query(scan, opaque))
    {
        // elog(NOTICE, "temporal_rtree: no usable scan key found");
        return false;
    }

    meta = rtree_read_meta(scan->indexRelation);

    if (meta.magic != TRTREE_META_MAGIC)
    {
        // elog(NOTICE,
        //      "temporal_rtree: bad meta magic=%u expected=%u",
        //      meta.magic,
        //      TRTREE_META_MAGIC);
        return false;
    }

    rtree_stack_reset(opaque);
    rtree_release_current_page(opaque);
    opaque->first_call = false;

    if (meta.root == InvalidBlockNumber)
        return false;

    return rtree_stack_push(opaque, meta.root, meta.root_level, FirstOffsetNumber);
}

static bool
rtree_scan_next(IndexScanDesc scan, RTreeScanOpaque opaque)
{
    Relation indexRel = scan->indexRelation;
    Page page;
    OffsetNumber maxoff;
    OffsetNumber offset;

    while (opaque->stack_top > 0)
    {
        RTreeScanFrameData *frame = &opaque->stack[opaque->stack_top - 1];

        if (!BufferIsValid(opaque->cur_buf) || opaque->cur_blkno != frame->blkno)
        {
            rtree_release_current_page(opaque);
            opaque->cur_buf = ReadBufferExtended(indexRel, MAIN_FORKNUM,
                                                 frame->blkno, RBM_NORMAL, NULL);
            RTREE_LOCK_FOR_READ(opaque->cur_buf);
            opaque->cur_blkno = frame->blkno;
        }

        page = BufferGetPage(opaque->cur_buf);
        maxoff = PageGetMaxOffsetNumber(page);
        // elog(NOTICE,
        //     "rtree scan page: blk=%u level=%u next_offset=%u maxoff=%u",
        //     frame->blkno,
        //     frame->level,
        //     frame->next_offset,
        //     maxoff);

        for (offset = frame->next_offset; offset <= maxoff; offset++)
        {
            ItemId itemid = PageGetItemId(page, offset);
            IndexTuple itup;
            RTreeTemporalBox box;

            if (!ItemIdIsUsed(itemid))
                continue;

            itup = (IndexTuple) PageGetItem(page, itemid);
            if (!rtree_index_tuple_box(indexRel, itup, &box))
            {
                // elog(NOTICE,
                //     "rtree scan: could not extract box at blk=%u off=%u level=%u",
                //     frame->blkno,
                //     offset,
                //     frame->level);
                continue;
            }

            if (frame->level == 0)
            {
                /*
                * Correctness-safe leaf filtering:
                * We still set xs_recheck=true so executor verifies the original SQL qual.
                * This prevents false positives while avoiding the huge cost of returning
                * every leaf tuple.
                */
                if (rtree_box_matches_strategy(&box, &opaque->query_box,
                                            opaque->strategy))
                {
                    frame->next_offset = offset + 1;
                    opaque->cur_offset = offset;
                    scan->xs_heaptid = itup->t_tid;

                    /*
                    * Keep true for now. After correctness is validated, this can become
                    * false if AM predicate semantics exactly match SQL cube operators.
                    */
                    scan->xs_recheck = false;                                                   ///////////////
                    return true;
                }

                continue;
            }

            /*
            * Correctness-first traversal:
            * Descend into every internal child.
            *
            * Leaf tuples are still filtered exactly using rtree_box_matches_strategy().
            * This avoids false negatives caused by stale/corrupt internal MBRs.
            *
            * TODO: Re-enable internal MBR pruning after validating MBR construction,
            * infinity handling, and split propagation.
            */
            {
                BlockNumber childblk = ItemPointerGetBlockNumber(&itup->t_tid);

                frame->next_offset = offset + 1;
                rtree_release_current_page(opaque);
                rtree_stack_push(opaque, childblk, frame->level - 1, FirstOffsetNumber);
                break;
            }
        }

        if (offset > maxoff)
        {
            rtree_release_current_page(opaque);
            opaque->stack_top--;
        }
    }

    return false;
}

IndexScanDesc
temporal_rtree_beginscan(Relation r, int nkeys, int norderbys)
{
    IndexScanDesc scan = RelationGetIndexScan(r, nkeys, norderbys);
    RTreeScanOpaque opaque;

    // elog(NOTICE, "TEMPORAL_RTREE DEBUG: new search.c loaded");

    opaque = (RTreeScanOpaque) palloc0(sizeof(RTreeScanOpaqueData));
    opaque->cur_buf = InvalidBuffer;
    opaque->cur_offset = InvalidOffsetNumber;
    opaque->cur_blkno = InvalidBlockNumber;
    opaque->first_call = true;
    opaque->have_query = false;
    opaque->stack_size = 16;
    opaque->stack_top = 0;
    opaque->stack = (RTreeScanFrameData *) palloc0(sizeof(RTreeScanFrameData) * opaque->stack_size);

    scan->opaque = opaque;

    // elog(DEBUG1, "temporal_rtree: beginscan initialized with stack-driven cursor scan");
    return scan;
}

bool
temporal_rtree_gettuple(IndexScanDesc scan, ScanDirection dir)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return false;

    if (!ScanDirectionIsForward(dir))
        return false;

    if (opaque->first_call)
    {
        if (!rtree_initialize_scan(scan, opaque))
            return false;
    }

    return rtree_scan_next(scan, opaque);
}

void
temporal_rtree_rescan(IndexScanDesc scan,
                      ScanKey key,
                      int nkeys,
                      ScanKey orderbys,
                      int norderbys)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return;

    /*
     * PostgreSQL passes runtime scan keys here.
     * RelationGetIndexScan() allocates scan->keyData, but the AM must copy
     * the incoming keys into it during rescan.
     */
    if (key != NULL && nkeys > 0)
    {
        if (scan->keyData == NULL)
            elog(ERROR, "temporal_rtree: scan keyData is NULL");

        memcpy(scan->keyData, key, sizeof(ScanKeyData) * nkeys);                ///////////////////////
        scan->numberOfKeys = nkeys;
    }

    /*
     * This AM does not support order-by scans yet.
     */
    (void) orderbys;
    (void) norderbys;

    rtree_release_current_page(opaque);
    rtree_stack_reset(opaque);

    opaque->first_call = true;
    opaque->have_query = false;
    opaque->cur_offset = InvalidOffsetNumber;
    opaque->cur_blkno = InvalidBlockNumber;
}

void
temporal_rtree_endscan(IndexScanDesc scan)
{
    RTreeScanOpaque opaque = (RTreeScanOpaque) scan->opaque;

    if (opaque == NULL)
        return;

    rtree_release_current_page(opaque);
    if (opaque->stack != NULL)
        pfree(opaque->stack);
    pfree(opaque);
    scan->opaque = NULL;
}
