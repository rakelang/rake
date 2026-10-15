/* Runs the independently specified oracles in the *_oracle.h headers against
   one native profile's objects. LANES selects the rack width; the vector
   extension type takes the platform's vector-register ABI on every profile. */
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef float rack __attribute__((vector_size(LANES * sizeof(float))));

static rack load(const float *values) {
    rack result;
    memcpy(&result, values, sizeof result);
    return result;
}

static void store(float *values, rack result) {
    memcpy(values, &result, sizeof result);
}

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

int main(void) {
    int (*const oracles[])(void) = {
        check_global_tines, check_quiet_comparisons, check_absolute_values,
        check_extrema,      check_rounding,          check_reductions_and_scans,
    };
    for (size_t index = 0; index < sizeof oracles / sizeof oracles[0]; ++index) {
        const int failure = oracles[index]();
        if (failure) {
            fprintf(stderr, "oracle %zu failed with %d\n", index, failure);
            return failure;
        }
    }
    printf("native oracle agreement: %d lanes\n", LANES);
    return 0;
}
