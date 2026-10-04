#include <immintrin.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

extern __m256 bounded_sine(__m256);

static inline float bounded_sine_c(float value) {
    const float square = value * value;
    const float fifth = 0.0000027557319223985893f * square - 0.0001984126984126984f;
    const float fourth = fifth * square + 0.008333333333333333f;
    const float third = fourth * square - 0.16666666666666666f;
    const float second = third * square + 1.0f;
    return value * second;
}

void bounded_sine_column_c(const float *values, float *output, size_t count) {
    for (size_t i = 0; i < count; ++i)
        output[i] = bounded_sine_c(values[i]);
}

int main(void) {
    const size_t count = 8000;
    float values[8000], c_results[8000];
    for (size_t i = 0; i < count; ++i)
        values[i] = (float)i / (float)(count - 1) - 0.5f;
    bounded_sine_column_c(values, c_results, count);
    float c_error = 0.0f, rake_error = 0.0f;
    for (size_t i = 0; i < count; i += 8) {
        float results[8];
        _mm256_storeu_ps(results, bounded_sine(_mm256_loadu_ps(values + i)));
        for (size_t lane = 0; lane < 8; ++lane) {
            const float reference = sinf(values[i + lane]);
            const float c_difference = fabsf(c_results[i + lane] - reference);
            const float rake_difference = fabsf(results[lane] - reference);
            if (c_difference > 0.0000001f || rake_difference > 0.0000001f ||
                !isfinite(results[lane]) || !isfinite(c_results[i + lane])) abort();
            if (c_difference > c_error) c_error = c_difference;
            if (rake_difference > rake_error) rake_error = rake_difference;
        }
    }
    printf("bounded_sine\tcount=%zu\tdomain=[-0.5,0.5]\tc_max_abs_error=%.9g\trake_max_abs_error=%.9g\n",
        count, (double)c_error, (double)rake_error);
    return 0;
}
