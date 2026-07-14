#include "soa_proof.h"

#include <stdio.h>

typedef void (*advance_kernel)(const float *, const float *, float *, size_t,
                               float);

enum { TEST_CAPACITY = 417 };

static int check_result(const char *kernel_name, const char *alias_name,
                        size_t count, const float *expected,
                        const float *actual) {
  const float error = soa_proof_max_abs_error(expected, actual, count);
  if (error == 0.0f) {
    return 0;
  }

  fprintf(stderr, "%s (%s) failed at count %zu: max error %.9g\n",
          kernel_name, alias_name, count, (double)error);
  return 1;
}

static int check_kernel(advance_kernel kernel, const char *kernel_name) {
  float position[TEST_CAPACITY];
  float velocity[TEST_CAPACITY];
  float expected[TEST_CAPACITY];
  float output[TEST_CAPACITY];
  const float dt = 0.03125f;

  for (size_t count = 0; count <= TEST_CAPACITY; ++count) {
    soa_proof_init(position, velocity, count);
    advance_x_scalar(position, velocity, expected, count, dt);
    kernel(position, velocity, output, count, dt);
    if (check_result(kernel_name, "disjoint", count, expected, output)) {
      return 1;
    }

    soa_proof_init(position, velocity, count);
    kernel(position, velocity, position, count, dt);
    if (check_result(kernel_name, "output==position", count, expected,
                     position)) {
      return 1;
    }

    soa_proof_init(position, velocity, count);
    kernel(position, velocity, velocity, count, dt);
    if (check_result(kernel_name, "output==velocity", count, expected,
                     velocity)) {
      return 1;
    }
  }

  printf("%s: disjoint and exact-alias cases pass for counts 0..%d\n",
         kernel_name, TEST_CAPACITY);
  return 0;
}

int main(void) {
  int failed = check_kernel(advance_x_scalar, "scalar");
  failed |= check_kernel(advance_x_sse2, "sse2");

#if defined(__GNUC__) || defined(__clang__)
  if (__builtin_cpu_supports("avx2")) {
    failed |= check_kernel(advance_x_avx2, "avx2");
  } else {
    puts("avx2: skipped (unsupported by host CPU)");
  }
#endif

  return failed;
}
