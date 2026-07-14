#include "soa_proof.h"

#include <immintrin.h>

void advance_x_avx2(const float *position_x, const float *velocity_x,
                    float *output_x, size_t count, float dt) {
  const __m256 dt_vector = _mm256_set1_ps(dt);
  size_t i = 0;

  for (; count - i >= 8; i += 8) {
    const __m256 position = _mm256_loadu_ps(position_x + i);
    const __m256 velocity = _mm256_loadu_ps(velocity_x + i);
    const __m256 displacement = _mm256_mul_ps(velocity, dt_vector);
    _mm256_storeu_ps(output_x + i, _mm256_add_ps(position, displacement));
  }

  for (; i < count; ++i) {
    output_x[i] = position_x[i] + velocity_x[i] * dt;
  }
}
