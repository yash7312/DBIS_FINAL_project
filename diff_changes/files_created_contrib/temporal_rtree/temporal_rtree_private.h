#ifndef TEMPORAL_RTREE_PRIVATE_H
#define TEMPORAL_RTREE_PRIVATE_H

#include "postgres.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/sdir.h"
#include "access/tableam.h"
#include "storage/bufmgr.h"
#include "temporal_rtree.h"

/*
 * Scan opaque data: holds page pins, traversal state, and scan context
 * following GiST's GISTScanOpaqueData pattern.
 */
typedef struct RTreeScanFrameData
{
    BlockNumber blkno;
    uint16 level;
    OffsetNumber next_offset;
} RTreeScanFrameData;

typedef struct RTreeScanOpaqueData
{
    Buffer cur_buf;           /* current pinned buffer, or InvalidBuffer */
    OffsetNumber cur_offset;  /* last returned tuple offset */
    BlockNumber cur_blkno;    /* current block number */

    bool first_call;          /* true until first gettuple */

    RTreeTemporalBox query_box;
    StrategyNumber strategy;
    bool have_query;

    RTreeScanFrameData *stack;
    int stack_size;
    int stack_top;
} RTreeScanOpaqueData;

typedef RTreeScanOpaqueData *RTreeScanOpaque;

/* Buffer locking macros */
#define RTREE_LOCK_FOR_READ(buf)  LockBuffer((buf), BUFFER_LOCK_SHARE)
#define RTREE_LOCK_FOR_WRITE(buf) LockBuffer((buf), BUFFER_LOCK_EXCLUSIVE)
#define RTREE_UNLOCK(buf)         LockBuffer((buf), BUFFER_LOCK_UNLOCK)

typedef struct RTreeVacuumStateData
{
    IndexVacuumInfo *info;
    IndexBulkDeleteResult *stats;
    IndexBulkDeleteCallback callback;
    void *callback_state;
} RTreeVacuumStateData;

typedef RTreeVacuumStateData *RTreeVacuumState;

/* WAL record helpers (GenericXLog wrappers) */
extern void rtree_wal_insert(Relation rel, Buffer buf, OffsetNumber offset, RTreeTemporalBox *box, ItemPointer tid);
extern void rtree_wal_split(Relation rel, Buffer left_buf, Buffer right_buf, BlockNumber right_link);
extern void rtree_wal_vacuum(Relation rel, Buffer buf, OffsetNumber *dead_offsets, int ndead);

extern bool rtree_vacuum_shrink_root(Relation rel, BlockNumber rootblk,
                                     uint16 root_level,
                                     IndexBulkDeleteResult *stats);

#endif /* TEMPORAL_RTREE_PRIVATE_H */
