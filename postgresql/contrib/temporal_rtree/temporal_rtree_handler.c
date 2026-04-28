#include "postgres.h"
#include "fmgr.h"
#include "access/amapi.h"
#include "access/relscan.h"
#include "access/reloptions.h"
#include "nodes/execnodes.h"
#include "nodes/pathnodes.h"
#include "optimizer/pathnode.h"
#include "utils/elog.h"

PG_MODULE_MAGIC;

/* forward declarations of AM callbacks */
extern bool temporal_rtree_insert(Relation rel, Datum *values, bool *isnull,
                                  ItemPointer ht_ctid, Relation heapRel,
                                  IndexUniqueCheck checkUnique,
                                  bool indexUnchanged, IndexInfo *indexInfo);
extern IndexScanDesc temporal_rtree_beginscan(Relation r, int nkeys, int norderbys);
extern bool temporal_rtree_gettuple(IndexScanDesc scan, ScanDirection dir);
extern void temporal_rtree_rescan(IndexScanDesc scan, ScanKey key, int nkeys, ScanKey orderbys, int norderbys);
extern void temporal_rtree_endscan(IndexScanDesc scan);
extern IndexBulkDeleteResult *temporal_rtree_bulkdelete(IndexVacuumInfo *info,
                                                        IndexBulkDeleteResult *stats,
                                                        IndexBulkDeleteCallback callback,
                                                        void *callback_state);
extern IndexBulkDeleteResult *temporal_rtree_vacuumcleanup(IndexVacuumInfo *info,
                                                           IndexBulkDeleteResult *stats);
extern void temporal_rtree_costestimate(PlannerInfo *root, IndexPath *path,
                                        double loop_count, Cost *indexStartupCost,
                                        Cost *indexTotalCost, Selectivity *indexSelectivity,
                                        double *indexCorrelation, double *indexPages);

/* handler declaration */
PG_FUNCTION_INFO_V1(temporal_rtree_handler);

Datum
temporal_rtree_handler(PG_FUNCTION_ARGS)
{
    IndexAmRoutine *amroutine = (IndexAmRoutine *) palloc0(sizeof(IndexAmRoutine));

    amroutine->type = T_IndexAmRoutine;

    /* Basic capabilities; refine later */
    amroutine->amstrategies = 0;
    amroutine->amsupport = 0;
    amroutine->amcanmulticol = true;
    amroutine->amoptionalkey = true;
    amroutine->amsearchnulls = true;
    amroutine->amcanparallel = true;
    amroutine->amcanbuildparallel = true;
    amroutine->ampredlocks = false;


    /* Implementation callbacks: wire to our stubs/implementations */
    amroutine->ambuild = NULL;
    amroutine->ambuildempty = NULL;
    amroutine->aminsert = temporal_rtree_insert;
    amroutine->ambulkdelete = temporal_rtree_bulkdelete;
    amroutine->amvacuumcleanup = temporal_rtree_vacuumcleanup;
    amroutine->amcostestimate = temporal_rtree_costestimate;

    amroutine->ambeginscan = temporal_rtree_beginscan;
    amroutine->amrescan = temporal_rtree_rescan;
    amroutine->amgettuple = temporal_rtree_gettuple;
    amroutine->amgetbitmap = NULL;
    amroutine->amendscan = temporal_rtree_endscan;

    PG_RETURN_POINTER(amroutine);
}
