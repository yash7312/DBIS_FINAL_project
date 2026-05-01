MODULE_big = temporal_rtree
OBJS = temporal_rtree_handler.o temporal_rtree_page.o temporal_rtree_build.o \
       temporal_rtree_split.o temporal_rtree_insert.o temporal_rtree_search.o \
       temporal_rtree_wal.o temporal_rtree_vacuum.o temporal_rtree_cost.o \
       temporal_rtree_hooks.o
.DEFAULT_GOAL := all
EXTENSION = temporal_rtree
DATA = temporal_rtree--1.0.sql
REGRESS = temporal_rtree_smoke temporal_rtree_plans \
          temporal_rtree_hooks temporal_rtree_hook_planner temporal_rtree_hook_executor temporal_rtree_hook_presence \
          temporal_rtree_path_bias
ISOLATION = temporal_rtree_concurrent_split
PG_CPPFLAGS += -I$(top_srcdir)/contrib/cube

.PHONY: crash-restart-check
crash-restart-check: ; bash temporal_rtree_crash_restart.sh

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
