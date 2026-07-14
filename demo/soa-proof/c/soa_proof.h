#ifndef RAKE_DEMO_SOA_PROOF_C_SOA_PROOF_H
#define RAKE_DEMO_SOA_PROOF_C_SOA_PROOF_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SOA_PROOF_DEFAULT_COUNT ((size_t)400)
#define SOA_PROOF_PRESSURE_STREAMS 24

/* All advance kernels implement out[i] = position_x[i] + velocity_x[i] * dt.
 * output_x may exactly alias either input array, or all arrays must be
 * disjoint; partial overlap is outside the API contract.  Each SIMD chunk
 * loads both inputs before storing its output.  FP contraction should be
 * disabled when compiling these files so that every implementation has
 * separate-rounding multiply/add semantics.
 */
void advance_x_scalar(const float *position_x, const float *velocity_x,
                      float *output_x, size_t count, float dt);
void advance_x_sse2(const float *position_x, const float *velocity_x,
                    float *output_x, size_t count, float dt);
void advance_x_avx2(const float *position_x, const float *velocity_x,
                    float *output_x, size_t count, float dt);
void advance_x_avx512(const float *position_x, const float *velocity_x,
                      float *output_x, size_t count, float dt);

/* Primary negative comparison: ordinary strict C accepts a scalar library
 * call per element even though the loop has no portable SIMD sin operation.
 */
/* output may exactly alias input; partial overlap is outside the contract. */
void sin_array_scalar(const float *input, float *output, size_t count);

/* Secondary stress kernel: twenty-four loop-carried vector accumulators
 * intentionally exceed the sixteen-vector-register AVX2 register file.  This
 * is useful for assembly/spill inspection but is not the fair rejection case.
 */
float pressure_sum_avx2(
    const float *restrict streams[restrict static SOA_PROOF_PRESSURE_STREAMS],
    size_t count);

void soa_proof_init(float *position_x, float *velocity_x, size_t count);
void soa_proof_init_pressure(
    float *streams[static SOA_PROOF_PRESSURE_STREAMS], size_t count);
double soa_proof_checksum(const float *values, size_t count);
float soa_proof_max_abs_error(const float *expected, const float *actual,
                              size_t count);

#ifdef __cplusplus
}
#endif

#endif
