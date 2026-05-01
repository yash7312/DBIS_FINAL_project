#include "postgres.h"
#include "fmgr.h"
#include <math.h>
#include "access/amapi.h"
#include "nodes/pathnodes.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "utils/spccache.h"
#include "temporal_rtree.h"
#include "utils/selfuncs.h"

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
    IndexOptInfo *index = path->indexinfo;
    List *indexQuals = get_quals_from_indexclauses(path->indexclauses);
    List *selectivityQuals;
    Selectivity selectivity;
    Cost qual_arg_cost;
    Cost qual_op_cost;
    Cost page_cost;
    double numIndexTuples;
    double numIndexPages;
    double random_page_cost_local;
    double tuples;

    selectivityQuals = add_predicate_to_index_quals(index, indexQuals);
    selectivity = clauselist_selectivity(root,
                                         selectivityQuals,
                                         index->rel->relid,
                                         JOIN_INNER,
                                         NULL);
    selectivity = Max(0.0, Min(selectivity, 1.0));
    *indexSelectivity = selectivity;

    tuples = Max(index->tuples, 1.0);
    numIndexTuples = rint(tuples * selectivity);
    if (numIndexTuples < 1.0)
        numIndexTuples = 1.0;
    if (numIndexTuples > tuples)
        numIndexTuples = tuples;

    if (index->pages > 1.0 && tuples > 1.0)
        numIndexPages = ceil(numIndexTuples * index->pages / tuples);
    else
        numIndexPages = 1.0;
    numIndexPages = Max(1.0, Min(numIndexPages, Max(index->pages, 1.0)));

    get_tablespace_page_costs(index->reltablespace,
                              &random_page_cost_local,
                              NULL);

    qual_arg_cost = index_other_operands_eval_cost(root, indexQuals);
    qual_op_cost = cpu_operator_cost * list_length(indexQuals);

    page_cost = numIndexPages * random_page_cost_local;
    if (loop_count > 1.0 && numIndexPages > 1.0)
    {
        double pages_fetched;

        pages_fetched = index_pages_fetched(numIndexPages * loop_count,
                                            (BlockNumber) index->pages,
                                            index->pages,
                                            root);
        page_cost = (pages_fetched * random_page_cost_local) / loop_count;
    }

    *indexStartupCost = qual_arg_cost;
    *indexTotalCost = qual_arg_cost + page_cost +
        (numIndexTuples * (cpu_index_tuple_cost + qual_op_cost));
    *indexCorrelation = 0.0;
    *indexPages = numIndexPages;
}
