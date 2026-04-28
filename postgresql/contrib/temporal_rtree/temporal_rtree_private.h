#ifndef TEMPORAL_RTREE_PRIVATE_H
#define TEMPORAL_RTREE_PRIVATE_H

#include "postgres.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/sdir.h"
#include "storage/bufmgr.h"
#include "temporal_rtree.h"

/*
 * Scan opaque data: holds page pins, traversal state, and scan context
 * following GiST's GISTScanOpaqueData pattern.
 */
typedef struct RTreeScanItemData
{
    OffsetNumber offnum;
    RTreeTemporalBox box;
} RTreeScanItemData;

typedef struct RTreeScanOpaqueData
{
    Buffer cur_buf;           /* current pinned buffer, or InvalidBuffer */
    OffsetNumber cur_offset;  /* last returned tuple offset */
    uint16 level;             /* current tree level */
    BlockNumber cur_blkno;    /* current block number */

    /* Item queue for deferred traversal (unvisited children) */
    RTreeScanItemData *items;
    int nitems;
    int items_size;           /* allocated size */
    int next_item;            /* index into items[] */

    bool first_call;          /* true until first gettuple */
    ScanDirection direction;  /* forward or backward */
} RTreeScanOpaqueData;

typedef RTreeScanOpaqueData *RTreeScanOpaque;

/* Buffer locking macros */
#define RTREE_LOCK_FOR_READ(buf)  LockBuffer((buf), BUFFER_LOCK_SHARE)
#define RTREE_LOCK_FOR_WRITE(buf) LockBuffer((buf), BUFFER_LOCK_EXCLUSIVE)
#define RTREE_UNLOCK(buf)         LockBuffer((buf), BUFFER_LOCK_UNLOCK)

/* WAL record helpers (GenericXLog wrappers) */
extern void rtree_wal_insert(Relation rel, Buffer buf, OffsetNumber offset, RTreeTemporalBox *box, ItemPointer tid);
extern void rtree_wal_split(Relation rel, Buffer left_buf, Buffer right_buf, BlockNumber right_link);
extern void rtree_wal_vacuum(Relation rel, Buffer buf, OffsetNumber *dead_offsets, int ndead);

#endif /* TEMPORAL_RTREE_PRIVATE_H */
