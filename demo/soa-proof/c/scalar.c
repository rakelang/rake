#include "soa_proof.h"

void advance_x_scalar(const float *position_x, const float *velocity_x,
                      float *output_x, size_t count, float dt) {
  for (size_t i = 0; i < count; ++i) {
    output_x[i] = position_x[i] + velocity_x[i] * dt;
  }
}
