/*
 * temporal_rtree_hooks.c
 *
 * Lightweight hooks for temporal_rtree AM detection and logging.
 * Purpose: Track which queries/DML statements are candidates for temporal_rtree indexing.
 * No planning changes in C1; visibility only.
 *
 * Copyright (c) 2024, Temporal R-tree Project
 */

#include "postgres.h"
#include "fmgr.h"
#include "optimizer/planner.h"
#include "optimizer/clauses.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/cost.h"
#include "tcop/utility.h"
#include "executor/executor.h"
#include "utils/guc.h"
#include "utils/builtins.h"
#include "nodes/nodes.h"
#include "nodes/primnodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "catalog/pg_am.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_class.h"
#include "catalog/pg_index.h"
#include "catalog/pg_operator.h"
#include "access/relation.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "utils/syscache.h"
#include "funcapi.h"

/* Hook chain variables */
static planner_hook_type prev_planner_hook = NULL;
static ExecutorStart_hook_type prev_ExecutorStart_hook = NULL;
static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook = NULL;

/* GUC variables */
static bool trtree_enable_hook_debug = true;
static bool trtree_force_rtree_paths = false;
static bool trtree_log_dml = true;

/* Statistics counters */
static uint64 hook_stats_planner_hits = 0;
static uint64 hook_stats_planner_rtree_eligible_hits = 0;
static uint64 hook_stats_executor_dml_hits = 0;
static uint64 hook_stats_executor_target_with_rtree_hits = 0;
static uint64 hook_stats_path_bias_applied = 0;

/* SQL-visible function prototypes */
PG_FUNCTION_INFO_V1(temporal_rtree_hook_stats);
PG_FUNCTION_INFO_V1(temporal_rtree_hook_reset);

Datum temporal_rtree_hook_stats(PG_FUNCTION_ARGS);
Datum temporal_rtree_hook_reset(PG_FUNCTION_ARGS);

/* Forward declarations */
static PlannedStmt *trtree_planner_hook(Query *parse,
										const char *query_string,
										int cursorOptions,
										ParamListInfo boundParams);
static void trtree_executor_start_hook(QueryDesc *queryDesc, int eflags);
static void trtree_set_rel_pathlist_hook(PlannerInfo *root,
										  RelOptInfo *rel,
										  Index rti,
										  RangeTblEntry *rte);

/* Helper: Check if a relation has a temporal_rtree index */
static bool
trtree_has_temporal_rtree_index(Oid relationOid)
{
	Relation	rel;
	List	   *indexOids;
	ListCell   *lc;
	bool		has_rtree = false;

	rel = table_open(relationOid, AccessShareLock);

	/* Get all indexes on this relation */
	indexOids = RelationGetIndexList(rel);

	foreach(lc, indexOids)
	{
		Oid			indexOid = lfirst_oid(lc);
		Relation	indexRel;
		HeapTuple	indexTuple;
		Form_pg_index indexForm;
		Oid			amOid;

		indexRel = index_open(indexOid, AccessShareLock);
		indexTuple = SearchSysCache1(RELOID, ObjectIdGetDatum(indexOid));

		if (HeapTupleIsValid(indexTuple))
		{
			Form_pg_class indexClass = (Form_pg_class) GETSTRUCT(indexTuple);

			amOid = indexClass->relam;

			/* Check if the access method is temporal_rtree */
			if (amOid != InvalidOid)
			{
				HeapTuple	amTuple;
				Form_pg_am	amForm;

				amTuple = SearchSysCache1(AMOID, ObjectIdGetDatum(amOid));
				if (HeapTupleIsValid(amTuple))
				{
					amForm = (Form_pg_am) GETSTRUCT(amTuple);
					if (strcmp(NameStr(amForm->amname), "temporal_rtree") == 0)
					{
						has_rtree = true;
						ReleaseSysCache(amTuple);
					}
					else
					{
						ReleaseSysCache(amTuple);
					}
				}
			}
			ReleaseSysCache(indexTuple);
		}

		index_close(indexRel, AccessShareLock);

		if (has_rtree)
			break;
	}

	list_free(indexOids);
	table_close(rel, AccessShareLock);

	return has_rtree;
}

/* Helper: Check if expression tree contains temporalbox(...) */
static bool
trtree_contains_temporalbox(Node *node)
{
	if (node == NULL)
		return false;

	if (IsA(node, FuncExpr))
	{
		FuncExpr   *func = (FuncExpr *) node;
		const char *funcname;
		HeapTuple	tuple;

		tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(func->funcid));
		if (HeapTupleIsValid(tuple))
		{
			Form_pg_proc procForm = (Form_pg_proc) GETSTRUCT(tuple);

			funcname = NameStr(procForm->proname);
			if (strcmp(funcname, "temporalbox") == 0)
			{
				ReleaseSysCache(tuple);
				return true;
			}
			ReleaseSysCache(tuple);
		}
	}

	/* Recurse into expression tree */
	return expression_tree_walker(node, (bool (*)(Node *, void *)) trtree_contains_temporalbox, NULL);
}

