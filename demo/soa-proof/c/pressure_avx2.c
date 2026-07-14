#include "soa_proof.h"

#include <immintrin.h>

float pressure_sum_avx2(
    const float *restrict streams[restrict static SOA_PROOF_PRESSURE_STREAMS],
    size_t count) {
  __m256 sums[SOA_PROOF_PRESSURE_STREAMS];
  for (size_t stream = 0; stream < SOA_PROOF_PRESSURE_STREAMS; ++stream) {
    sums[stream] = _mm256_setzero_ps();
  }

  size_t i = 0;
  for (; count - i >= 8; i += 8) {
    /* Every sum is loop-carried and therefore live across the loop backedge. */
    for (size_t stream = 0; stream < SOA_PROOF_PRESSURE_STREAMS; ++stream) {
      const __m256 input = _mm256_loadu_ps(streams[stream] + i);
      sums[stream] = _mm256_add_ps(sums[stream], input);
    }
  }

  __m256 total = _mm256_setzero_ps();
  for (size_t stream = 0; stream < SOA_PROOF_PRESSURE_STREAMS; ++stream) {
    total = _mm256_add_ps(total, sums[stream]);
  }

  const __m128 low = _mm256_castps256_ps128(total);
  const __m128 high = _mm256_extractf128_ps(total, 1);
  __m128 folded = _mm_add_ps(low, high);
  folded = _mm_hadd_ps(folded, folded);
  folded = _mm_hadd_ps(folded, folded);
  float result = _mm_cvtss_f32(folded);

  for (; i < count; ++i) {
    for (size_t stream = 0; stream < SOA_PROOF_PRESSURE_STREAMS; ++stream) {
      result += streams[stream][i];
    }
  }
  return result;
}
