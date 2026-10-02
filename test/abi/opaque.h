#ifndef RAKE_OPAQUE_ABI_H
#define RAKE_OPAQUE_ABI_H
#include <stdint.h>
typedef struct opaque_caller opaque_caller;
typedef struct opaque_trap opaque_trap;
typedef opaque_trap *(*opaque_callback)(opaque_caller *, void *);
opaque_trap *run_opaque_callback(opaque_callback, void *);
opaque_trap *trap_for_caller(opaque_caller *);
#endif