/* Helper: Check if an operator is compatible with temporal_rtree paths (&&, @>, <@) */
static bool
trtree_is_compatible_operator(Oid opoid)
{
	const char *opname = NULL;
	HeapTuple	optuple;
	Form_pg_operator opForm;

	optuple = SearchSysCache1(OPEROID, ObjectIdGetDatum(opoid));
	if (!HeapTupleIsValid(optuple))
		return false;

	opForm = (Form_pg_operator) GETSTRUCT(optuple);
	opname = NameStr(opForm->oprname);

	/* Check for supported operators: &&, @>, <@ */
	bool result = (strcmp(opname, "&&") == 0 ||
				   strcmp(opname, "@>") == 0 ||
				   strcmp(opname, "<@") == 0);

	ReleaseSysCache(optuple);
	return result;
}

/* Helper: Check if a clause is compatible with temporal_rtree indexing */
static bool
trtree_clause_is_temporal_rtree_compatible(Node *clause)
{
	if (clause == NULL)
		return false;

	/* Look for OpExpr: temporalbox(...) op cube_expr */
	if (IsA(clause, OpExpr))
	{
		OpExpr	   *opexpr = (OpExpr *) clause;

		if (list_length(opexpr->args) == 2)
		{
			Node	   *leftarg = linitial(opexpr->args);
			Node	   *rightarg = lsecond(opexpr->args);

			/* Check if left arg is temporalbox(...) and operator is compatible */
			if (trtree_contains_temporalbox(leftarg) &&
				trtree_is_compatible_operator(opexpr->opno))
				return true;

			/* Also check if right arg is temporalbox(...) */
			if (trtree_contains_temporalbox(rightarg) &&
				trtree_is_compatible_operator(opexpr->opno))
				return true;
		}
	}

	/* Recurse for AND clauses */
	if (IsA(clause, BoolExpr))
	{
		BoolExpr   *boolexpr = (BoolExpr *) clause;

		if (boolexpr->boolop == AND_EXPR)
		{
			ListCell   *lc;

			foreach(lc, boolexpr->args)
			{
				if (trtree_clause_is_temporal_rtree_compatible(lfirst(lc)))
					return true;
			}
		}
	}

	return false;
}

/* Helper: Check if any restriction clause is temporal_rtree compatible */
static bool
trtree_has_compatible_clauses(RelOptInfo *rel)
{
	ListCell   *lc;

	if (rel->baserestrictinfo == NULL)
		return false;

	foreach(lc, rel->baserestrictinfo)
	{
		RestrictInfo *rinfo = (RestrictInfo *) lfirst(lc);

		if (trtree_clause_is_temporal_rtree_compatible((Node *) rinfo->clause))
			return true;
	}

	return false;
}

/* Helper: Get temporal_rtree index OID for a relation, if present */
static Oid
trtree_get_rtree_index_oid(Oid relationOid)
{
	Relation	rel;
	List	   *indexOids;
	ListCell   *lc;
	Oid			result = InvalidOid;

	rel = table_open(relationOid, AccessShareLock);
	indexOids = RelationGetIndexList(rel);

	foreach(lc, indexOids)
	{
		Oid			indexOid = lfirst_oid(lc);
		Relation	indexRel;
		HeapTuple	indexTuple;
		Oid			amOid;

		indexRel = index_open(indexOid, AccessShareLock);
		indexTuple = SearchSysCache1(RELOID, ObjectIdGetDatum(indexOid));

		if (HeapTupleIsValid(indexTuple))
		{
			Form_pg_class indexClass = (Form_pg_class) GETSTRUCT(indexTuple);
			amOid = indexClass->relam;

			if (amOid != InvalidOid)
			{
				HeapTuple	amTuple = SearchSysCache1(AMOID, ObjectIdGetDatum(amOid));
				if (HeapTupleIsValid(amTuple))
				{
					Form_pg_am amForm = (Form_pg_am) GETSTRUCT(amTuple);
					if (strcmp(NameStr(amForm->amname), "temporal_rtree") == 0)
					{
						result = indexOid;
						ReleaseSysCache(amTuple);
						ReleaseSysCache(indexTuple);
						index_close(indexRel, AccessShareLock);
						break;
					}
					ReleaseSysCache(amTuple);
				}
			}
			ReleaseSysCache(indexTuple);
		}
		index_close(indexRel, AccessShareLock);
	}

	list_free(indexOids);
	table_close(rel, AccessShareLock);

	return result;
}

