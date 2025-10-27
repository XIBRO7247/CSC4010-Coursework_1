#include <omp.h>

/* Baked schedule shim.
   build.sh may pass:
     -DFIX_KIND_static | -DFIX_KIND_dynamic | -DFIX_KIND_guided | -DFIX_KIND_auto
     and optionally -DFIX_CHUNK=NN
*/
static void _apply_baked_omp_schedule(void) {
#if defined(FIX_KIND_static) || defined(FIX_KIND_dynamic) || defined(FIX_KIND_guided) || defined(FIX_KIND_auto)
    omp_sched_t kind =
    #if defined(FIX_KIND_static)
        omp_sched_static;
#elif defined(FIX_KIND_dynamic)
            omp_sched_dynamic;
#elif defined(FIX_KIND_guided)
                omp_sched_guided;
#else
                    omp_sched_auto;
#endif

#ifdef FIX_CHUNK
    int chunk = FIX_CHUNK;
#else
    int chunk = 0;  // runtime default
#endif

    omp_set_schedule(kind, chunk);
#else
    /* No baked kind provided → no-op */
    (void)0;
#endif
}

__attribute__((constructor))
static void _init_sched_ctor(void) {
    _apply_baked_omp_schedule();
}
