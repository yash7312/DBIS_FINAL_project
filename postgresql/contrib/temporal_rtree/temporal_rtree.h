#ifndef TEMPORAL_RTREE_H
#define TEMPORAL_RTREE_H

#include "postgres.h"
#include "access/itup.h"

/* Flags for bounds */
#define TRTREE_FLAG_EMPTY      0x0001
#define TRTREE_FLAG_LOWER_INF  0x0002
#define TRTREE_FLAG_UPPER_INF  0x0004

/* Page flags */
#define TRTREE_PAGE_LEAF 0x01
#define TRTREE_PAGE_ROOT 0x02

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

#endif /* TEMPORAL_RTREE_H */
