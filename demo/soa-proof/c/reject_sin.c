#include "soa_proof.h"

#include <math.h>

void sin_array_scalar(const float *input, float *output, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    output[i] = sinf(input[i]);
  }
}
