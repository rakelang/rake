#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${root}/_build/default/src/bin/main.exe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

source_file="${test_dir}/native/add.rk"
"${rakec}" --emit-native-ir --target x86-avx2 "${source_file}" >"${tmp}/add.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/add.s" "${source_file}"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/add.o" "${source_file}"

grep -Fq '%2 : rack<f32> = add %0, %1' "${tmp}/add.native"
grep -Fq 'vaddps ymm0, ymm0, ymm1' "${tmp}/add.s"

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/identity.o" \
  "${test_dir}/native/identity.rk"
objdump -d --no-show-raw-insn "${tmp}/identity.o" | grep -Fq $'\tret'

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/fma.o" \
  "${test_dir}/native/fused_fma.rk"
if [[ "$(objdump -d --no-show-raw-insn "${tmp}/fma.o" | grep -c $'\tvfmadd')" -ne 1 ]]; then
  echo "explicit FMA did not produce exactly one native FMA instruction" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/contracted_fma.rk" >"${tmp}/contracted.native"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/contracted.o" \
  "${test_dir}/native/contracted_fma.rk"
grep -Fq 'rack.fma' "${tmp}/contracted.native"
if grep -Eq ' = (mul|add) ' "${tmp}/contracted.native"; then
  echo "transparent fused alias survived FMA contraction" >&2
  exit 1
fi
if [[ "$(objdump -d --no-show-raw-insn "${tmp}/contracted.o" | grep -c $'\tvfmadd')" -ne 1 ]]; then
  echo "ordinary fused multiply-add graph did not select exactly one native FMA" >&2
  exit 1
fi

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/select.o" \
  "${test_dir}/native/select.rk"

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/scalar_parameter.rk" >"${tmp}/scalar.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/scalar.s" \
  "${test_dir}/native/scalar_parameter.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/scalar.o" \
  "${test_dir}/native/scalar_parameter.rk"
grep -Fq '%3 : rack<f32> = rack.broadcast %1' "${tmp}/scalar.native"
grep -Eq 'vbroadcastss[[:space:]]+ymm[0-9]+,[[:space:]]*xmm1' "${tmp}/scalar.s"
if objdump -d -M intel --no-show-raw-insn "${tmp}/scalar.o" | grep -Eq '\<(call|push|pop)\>'; then
  echo "scalar-parameter crunch introduced a call or stack operation" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/predication.rk" >"${tmp}/predication.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/predication.s" \
  "${test_dir}/native/predication.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/predication.o" \
  "${test_dir}/native/predication.rk"
grep -Fq ' = sanitize ' "${tmp}/predication.native"
grep -Fq 'mask.const false' "${tmp}/predication.native"
grep -Fq 'vblendvps' "${tmp}/predication.s"
if objdump -d -M intel --no-show-raw-insn "${tmp}/predication.o" \
    | grep -Eq '\<(call|push|pop|j[a-z]+|loop)[[:space:]]'; then
  echo "predicated rake introduced a call, stack operation, or lane branch" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/reductions_scans.rk" >"${tmp}/cross-lane.native"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/cross-lane.o" \
  "${test_dir}/native/reductions_scans.rk"
grep -Fq 'rack.reduce.add' "${tmp}/cross-lane.native"
grep -Fq 'rack.scan.max' "${tmp}/cross-lane.native"
objdump -d -M intel --no-show-raw-insn "${tmp}/cross-lane.o" \
  >"${tmp}/cross-lane.dis"
if grep -Eq '\<(vhaddps|call|push|pop)\>|\<(rsp|rbp)\>' "${tmp}/cross-lane.dis"; then
  echo "strict cross-lane lowering introduced reassociation, a call, or stack use" >&2
  exit 1
fi
if [[ "$(sed -n '/<strict_reduce_add>:/,/^$/p' "${tmp}/cross-lane.dis" | grep -c $'\tvaddps')" -ne 7 ]]; then
  echo "strict add reduction did not contain seven ordered additions" >&2
  exit 1
fi
if [[ "$(sed -n '/<strict_scan_add>:/,/^$/p' "${tmp}/cross-lane.dis" | grep -c $'\tvaddps')" -ne 7 ]]; then
  echo "strict add scan did not contain seven ordered additions" >&2
  exit 1
fi

"${root}/_build/default/test/native_expected.exe" \
  "${test_dir}/native/add.rk" "${test_dir}/native/select.rk" \
  "${test_dir}/native/scalar_parameter.rk" \
  "${test_dir}/native/predication.rk" \
  "${test_dir}/native/reductions_scans.rk" \
  >"${tmp}/expected.bits"

cat >"${tmp}/harness.c" <<'EOF'
#include <immintrin.h>
#include <fenv.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern __m256 lowering_add(__m256, __m256);
extern __m256 choose_positive(__m256, __m256);
extern __m256 scale_and_add(__m256, float, __m256);
extern __m256 guarded_partial(__m256, __m256, __m256, __m256, __m256);
extern __m256 overlap_priority_native(__m256);
extern float strict_reduce_add(__m256);
extern float strict_reduce_mul(__m256);
extern float strict_reduce_min(__m256);
extern float strict_reduce_max(__m256);
extern __m256 strict_scan_add(__m256);
extern __m256 strict_scan_mul(__m256);
extern __m256 strict_scan_min(__m256);
extern __m256 strict_scan_max(__m256);

