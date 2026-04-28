#include "postgres.h"
#include "temporal_rtree.h"
#include <float.h>
#include "utils/float.h"

/* helper: width in time dimension (treat upper-inf specially) */
static double
width_time(const RTreeTemporalBox *b)
{
    if (b->flags & TRTREE_FLAG_EMPTY)
        return 0.0;
    if (b->flags & TRTREE_FLAG_UPPER_INF)
        return (double) PG_INT64_MAX - (double) b->lower_us;
    return (double) (b->upper_us - b->lower_us);
}

static double
width_attr(const RTreeTemporalBox *b)
{
    if (b->dims < 2)
        return 0.0;
    return (double) (b->attr_hi - b->attr_lo);
}

RTreeTemporalBox
tr_union(const RTreeTemporalBox *a, const RTreeTemporalBox *b)
{
    RTreeTemporalBox u;

    if (a->flags & TRTREE_FLAG_EMPTY)
        return *b;
    if (b->flags & TRTREE_FLAG_EMPTY)
        return *a;

    u.dims = Max(a->dims, b->dims);
    u.flags = (a->flags | b->flags) & ~(TRTREE_FLAG_EMPTY);
    u.lower_us = Min(a->lower_us, b->lower_us);
    u.upper_us = Max(a->upper_us, b->upper_us);
    u.attr_lo = Min(a->attr_lo, b->attr_lo);
    u.attr_hi = Max(a->attr_hi, b->attr_hi);

    /* if either had upper-inf, mark union upper-inf */
    if ((a->flags & TRTREE_FLAG_UPPER_INF) || (b->flags & TRTREE_FLAG_UPPER_INF))
        u.flags |= TRTREE_FLAG_UPPER_INF;

    return u;
}

double
tr_penalty(const RTreeTemporalBox *child, const RTreeTemporalBox *newb, double w_attr, double w_current)
{
    RTreeTemporalBox ext = tr_union(child, newb);
    double time_enlargement = width_time(&ext) - width_time(child);
    double attr_enlargement = width_attr(&ext) - width_attr(child);

    bool child_current = (child->flags & TRTREE_FLAG_UPPER_INF) != 0;
    bool new_current = (newb->flags & TRTREE_FLAG_UPPER_INF) != 0;

    if (child_current != new_current)
    {
        /* bias separation of current vs history */
        return DBL_MAX / 4.0;
    }

    if (child_current && new_current)
    {
        double d = fabs((double) (newb->lower_us - child->lower_us));
        return d * w_current;
    }

    return time_enlargement + attr_enlargement * w_attr;
}

/* Simple picksplit: choose seed pair with max wasted area and greedily assign */
int
tr_picksplit(RTreeTemporalBox *items, int nitems, int *left_idxs, int *nleft, int *right_idxs, int *nright)
{
    int i, j;
    double best_waste;
    int seed1, seed2;
    RTreeTemporalBox u;
    double waste;
    RTreeTemporalBox left_union;
    RTreeTemporalBox right_union;
    double pen_l, pen_r;

    if (nitems <= 0)
    {
        *nleft = *nright = 0;
        return 0;
    }

    best_waste = -1.0;
    seed1 = 0;
    seed2 = 0;

    /* pick seeds */
    for (i = 0; i < nitems; i++)
    {
        for (j = i + 1; j < nitems; j++)
        {
            u = tr_union(&items[i], &items[j]);
            waste = width_time(&u) * (1.0 + width_attr(&u)) -
                (width_time(&items[i]) * (1.0 + width_attr(&items[i]))) -
                (width_time(&items[j]) * (1.0 + width_attr(&items[j])));
            if (waste > best_waste)
            {
                best_waste = waste;
                seed1 = i;
                seed2 = j;
            }
        }
    }

    /* initialize */
    *nleft = *nright = 0;
    left_idxs[(*nleft)++] = seed1;
    right_idxs[(*nright)++] = seed2;

    /* track unions */
    left_union = items[seed1];
    right_union = items[seed2];

    /* assign remaining */
    for (i = 0; i < nitems; i++)
    {
        if (i == seed1 || i == seed2)
            continue;
        pen_l = tr_penalty(&left_union, &items[i], 1.0, 1.0);
        pen_r = tr_penalty(&right_union, &items[i], 1.0, 1.0);
        if (pen_l < pen_r)
        {
            left_idxs[(*nleft)++] = i;
            left_union = tr_union(&left_union, &items[i]);
        }
        else
        {
            right_idxs[(*nright)++] = i;
            right_union = tr_union(&right_union, &items[i]);
        }
    }

    return 0;
}
