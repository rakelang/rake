#include "soa_proof.h"

#include <immintrin.h>
#include <stdint.h>

void advance_x_avx512(const float *position_x, const float *velocity_x,
                      float *output_x, size_t count, float dt) {
  const __m512 dt_vector = _mm512_set1_ps(dt);
  size_t i = 0;

  for (; count - i >= 16; i += 16) {
    const __m512 position = _mm512_loadu_ps(position_x + i);
    const __m512 velocity = _mm512_loadu_ps(velocity_x + i);
    const __m512 displacement = _mm512_mul_ps(velocity, dt_vector);
    _mm512_storeu_ps(output_x + i, _mm512_add_ps(position, displacement));
  }

  if (i < count) {
    const unsigned remaining = (unsigned)(count - i);
    const __mmask16 mask = (__mmask16)((UINT32_C(1) << remaining) - 1U);
    const __m512 position = _mm512_maskz_loadu_ps(mask, position_x + i);
    const __m512 velocity = _mm512_maskz_loadu_ps(mask, velocity_x + i);
    const __m512 displacement = _mm512_mul_ps(velocity, dt_vector);
    const __m512 result = _mm512_add_ps(position, displacement);
    _mm512_mask_storeu_ps(output_x + i, mask, result);
  }
}
