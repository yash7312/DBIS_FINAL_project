#ifndef TEMPORAL_RTREE_H
#define TEMPORAL_RTREE_H

#include "postgres.h"
#include "access/rel.h"
#include "access/itup.h"
#include "access/stratnum.h"
#include "storage/bufpage.h"
#include "cubedata.h"

/* Flags for bounds */
#define TRTREE_FLAG_EMPTY      0x0001
#define TRTREE_FLAG_LOWER_INF  0x0002
#define TRTREE_FLAG_UPPER_INF  0x0004

/* Operator strategy numbers */
#define TRTREE_STRATEGY_OVERLAP   1
#define TRTREE_STRATEGY_CONTAINS  2
#define TRTREE_STRATEGY_CONTAINED 3

/* Meta page magic */
#define TRTREE_META_MAGIC 0x54525452U

/* Page flags */
#define TRTREE_PAGE_LEAF 0x01
#define TRTREE_PAGE_ROOT 0x02
#define TRTREE_PAGE_META 0x04

typedef struct RTreeMetaPageData
{
    uint32 magic;
    BlockNumber root;
    uint16 root_level;
    uint16 flags;
} RTreeMetaPageData;

typedef struct RTreeTemporalBox
{
    int64 lower_us;      /* epoch microseconds */
    int64 upper_us;      /* PG_INT64_MAX if upper-inf */
    int32 attr_lo;       /* optional second dimension */
    int32 attr_hi;
    uint16 dims;         /* 1 = time only, 2 = attr x time */
    uint16 flags;        /* EMPTY, LOWER_INF, UPPER_INF */
} RTreeTemporalBox;

typedef struct RTreePageOpaqueData
{
    BlockNumber rightlink;   /* sibling / split-follow-right */
    uint16 flags;            /* LEAF, ROOT, DELETED, META */
    uint16 level;            /* 0 = leaf */
    uint64 nsn;              /* split sequence / retry aid */
} RTreePageOpaqueData;

typedef struct RTreeLeafTupleData
{
    IndexTupleData itup;     /* t_tid = heap TID */
    RTreeTemporalBox key;
} RTreeLeafTupleData;

typedef struct RTreeInnerTupleData
{
    IndexTupleData itup;     /* t_tid points to child/downlink */
    RTreeTemporalBox mbr;
} RTreeInnerTupleData;

/* penalty and picksplit API for in-memory arrays */
extern double tr_penalty(const RTreeTemporalBox *child, const RTreeTemporalBox *newb, double w_attr, double w_current);
extern RTreeTemporalBox tr_union(const RTreeTemporalBox *a, const RTreeTemporalBox *b);
extern int tr_picksplit(RTreeTemporalBox *items, int nitems, int *left_idxs, int *nleft, int *right_idxs, int *nright);

extern RTreeTemporalBox rtree_cube_to_box(const NDBOX *cube);
extern NDBOX *rtree_box_to_cube(const RTreeTemporalBox *box);
extern bool rtree_box_overlaps(const RTreeTemporalBox *a, const RTreeTemporalBox *b);
extern bool rtree_box_contains(const RTreeTemporalBox *a, const RTreeTemporalBox *b);
extern bool rtree_box_contained(const RTreeTemporalBox *a, const RTreeTemporalBox *b);
extern bool rtree_box_matches_strategy(const RTreeTemporalBox *tuple_box,
                                       const RTreeTemporalBox *query_box,
                                       StrategyNumber strategy);
extern void rtree_init_metapage(Page page, BlockNumber rootblk, uint16 rootlevel);
extern void rtree_init_datapage(Page page, uint16 flags, uint16 level);
extern bool rtree_index_tuple_box(Relation indexRel, IndexTuple itup, RTreeTemporalBox *box);
extern IndexTuple rtree_form_tuple(Relation indexRel, const RTreeTemporalBox *box, ItemPointer heap_tid);
extern RTreeTemporalBox rtree_page_mbr(Relation indexRel, Page page, bool leaf);

#endif /* TEMPORAL_RTREE_H */
