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

static uint32_t bits(float value) {
    uint32_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

#include "global_tines_oracle.h"
#include "quiet_comparisons_oracle.h"
#include "absolute_oracle.h"
#include "extrema_oracle.h"
#include "rounding_oracle.h"
#include "reductions_oracle.h"

static int equal(float actual, float expected) {
    return (isnan(actual) && isnan(expected)) || bits(actual) == bits(expected);
}

int main(void) {
    int failure = check_global_tines();
    if (failure) return failure;
    failure = check_quiet_comparisons();
    if (failure) return failure;
    failure = check_absolute_values();
    if (failure) return failure;
    failure = check_extrema();
    if (failure) return failure;
    failure = check_rounding();
    if (failure) return failure;
    failure = check_reductions_and_scans();
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

    printf("x86 runtime agreement: %d lanes\n", LANES);
    return 0;
}
