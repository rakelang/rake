#include "reject_register_pressure_avx2.h"

__m256 reject_register_pressure_avx2(__m256 a, __m256 b, __m256 c, __m256 d,
                                    __m256 e, __m256 f, __m256 g, __m256 h) {
  const __m256 t0 = _mm256_add_ps(a, b);
  const __m256 t1 = _mm256_add_ps(a, b);
  const __m256 t2 = _mm256_add_ps(a, b);
  const __m256 t3 = _mm256_add_ps(a, b);
  const __m256 t4 = _mm256_add_ps(a, b);
  const __m256 t5 = _mm256_add_ps(a, b);
  const __m256 t6 = _mm256_add_ps(a, b);
  const __m256 t7 = _mm256_add_ps(a, b);
  const __m256 t8 = _mm256_add_ps(a, b);

  __m256 sum = t0;
  sum = _mm256_add_ps(sum, t1);
  sum = _mm256_add_ps(sum, t2);
  sum = _mm256_add_ps(sum, t3);
  sum = _mm256_add_ps(sum, t4);
  sum = _mm256_add_ps(sum, t5);
  sum = _mm256_add_ps(sum, t6);
  sum = _mm256_add_ps(sum, t7);
  sum = _mm256_add_ps(sum, t8);
  sum = _mm256_add_ps(sum, a);
  sum = _mm256_add_ps(sum, b);
  sum = _mm256_add_ps(sum, c);
  sum = _mm256_add_ps(sum, d);
  sum = _mm256_add_ps(sum, e);
  sum = _mm256_add_ps(sum, f);
  sum = _mm256_add_ps(sum, g);
  return _mm256_add_ps(sum, h);
}
