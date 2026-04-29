MODULE_big = temporal_rtree
OBJS = temporal_rtree_handler.o temporal_rtree_page.o temporal_rtree_build.o \
       temporal_rtree_split.o temporal_rtree_insert.o temporal_rtree_search.o \
       temporal_rtree_wal.o temporal_rtree_vacuum.o temporal_rtree_cost.o
EXTENSION = temporal_rtree
DATA = temporal_rtree--1.0.sql
REGRESS = temporal_rtree_smoke temporal_rtree_plans
ISOLATION = temporal_rtree_concurrent_split
PG_CPPFLAGS += -I$(top_srcdir)/contrib/cube

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
