#include "soa_proof.h"

#include <emmintrin.h>

void advance_x_sse2(const float *position_x, const float *velocity_x,
                    float *output_x, size_t count, float dt) {
  const __m128 dt_vector = _mm_set1_ps(dt);
  size_t i = 0;

  for (; count - i >= 4; i += 4) {
    const __m128 position = _mm_loadu_ps(position_x + i);
    const __m128 velocity = _mm_loadu_ps(velocity_x + i);
    const __m128 displacement = _mm_mul_ps(velocity, dt_vector);
    _mm_storeu_ps(output_x + i, _mm_add_ps(position, displacement));
  }

  for (; i < count; ++i) {
    output_x[i] = position_x[i] + velocity_x[i] * dt;
  }
}
