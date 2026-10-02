#include <math.h>
#include <stddef.h>

void safe_root_c(const float *values, float *roots, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        if (values[i] >= 0.0f)
            roots[i] = sqrtf(values[i]);
        else
            roots[i] = 0.0f;
    }
}
