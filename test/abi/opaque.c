#include "opaque.h"
#include <stddef.h>
/* Only the independent C translation unit sees the real object layouts. */
struct opaque_caller { int32_t value; };
struct opaque_trap { int32_t value; };
static opaque_trap trap = { 37 };
opaque_trap *run_opaque_callback(opaque_callback callback, void *state) {
    opaque_caller caller = { 19 };
    return callback(&caller, state);
}
opaque_trap *trap_for_caller(opaque_caller *caller) {
    return caller->value == 19 ? &trap : NULL;
}
extern opaque_trap *opaque_result(void);
int main(void) {
    return opaque_result() == &trap ? 0 : 1;
}
