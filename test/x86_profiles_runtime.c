/* The same ABI and scalar reference calculation at each physical rack width. */
#include <immintrin.h>
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if LANES == 4
typedef __m128 rack;
#define load _mm_loadu_ps
#define store _mm_storeu_ps
#elif LANES == 8
typedef __m256 rack;
#define load _mm256_loadu_ps
#define store _mm256_storeu_ps
#elif LANES == 16
typedef __m512 rack;
#define load _mm512_loadu_ps
#define store _mm512_storeu_ps
#endif

extern rack lowering_add(rack, rack);
extern rack choose_positive(rack, rack);
extern rack scale_and_add(rack, float, rack);
extern rack guarded_roots(rack);
extern rack ordered_difference(rack, rack);
extern float strict_reduce_add(rack);
extern float strict_reduce_mul(rack);
extern float strict_reduce_min(rack);
extern float strict_reduce_max(rack);
extern rack strict_scan_add(rack);
extern rack strict_scan_mul(rack);
extern rack strict_scan_min(rack);
extern rack strict_scan_max(rack);

static uint32_t bits(float value) {
    uint32_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

#include "global_tines_oracle.h"
#include "quiet_comparisons_oracle.h"

static int equal(float actual, float expected) {
    return (isnan(actual) && isnan(expected)) || bits(actual) == bits(expected);
}

/* The language's strict extrema propagate NaN and distinguish signed zeros. */
static float extreme(float a, float b, int maximum) {
    if (isnan(a) || isnan(b)) return NAN;
    if (a == 0 && b == 0)
        return maximum ? (signbit(a) && signbit(b) ? -0.0f : 0.0f)
                       : (signbit(a) || signbit(b) ? -0.0f : 0.0f);
    return maximum ? (a > b ? a : b) : (a < b ? a : b);
}

int main(void) {
    int failure = check_global_tines();
    if (failure) return failure;
    failure = check_quiet_comparisons();
    if (failure) return failure;
    const float a_seed[] = {16777216, 1, -16777216, 1, 2, 3, 4, 5};
    const float b_seed[] = {2, -1, 0, 3, -2, 0.5f, 1, -4};
    float a[LANES], b[LANES], result[LANES];
    for (int i = 0; i < LANES; i++) {
        a[i] = a_seed[i % 8];
        b[i] = b_seed[i % 8];
    }
    store(result, lowering_add(load(a), load(b)));
    for (int i = 0; i < LANES; i++) if (!equal(result[i], a[i] + b[i])) return 1;
    store(result, choose_positive(load(a), load(b)));
    for (int i = 0; i < LANES; i++) if (!equal(result[i], a[i] > 0 ? a[i] : b[i])) return 2;
    store(result, scale_and_add(load(a), 0.5f, load(b)));
    for (int i = 0; i < LANES; i++) if (!equal(result[i], a[i] * 0.5f + b[i])) return 3;

    for (int i = 0; i < LANES; i++) a[i] = i % 2 ? -4 : 16;
    feclearexcept(FE_ALL_EXCEPT);
    store(result, guarded_roots(load(a)));
    if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) return 4;
    for (int i = 0; i < LANES; i++) if (!equal(result[i], i % 2 ? -2 : 4)) return 5;

    for (int i = 0; i < LANES; i++) { a[i] = i % 2 ? NAN : i; b[i] = i % 3 ? i : -1; }
    store(result, ordered_difference(load(a), load(b)));
    for (int i = 0; i < LANES; i++)
        if (!equal(result[i], !isnan(a[i]) && !isnan(b[i]) && a[i] != b[i] ? 1 : 0)) return 6;

    for (int op = 0; op < 4; op++) {
        for (int i = 0; i < LANES; i++)
            a[i] = op == 0 ? a_seed[i % 8] : op == 1 ? b_seed[i % 8] : i % 2 ? -0.0f : 0.0f;
        for (int scenario = 0; scenario < (op >= 2 ? 2 : 1); scenario++) {
            if (scenario) a[LANES - 1] = NAN;
            rack input = load(a);
            float reduced = op == 0 ? strict_reduce_add(input) : op == 1 ? strict_reduce_mul(input)
                            : op == 2 ? strict_reduce_min(input) : strict_reduce_max(input);
            rack scanned = op == 0 ? strict_scan_add(input) : op == 1 ? strict_scan_mul(input)
                           : op == 2 ? strict_scan_min(input) : strict_scan_max(input);
            store(result, scanned);
            volatile float prefix = a[0];
            for (int i = 0; i < LANES; i++) {
                if (i) prefix = op == 0 ? prefix + a[i] : op == 1 ? prefix * a[i]
                                : extreme(prefix, a[i], op == 3);
                if (!equal(result[i], prefix)) return 7 + op;
            }
            if (!equal(reduced, prefix)) return 11 + op;
        }
    }
    printf("x86 runtime agreement: %d lanes\n", LANES);
    return 0;
}