/* Planner hook: log temporal_rtree-eligible queries */
static PlannedStmt *
trtree_planner_hook(Query *parse,
					 const char *query_string,
					 int cursorOptions,
					 ParamListInfo boundParams)
{
	PlannedStmt *result;
	bool		has_temporalbox = false;
	bool		has_rtree_indexed_rel = false;
	ListCell   *lc;

	/* Check if query uses temporalbox(...) in target list or WHERE conditions */
	if (parse->targetList)
	{
		if (trtree_contains_temporalbox((Node *) parse->targetList))
			has_temporalbox = true;
	}

	if (!has_temporalbox && parse->jointree && parse->jointree->quals)
	{
		if (trtree_contains_temporalbox(parse->jointree->quals))
			has_temporalbox = true;
	}

	/* Check if any ranged relation has a temporal_rtree index */
	foreach(lc, parse->rtable)
	{
		RangeTblEntry *rte = (RangeTblEntry *) lfirst(lc);

		if (rte->rtekind == RTE_RELATION && rte->relid != InvalidOid)
		{
			if (trtree_has_temporal_rtree_index(rte->relid))
			{
				has_rtree_indexed_rel = true;
				break;
			}
		}
	}

	/* Update statistics */
	if (has_temporalbox || has_rtree_indexed_rel)
	{
		hook_stats_planner_hits++;
		if (has_temporalbox && has_rtree_indexed_rel)
			hook_stats_planner_rtree_eligible_hits++;
	}

	/* Log hook hit if debugging enabled */
	if (trtree_enable_hook_debug && (has_temporalbox || has_rtree_indexed_rel))
	{
		ereport(LOG,
				(errmsg("temporal_rtree planner hook: has_temporalbox=%d has_rtree_idx=%d",
						has_temporalbox, has_rtree_indexed_rel),
				 query_string ? errdetail("query: %s", query_string) : 0));
	}

	/* Call previous hook or standard planner */
	if (prev_planner_hook)
		result = prev_planner_hook(parse, query_string, cursorOptions, boundParams);
	else
		result = standard_planner(parse, query_string, cursorOptions, boundParams);

	return result;
}

