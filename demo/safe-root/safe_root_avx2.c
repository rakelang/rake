#include <immintrin.h>
#include <stddef.h>

static __m256 safe_root_rack(__m256 value) {
    const __m256 zero = _mm256_setzero_ps();
    const __m256 valid = _mm256_cmp_ps(value, zero, _CMP_GE_OQ);
    const __m256 input = _mm256_and_ps(valid, value);
    return _mm256_and_ps(valid, _mm256_sqrt_ps(input));
}

void safe_root_avx2(const float *values, float *roots, size_t count) {
    size_t i = 0;
    for (; count - i >= 8; i += 8) {
        const __m256 value = _mm256_loadu_ps(values + i);
        _mm256_storeu_ps(roots + i, safe_root_rack(value));
    }
    if (i < count) {
        const __m256i lanes = _mm256_setr_epi32(0, 1, 2, 3, 4, 5, 6, 7);
        const __m256i remaining = _mm256_set1_epi32((int)(count - i));
        const __m256i active = _mm256_cmpgt_epi32(remaining, lanes);
        const __m256 value = _mm256_maskload_ps(values + i, active);
        _mm256_maskstore_ps(roots + i, active, safe_root_rack(value));
    }
}
