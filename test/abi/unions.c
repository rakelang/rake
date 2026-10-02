#include "unions.h"
#include <stddef.h>

foreign_value_t union_make_integer(int64_t value)
{
    return (foreign_value_t){ .i64 = value };
}

foreign_value_t union_echo(foreign_value_t value)
{
    return value;
}

static int64_t union_inspect_from_c(const void *context, const foreign_value_t *value)
{
    return value->i64 + *(const int32_t *)context;
}

UnionInspector union_inspector(void)
{
    return union_inspect_from_c;
}

int64_t union_invoke(UnionInspector callback, const void *context, const foreign_value_t *value)
{
    return callback(context, value);
}

/* Independent C definitions check padding, overlapping storage, returned
   aggregates and actual callback calls rather than inspecting generated text. */
int32_t union_abi_test(void)
{
    if (sizeof(foreign_value_t) != 24 || _Alignof(foreign_value_t) != 8
        || offsetof(foreign_value_t, i32) != 0
        || offsetof(foreign_value_t, pair) != 0
        || sizeof(union_envelope_t) != 40
        || offsetof(union_envelope_t, of) != 8
        || offsetof(union_envelope_t, tail) != 32) return 1;
    foreign_value_t value = rake_union_integer(INT64_C(4294967317));
    if (value.i64 != INT64_C(4294967317)) return 2;
    value = rake_union_float();
    if (value.f64 != 1.5) return 3;
    value = rake_union_bytes();
    for (int index = 0; index < 16; ++index)
        if (value.v128[index] != index + 1) return 4;
    value = rake_union_pair();
    if (value.pair.tag != 5 || value.pair.weight != 1.25
        || value.pair.ticks != UINT64_C(4294967327)) return 5;
    union_envelope_t envelope = rake_union_envelope();
    if (envelope.kind != 2 || envelope.of.f64 != 2.5 || envelope.tail != 0xABC) return 6;
    value.i64 = 41;
    int64_t *saved = &value.i64;
    rake_union_mutate(&value);
    if (*saved != 52) return 7;
    if (rake_union_call_c() != INT64_C(4294967317)) return 8;
    if (rake_union_callback(&value) != 124) return 9;
    return 0;
}
