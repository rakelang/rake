#include <fenv.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef float rack __attribute__((vector_size(16)));

extern rack lowering_add(rack, rack);
extern rack choose_positive(rack, rack);
extern rack scale_and_add(rack, float, rack);
extern rack fused_madd(rack, rack, rack);
extern rack guarded_partial(rack, rack, rack, rack, rack);
extern rack overlap_priority_native(rack);

static uint32_t bits(float value) {
  uint32_t result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

#define LANES 4
static rack load(const float *values) { rack result; memcpy(&result, values, sizeof result); return result; }
static void store(float *values, rack result) { memcpy(values, &result, sizeof result); }
#include "global_tines_oracle.h"
#include "quiet_comparisons_oracle.h"
#include "absolute_oracle.h"
#include "extrema_oracle.h"
#include "rounding_oracle.h"
#include "reductions_oracle.h"

static float from_bits(uint32_t value) {
  float result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

static int check(rack actual, const uint32_t *expected, int base) {
  float lanes[4];
  memcpy(lanes, &actual, sizeof(lanes));
  for (int lane = 0; lane < 4; ++lane)
    if (bits(lanes[lane]) != expected[lane])
      return base + lane;
  return 0;
}

int main(int argc, char **argv) {
  int global_failure = check_global_tines();
  if (global_failure) return global_failure;
  int comparison_failure = check_quiet_comparisons();
  if (comparison_failure) return comparison_failure;
  int absolute_failure = check_absolute_values();
  if (absolute_failure) return absolute_failure;
  int extrema_failure = check_extrema();
  if (extrema_failure) return extrema_failure;
  int rounding_failure = check_rounding();
  if (rounding_failure) return rounding_failure;
  int fold_failure = check_reductions_and_scans();
  if (fold_failure) return fold_failure;
  if (argc != 2)
    return 100;
  FILE *file = fopen(argv[1], "r");
  if (!file)
    return 101;
  uint32_t expected[24];
  for (int lane = 0; lane < 24; ++lane)
    if (fscanf(file, "%x", &expected[lane]) != 1)
      return 102;
  if (fclose(file) != 0)
    return 103;

  rack left = {-8.0f, -3.5f, -0.0f, 1024.0f};
  rack right = {3.0f, 1.5f, 0.0f, 0.5f};
  int failure = check(lowering_add(left, right), expected, 1);
  if (failure)
    return failure;

  rack values = {-8.0f, 3.5f, -0.0f, 1024.0f};
  rack fallback = {9.0f, 9.0f, 9.0f, 9.0f};
  failure = check(choose_positive(values, fallback), expected + 4, 5);
  if (failure)
    return failure;

  failure = check(scale_and_add(left, 0.5f, right), expected + 8, 9);
  if (failure)
    return failure;

  rack fma_a = {1.0000001192092896f, -3.5f, 16.0f, -0.0f};
  rack fma_b = {1.0000001192092896f, 2.0f, 0.25f, 8.0f};
  rack fma_c = {-1.000000238418579f, 7.0f, -4.0f, 0.0f};
  failure = check(fused_madd(fma_a, fma_b, fma_c), expected + 12, 13);
  if (failure)
    return failure;

  rack selector = {1.0f, -1.0f, 1.0f, -1.0f};
  rack guarded_x = {4.0f, -1.0f, 9.0f, FLT_MAX};
  rack denominator = {2.0f, 0.0f, 3.0f, 0.0f};
  rack multiplier = {1.0f, INFINITY, 1.0f, INFINITY};
  rack addend = {0.0f, -INFINITY, 0.0f, -INFINITY};
  guarded_x[1] = from_bits(0x7f800001u);
  feclearexcept(FE_ALL_EXCEPT);
  rack guarded = guarded_partial(selector, guarded_x, denominator, multiplier, addend);
  if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW) != 0)
    return 50;
  failure = check(guarded, expected + 16, 17);
  if (failure)
    return failure;

  rack overlap = {-1.0f, 0.0f, 1.0f, NAN};
  failure = check(overlap_priority_native(overlap), expected + 20, 21);
  return failure;
}
