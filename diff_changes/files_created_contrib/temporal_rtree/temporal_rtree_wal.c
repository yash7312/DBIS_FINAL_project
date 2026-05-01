#include "postgres.h"
#include "access/generic_xlog.h"
#include "access/xloginsert.h"
#include "access/xlog.h"
#include "storage/bufmgr.h"
#include "temporal_rtree.h"
#include "temporal_rtree_private.h"

/*
 * GenericXLog wrapper for insert: logs a page modification when a tuple is added.
 * This is the simplest WAL approach for extension code.
 */
void
rtree_wal_insert(Relation rel, Buffer buf, OffsetNumber offset, RTreeTemporalBox *box, ItemPointer tid)
{
    GenericXLogState *state;

    state = GenericXLogStart(rel);
    GenericXLogRegisterBuffer(state, buf, GENERIC_XLOG_FULL_IMAGE);

    /* If you later store page-specific metadata in opaque area, update it here */
    GenericXLogFinish(state);

    elog(DEBUG2, "rtree_wal_insert: logged insert at offset %d", offset);
}

/*
 * GenericXLog wrapper for split: logs that a page was split and linked.
 */
void
rtree_wal_split(Relation rel, Buffer left_buf, Buffer right_buf, BlockNumber right_link)
{
    GenericXLogState *state;

    state = GenericXLogStart(rel);
    GenericXLogRegisterBuffer(state, left_buf, GENERIC_XLOG_FULL_IMAGE);
    GenericXLogRegisterBuffer(state, right_buf, GENERIC_XLOG_FULL_IMAGE);
    GenericXLogFinish(state);

    elog(DEBUG2, "rtree_wal_split: logged split with rightlink %u", right_link);
}

/*
 * GenericXLog wrapper for vacuum: logs entries marked for deletion.
 */
void
rtree_wal_vacuum(Relation rel, Buffer buf, OffsetNumber *dead_offsets, int ndead)
{
    GenericXLogState *state;

    state = GenericXLogStart(rel);
    GenericXLogRegisterBuffer(state, buf, GENERIC_XLOG_FULL_IMAGE);
    GenericXLogFinish(state);

    elog(DEBUG2, "rtree_wal_vacuum: logged vacuum of %d entries", ndead);
}