/* Executor start hook: log DML targeting temporal_rtree indexed tables */
static void
trtree_executor_start_hook(QueryDesc *queryDesc, int eflags)
{
	bool		has_rtree_idx = false;

	/* Check for DML (INSERT, UPDATE, DELETE) */
	if (queryDesc->plannedstmt && queryDesc->plannedstmt->rtable)
	{
		ListCell   *lc;

		foreach(lc, queryDesc->plannedstmt->rtable)
		{
			RangeTblEntry *rte = (RangeTblEntry *) lfirst(lc);

			if (rte->rtekind == RTE_RELATION && rte->relid != InvalidOid)
			{
				/* Check if this is the target of an insert/update/delete */
				if (queryDesc->operation != CMD_SELECT)
				{
					hook_stats_executor_dml_hits++;
					if (trtree_has_temporal_rtree_index(rte->relid))
					{
						has_rtree_idx = true;
						hook_stats_executor_target_with_rtree_hits++;
					}
				}
			}
		}
	}

	/* Log hook hit if debugging enabled */
	if (trtree_enable_hook_debug && trtree_log_dml && has_rtree_idx)
	{
		const char *cmdname = "UNKNOWN";

		switch (queryDesc->operation)
		{
			case CMD_SELECT:
				cmdname = "SELECT";
				break;
			case CMD_INSERT:
				cmdname = "INSERT";
				break;
			case CMD_UPDATE:
				cmdname = "UPDATE";
				break;
			case CMD_DELETE:
				cmdname = "DELETE";
				break;
			default:
				cmdname = "OTHER";
				break;
		}

		ereport(LOG,
				(errmsg("temporal_rtree executor hook: %s statement on temporal_rtree-indexed relation",
						cmdname)));
	}

	/* Call previous hook or standard start */
	if (prev_ExecutorStart_hook)
		prev_ExecutorStart_hook(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}

/* Set rel pathlist hook: Bias paths toward temporal_rtree when force_rtree_paths is enabled */
static void
trtree_set_rel_pathlist_hook(PlannerInfo *root,
							  RelOptInfo *rel,
							  Index rti,
							  RangeTblEntry *rte)
{
	Oid			rtree_index_oid;
	ListCell   *lc;
	bool		found_matched_path = false;

	/* Call previous hook first */
	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	/* If forcing disabled, nothing to do */
	if (!trtree_force_rtree_paths)
		return;

	/* Only apply biasing for SELECT/UPDATE/DELETE (not INSERT) */
	if (root->parse->commandType != CMD_SELECT &&
		root->parse->commandType != CMD_UPDATE &&
		root->parse->commandType != CMD_DELETE)
		return;

	/* Check if relation has a temporal_rtree index */
	if (rte->rtekind != RTE_RELATION || rte->relid == InvalidOid)
		return;

	rtree_index_oid = trtree_get_rtree_index_oid(rte->relid);
	if (rtree_index_oid == InvalidOid)
		return;

	/* Check if there are compatible restriction clauses */
	if (!trtree_has_compatible_clauses(rel))
		return;

	/* Bias the cost of temporal_rtree IndexPath downward */
	foreach(lc, rel->pathlist)
	{
		Path	   *path = (Path *) lfirst(lc);
		IndexPath  *indexpath;

		if (!IsA(path, IndexPath))
			continue;

		indexpath = (IndexPath *) path;

		/* Check if this index path is for our temporal_rtree index */
		if (indexpath->indexinfo->indexoid == rtree_index_oid)
		{
			/* Apply cost bias: multiply by 0.05 to make temporal_rtree much cheaper */
			/* This is conservative to test the cost model; adjust as needed */
			const double COST_BIAS_FACTOR = 0.05;

			indexpath->path.startup_cost *= COST_BIAS_FACTOR;
			indexpath->path.total_cost *= COST_BIAS_FACTOR;

			found_matched_path = true;

			if (trtree_enable_hook_debug)
			{
				ereport(LOG,
						(errmsg("temporal_rtree set_rel_pathlist: Applied cost bias to temporal_rtree index"),
						 errdetail("Original cost estimate biased by factor %.2f", COST_BIAS_FACTOR)));
			}

			hook_stats_path_bias_applied++;
		}
	}
}

/* SQL-visible function: Return hook statistics as a composite type */
Datum
temporal_rtree_hook_stats(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	HeapTuple	tuple;
	Datum		values[5];
	bool		nulls[5] = {false, false, false, false, false};
	AttInMetadata *attinmeta;

	/* Build tuple descriptor for return type */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context "
						"that cannot accept type record")));

	tupdesc = BlessTupleDesc(tupdesc);

	/* Fill in the values */
	values[0] = Int64GetDatum((int64) hook_stats_planner_hits);
	values[1] = Int64GetDatum((int64) hook_stats_planner_rtree_eligible_hits);
	values[2] = Int64GetDatum((int64) hook_stats_executor_dml_hits);
	values[3] = Int64GetDatum((int64) hook_stats_executor_target_with_rtree_hits);
	values[4] = Int64GetDatum((int64) hook_stats_path_bias_applied);

	/* Build and return the tuple */
	tuple = heap_form_tuple(tupdesc, values, nulls);
	return HeapTupleGetDatum(tuple);
}

/* SQL-visible function: Reset all hook statistics */
Datum
temporal_rtree_hook_reset(PG_FUNCTION_ARGS)
{
	hook_stats_planner_hits = 0;
	hook_stats_planner_rtree_eligible_hits = 0;
	hook_stats_executor_dml_hits = 0;
	hook_stats_executor_target_with_rtree_hits = 0;
	hook_stats_path_bias_applied = 0;

	PG_RETURN_VOID();
}

/* Module initialization */
void
_PG_init(void)
{
	/* Register GUCs */
	DefineCustomBoolVariable("temporal_rtree.enable_hook_debug",
							 "Log hook hits for temporal_rtree detection.",
							 NULL,
							 &trtree_enable_hook_debug,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("temporal_rtree.force_rtree_paths",
							 "Bias planner toward temporal_rtree paths (C2 future work).",
							 NULL,
							 &trtree_force_rtree_paths,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("temporal_rtree.log_dml",
							 "Log DML statements targeting temporal_rtree indexes.",
							 NULL,
							 &trtree_log_dml,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	/* Save previous hooks and install ours */
	prev_planner_hook = planner_hook;
	planner_hook = trtree_planner_hook;

	prev_ExecutorStart_hook = ExecutorStart_hook;
	ExecutorStart_hook = trtree_executor_start_hook;

	prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = trtree_set_rel_pathlist_hook;

	ereport(LOG,
			(errmsg("temporal_rtree module initialized with hooks"),
			 errhint("Set GUCs: temporal_rtree.enable_hook_debug, temporal_rtree.force_rtree_paths, temporal_rtree.log_dml")));
}

/* Module cleanup */
void
_PG_fini(void)
{
	/* Restore previous hooks */
	planner_hook = prev_planner_hook;
	ExecutorStart_hook = prev_ExecutorStart_hook;
	set_rel_pathlist_hook = prev_set_rel_pathlist_hook;

	ereport(LOG,
			(errmsg("temporal_rtree module unloaded; hooks restored")));
}
