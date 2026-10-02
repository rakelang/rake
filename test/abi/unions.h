#ifndef RAKE_TEST_UNIONS_H
#define RAKE_TEST_UNIONS_H

#include <stdint.h>

typedef struct union_pair_t {
    uint8_t  tag;
    double   weight;
    uint64_t ticks;
} union_pair_t;

typedef union foreign_value_t {
    int32_t      i32;
    int64_t      i64;
    float        f32;
    double       f64;
    void        *address;
    uint8_t      v128[16];
    union_pair_t pair;
} foreign_value_t;

typedef struct union_envelope_t {
    uint8_t         kind;
    foreign_value_t of;
    uint32_t        tail;
} union_envelope_t;

typedef int64_t (*UnionInspector)(const void *, const foreign_value_t *);

foreign_value_t union_make_integer(int64_t);
foreign_value_t union_echo(foreign_value_t);
UnionInspector union_inspector(void);
int64_t union_invoke(UnionInspector, const void *, const foreign_value_t *);
int32_t union_abi_test(void);

foreign_value_t rake_union_integer(int64_t);
foreign_value_t rake_union_float(void);
foreign_value_t rake_union_bytes(void);
foreign_value_t rake_union_pair(void);
union_envelope_t rake_union_envelope(void);
void rake_union_mutate(foreign_value_t *);
int64_t rake_union_call_c(void);
int64_t rake_union_inspect(const void *, const foreign_value_t *);
int64_t rake_union_callback(const foreign_value_t *);

#endif
