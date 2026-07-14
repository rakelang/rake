#include "soa_proof.h"

#include <math.h>
#include <stdint.h>

static uint32_t mix32(uint32_t value) {
  value ^= value >> 16;
  value *= UINT32_C(0x7feb352d);
  value ^= value >> 15;
  value *= UINT32_C(0x846ca68b);
  value ^= value >> 16;
  return value;
}

static float signed_unit(uint32_t value) {
  const int32_t centered = (int32_t)(mix32(value) & UINT32_C(0xffff)) - 32768;
  return (float)centered * (1.0f / 32768.0f);
}

void soa_proof_init(float *position_x, float *velocity_x, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    const uint32_t index = (uint32_t)i;
    position_x[i] = signed_unit(index + UINT32_C(0x12345678)) * 1000.0f;
    velocity_x[i] = signed_unit(index + UINT32_C(0x9abcdef0)) * 25.0f;
  }
}

void soa_proof_init_pressure(
    float *streams[static SOA_PROOF_PRESSURE_STREAMS], size_t count) {
  for (size_t stream = 0; stream < SOA_PROOF_PRESSURE_STREAMS; ++stream) {
    for (size_t i = 0; i < count; ++i) {
      streams[stream][i] =
          signed_unit((uint32_t)i + (uint32_t)(stream * UINT32_C(0x10001)));
    }
  }
}

double soa_proof_checksum(const float *values, size_t count) {
  double checksum = 0.0;
  for (size_t i = 0; i < count; ++i) {
    checksum += (double)values[i] * (double)((i % 251U) + 1U);
  }
  return checksum;
}

float soa_proof_max_abs_error(const float *expected, const float *actual,
                              size_t count) {
  float maximum = 0.0f;
  for (size_t i = 0; i < count; ++i) {
    const float error = fabsf(expected[i] - actual[i]);
    if (error > maximum) {
      maximum = error;
    }
  }
  return maximum;
}