static uint32_t bits(float value) {
  uint32_t result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

static float from_bits(uint32_t value) {
  float result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

int main(int argc, char **argv) {
  if (argc != 2)
    return 100;
  FILE *expected_file = fopen(argv[1], "r");
  if (!expected_file)
    return 101;
  uint32_t expected[76];
  for (int lane = 0; lane < 76; ++lane)
    if (fscanf(expected_file, "%x", &expected[lane]) != 1)
      return 102;
  if (fclose(expected_file) != 0)
    return 103;

  const float left[8] = {-8.0f, -3.5f, -0.0f, 1.0f, 2.5f, 8.0f, 16.0f, 1024.0f};
  const float right[8] = {3.0f, 1.5f, 0.0f, -4.0f, 2.5f, 0.25f, -8.0f, 0.5f};
  float result[8];
  _mm256_storeu_ps(result,
                   lowering_add(_mm256_loadu_ps(left), _mm256_loadu_ps(right)));
  for (int lane = 0; lane < 8; ++lane)
    if (bits(result[lane]) != expected[lane])
      return lane + 1;

  const float values[8] = {-8.0f, 3.5f, -0.0f, 1.0f, -2.5f, 8.0f, -16.0f, 1024.0f};
  const float fallback[8] = {9.0f, 9.0f, 9.0f, 9.0f, 9.0f, 9.0f, 9.0f, 9.0f};
  _mm256_storeu_ps(result,
                   choose_positive(_mm256_loadu_ps(values),
                                   _mm256_loadu_ps(fallback)));
  for (int lane = 0; lane < 8; ++lane)
    if (bits(result[lane]) != expected[lane + 8])
      return lane + 9;

  _mm256_storeu_ps(result,
                   scale_and_add(_mm256_loadu_ps(left), 0.5f,
                                 _mm256_loadu_ps(right)));
  for (int lane = 0; lane < 8; ++lane)
    if (bits(result[lane]) != expected[lane + 16])
      return lane + 17;

  const float selector[8] = {1.0f, -1.0f, 1.0f, -1.0f, 1.0f, -1.0f, 1.0f, -1.0f};
  float guarded_x[8] = {4.0f, -1.0f, 9.0f, FLT_MAX, 16.0f, 0.0f, 25.0f, -4.0f};
  const float denominator[8] = {2.0f, 0.0f, 3.0f, 0.0f, 4.0f, 0.0f, 5.0f, 0.0f};
  const float multiplier[8] = {1.0f, INFINITY, 1.0f, INFINITY, 1.0f, INFINITY, 1.0f, INFINITY};
  const float addend[8] = {0.0f, -INFINITY, 0.0f, -INFINITY, 0.0f, -INFINITY, 0.0f, -INFINITY};
  guarded_x[5] = from_bits(0x7f800001u);
  feclearexcept(FE_ALL_EXCEPT);
  _mm256_storeu_ps(result,
                   guarded_partial(_mm256_loadu_ps(selector),
                                   _mm256_loadu_ps(guarded_x),
                                   _mm256_loadu_ps(denominator),
                                   _mm256_loadu_ps(multiplier),
                                   _mm256_loadu_ps(addend)));
  if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW) != 0)
    return 50;
  for (int lane = 0; lane < 8; ++lane)
    if (bits(result[lane]) != expected[lane + 24])
      return lane + 25;

  float overlap[8] = {-1.0f, 0.0f, 1.0f, NAN, -0.0f, 5.0f, -5.0f, NAN};
  _mm256_storeu_ps(result, overlap_priority_native(_mm256_loadu_ps(overlap)));
  for (int lane = 0; lane < 8; ++lane)
    if (bits(result[lane]) != expected[lane + 32])
      return lane + 33;

  const float reduce_add_input[8] = {16777216.0f, 1.0f, -16777216.0f, 1.0f,
                                     2.0f, 3.0f, 4.0f, 5.0f};
  const float reduce_mul_input[8] = {1.5f, 2.0f, 0.5f, -1.0f,
                                     2.0f, 0.25f, 4.0f, 1.0f};
  const float extrema_input[8] = {3.0f, 0.0f, -0.0f, 5.0f,
                                  NAN, INFINITY, -INFINITY, 2.0f};
  const __m256 add_rack = _mm256_loadu_ps(reduce_add_input);
  const __m256 mul_rack = _mm256_loadu_ps(reduce_mul_input);
  const __m256 extrema_rack = _mm256_loadu_ps(extrema_input);
  const float reductions[4] = {
      strict_reduce_add(add_rack), strict_reduce_mul(mul_rack),
      strict_reduce_min(extrema_rack), strict_reduce_max(extrema_rack)};
  for (int index = 0; index < 4; ++index)
    if (bits(reductions[index]) != expected[40 + index])
      return 60 + index;

  const __m256 scans[4] = {
      strict_scan_add(add_rack), strict_scan_mul(mul_rack),
      strict_scan_min(extrema_rack), strict_scan_max(extrema_rack)};
  for (int scan = 0; scan < 4; ++scan) {
    _mm256_storeu_ps(result, scans[scan]);
    for (int lane = 0; lane < 8; ++lane)
      if (bits(result[lane]) != expected[44 + scan * 8 + lane])
        return 70 + scan * 8 + lane;
  }
  return 0;
}
EOF

cc -mavx2 -mfma "${tmp}/harness.c" "${tmp}/add.o" "${tmp}/select.o" \
  "${tmp}/scalar.o" \
  "${tmp}/predication.o" "${tmp}/cross-lane.o" -lm \
  -o "${tmp}/native-kernels"
"${tmp}/native-kernels" "${tmp}/expected.bits"

if "${rakec}" --emit-asm --target scalar "${source_file}" >"${tmp}/bad.out" 2>"${tmp}/bad.err"; then
  echo "scalar profile unexpectedly reached the AVX2 production backend" >&2
  exit 1
fi
grep -Fq "profile 'scalar' has no production backend yet" "${tmp}/bad.err"

echo "native backend CLI and semantic differential runtime test passed"
