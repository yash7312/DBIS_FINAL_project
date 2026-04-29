#include "postgres.h"

#include "access/itup.h"
#include "access/stratnum.h"
#include "storage/bufpage.h"
#include <string.h>
#include <math.h>
#include "temporal_rtree.h"

static NDBOX *
rtree_box_to_cube_internal(const RTreeTemporalBox *box)
{
    NDBOX *cube;
    bool point;
    Size size;
    double coords[4];

    point = (box->attr_lo == box->attr_hi &&
             box->lower_us == box->upper_us &&
             !(box->flags & (TRTREE_FLAG_LOWER_INF | TRTREE_FLAG_UPPER_INF)));
    size = point ? POINT_SIZE(2) : CUBE_SIZE(2);
    cube = (NDBOX *) palloc0(size);
    coords[0] = (double) box->attr_lo;
    coords[1] = (double) box->lower_us;

    if (!point)
    {
        coords[2] = (double) box->attr_hi;
        coords[3] = (double) box->upper_us;
    }
    else
        SET_POINT_BIT(cube);

    SET_VARSIZE(cube, size);
    SET_DIM(cube, 2);
    memcpy(cube->x, coords, point ? 2 * sizeof(double) : 4 * sizeof(double));

    return cube;
}

RTreeTemporalBox
rtree_cube_to_box(const NDBOX *cube)
{
    RTreeTemporalBox box;
    int dim;

    MemSet(&box, 0, sizeof(box));
    dim = DIM(cube);
    box.dims = (dim >= 2) ? 2 : 1;
    box.attr_lo = (int32) llround(LL_COORD(cube, 0));
    box.attr_hi = (int32) llround(IS_POINT(cube) ? LL_COORD(cube, 0) : UR_COORD(cube, 0));
    box.lower_us = (int64) llround((dim >= 2) ? LL_COORD(cube, 1) : LL_COORD(cube, 0));
    box.upper_us = (int64) llround((dim >= 2) ? (IS_POINT(cube) ? LL_COORD(cube, 1) : UR_COORD(cube, 1)) : box.lower_us);
    box.flags = 0;

    if (box.lower_us == PG_INT64_MIN)
        box.flags |= TRTREE_FLAG_LOWER_INF;
    if (box.upper_us == PG_INT64_MAX)
        box.flags |= TRTREE_FLAG_UPPER_INF;
    return box;
}

NDBOX *
rtree_box_to_cube(const RTreeTemporalBox *box)
{
    return rtree_box_to_cube_internal(box);
}

bool
rtree_box_overlaps(const RTreeTemporalBox *a, const RTreeTemporalBox *b)
{
    if (a->flags & TRTREE_FLAG_EMPTY)
        return false;
    if (b->flags & TRTREE_FLAG_EMPTY)
        return false;
    return !(a->attr_hi < b->attr_lo || b->attr_hi < a->attr_lo ||
             a->upper_us < b->lower_us || b->upper_us < a->lower_us);
}

bool
rtree_box_contains(const RTreeTemporalBox *a, const RTreeTemporalBox *b)
{
    return !(a->flags & TRTREE_FLAG_EMPTY) && !(b->flags & TRTREE_FLAG_EMPTY) &&
           a->attr_lo <= b->attr_lo && a->attr_hi >= b->attr_hi &&
           a->lower_us <= b->lower_us && a->upper_us >= b->upper_us;
}

bool
rtree_box_contained(const RTreeTemporalBox *a, const RTreeTemporalBox *b)
{
    return rtree_box_contains(b, a);
}

bool
rtree_box_matches_strategy(const RTreeTemporalBox *tuple_box,
                           const RTreeTemporalBox *query_box,
                           StrategyNumber strategy)
{
    switch (strategy)
    {
        case TRTREE_STRATEGY_OVERLAP:
            return rtree_box_overlaps(tuple_box, query_box);
        case TRTREE_STRATEGY_CONTAINS:
            return rtree_box_contains(tuple_box, query_box);
        case TRTREE_STRATEGY_CONTAINED:
            return rtree_box_contained(tuple_box, query_box);
        default:
            return rtree_box_overlaps(tuple_box, query_box);
    }
}

void
rtree_init_metapage(Page page, BlockNumber rootblk, uint16 rootlevel)
{
    RTreeMetaPageData *meta;

    PageInit(page, BLCKSZ, sizeof(RTreeMetaPageData));
    meta = (RTreeMetaPageData *) PageGetSpecialPointer(page);
    meta->magic = TRTREE_META_MAGIC;
    meta->root = rootblk;
    meta->root_level = rootlevel;
    meta->flags = TRTREE_PAGE_META;
}

void
rtree_init_datapage(Page page, uint16 flags, uint16 level)
{
    RTreePageOpaqueData *opaque;

    PageInit(page, BLCKSZ, sizeof(RTreePageOpaqueData));
    opaque = (RTreePageOpaqueData *) PageGetSpecialPointer(page);
    opaque->rightlink = InvalidBlockNumber;
    opaque->flags = flags;
    opaque->level = level;
    opaque->nsn = 0;
}

bool
rtree_index_tuple_box(Relation indexRel, IndexTuple itup, RTreeTemporalBox *box)
{
    Datum datum;
    bool isnull;

    datum = index_getattr(itup, 1, indexRel->rd_att, &isnull);
    if (isnull)
        return false;

    *box = rtree_cube_to_box(DatumGetNDBOXP(datum));
    return true;
}

IndexTuple
rtree_form_tuple(Relation indexRel, const RTreeTemporalBox *box, ItemPointer heap_tid)
{
    Datum values[1];
    bool isnull[1] = {false};
    IndexTuple itup;
    NDBOX *cube;

    cube = rtree_box_to_cube(box);
    values[0] = PointerGetDatum(cube);
    itup = index_form_tuple(indexRel->rd_att, values, isnull);
    itup->t_tid = *heap_tid;
    pfree(cube);
    return itup;
}

RTreeTemporalBox
rtree_page_mbr(Relation indexRel, Page page, bool leaf)
{
    OffsetNumber offset;
    OffsetNumber maxoff;
    RTreeTemporalBox mbr;
    bool first;

    MemSet(&mbr, 0, sizeof(mbr));
    mbr.flags = TRTREE_FLAG_EMPTY;
    first = true;
    maxoff = PageGetMaxOffsetNumber(page);

    for (offset = FirstOffsetNumber; offset <= maxoff; offset++)
    {
        ItemId itemid;
        IndexTuple itup;
        RTreeTemporalBox box;

        itemid = PageGetItemId(page, offset);
        if (!ItemIdIsUsed(itemid))
            continue;

        itup = (IndexTuple) PageGetItem(page, itemid);
        if (!rtree_index_tuple_box(indexRel, itup, &box))
            continue;

        if (first)
        {
            mbr = box;
            first = false;
        }
        else
            mbr = tr_union(&mbr, &box);
    }

    (void) leaf;
    return mbr;
}