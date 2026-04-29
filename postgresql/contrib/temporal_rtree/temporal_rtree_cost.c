#include "postgres.h"
#include "fmgr.h"
#include "access/amapi.h"
#include "temporal_rtree.h"
#include "nodes/pathnodes.h"
#include "optimizer/optimizer.h"
#include <math.h>
#include "utils/elog.h"

void
temporal_rtree_costestimate(PlannerInfo *root,
                            IndexPath *path,
                            double loop_count,
                            Cost *indexStartupCost,
                            Cost *indexTotalCost,
                            Selectivity *indexSelectivity,
                            double *indexCorrelation,
                            double *indexPages)
{
    double pages;
    double tuples;
    double clause_factor;
    double selectivity;
    double tuples_fetched;
    int nclauses;

    (void) root;
    (void) loop_count;

    pages = Max(path->indexinfo->pages, 1.0);
    tuples = Max(path->indexinfo->tuples, 1.0);
    nclauses = list_length(path->indexclauses);

    clause_factor = 1.0 + (double) nclauses;
    selectivity = 0.35 / clause_factor;
    if (selectivity < 0.01)
        selectivity = 0.01;
    if (selectivity > 0.35)
        selectivity = 0.35;

    tuples_fetched = tuples * selectivity;
    *indexSelectivity = selectivity;

    *indexPages = Max(1.0, Min(pages, pages * selectivity + sqrt(pages)));

    *indexStartupCost = 5.0 + (double) nclauses * 2.0;
    *indexTotalCost = *indexStartupCost +
        (*indexPages * random_page_cost * 0.35) +
        (tuples_fetched * cpu_index_tuple_cost);

    *indexCorrelation = 0.0;

    elog(DEBUG1, "temporal_rtree_costestimate: pages=%.0f tuples=%.0f clauses=%d cost=%.2f",
         *indexPages, tuples, nclauses, *indexTotalCost);
}
