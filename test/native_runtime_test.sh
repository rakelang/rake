#!/usr/bin/env bash
# Compiled kernels must agree with Rake's reference interpreter, bit for bit,
# on every runtime profile, and with the independent C oracles on every
# physical profile. One case table, test/native/reference_cases.tsv, serves all
# of them; test/reference_harness.ml turns it into a C harness for each profile.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
harness="${root}/_build/default/test/reference_harness.exe"
cases="${root}/test/native/reference_cases.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
source "${root}/test/profile.sh"

reference_fixtures=(add select scalar_parameter fused_fma contracted_fma predication
  reductions_scans absolute extrema rounding global_tines multiple_through
  integer_folds uniform_arithmetic bitcast)
oracle_fixtures=(select absolute extrema rounding reductions_scans global_tines)

# SSE2 and WebAssembly have no single-rounding fused multiply-add, and their
# guarded_partial lowering is not yet available. A shuffle names one rack
# width's lanes, so each profile adds the shuffle fixture for its width.
profile_fixtures() {
  local fixture
  for fixture in "${reference_fixtures[@]}"; do
    case "$1:${fixture}" in
      x86-sse2:fused_fma | x86-sse2:predication | wasm-*:fused_fma | wasm-*:predication) ;;
      *) echo "${fixture}" ;;
    esac
  done
  case "$1" in
    x86-avx2) echo shuffle_8 ;;
    x86-avx512) echo shuffle_16 ;;
    *) echo shuffle_4 ;;
  esac
}

c_flags=(-std=gnu11 -O1 -fno-fast-math -ffp-contract=off)

for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  use_profile "${profile}"
  sources=()
  objects=()
  for fixture in $(profile_fixtures "${profile}"); do
    "${rakec}" --verify-native --target "${profile}" -o "${tmp}/${profile}-${fixture}.o" \
      "${root}/test/native/${fixture}.rk"
    sources+=("${root}/test/native/${fixture}.rk")
    objects+=("${tmp}/${profile}-${fixture}.o")
  done
  "${harness}" "${profile}" "${cases}" "${sources[@]}" >"${tmp}/${profile}-reference.c"
  "${compiler}" "${c_flags[@]}" "${flags[@]}" -DRAKE_HARNESS_FENV -DRAKE_HARNESS_MAIN \
    "${tmp}/${profile}-reference.c" "${objects[@]}" -lm -o "${tmp}/${profile}-reference"
  "${runner[@]}" "${tmp}/${profile}-reference"

  oracle_objects=()
  for fixture in "${oracle_fixtures[@]}"; do
    oracle_objects+=("${tmp}/${profile}-${fixture}.o")
  done
  "${compiler}" "${c_flags[@]}" "${flags[@]}" -DLANES="${lanes}" -I"${root}/test" \
    "${root}/test/native_oracle_runtime.c" "${oracle_objects[@]}" -lm -o "${tmp}/${profile}-oracle"
  "${runner[@]}" "${tmp}/${profile}-oracle"
done

for profile in wasm-simd128 wasm-simd128-relaxed; do
  sources=()
  kernels=()
  for fixture in $(profile_fixtures "${profile}"); do
    "${rakec}" --emit-c --target "${profile}" -o "${tmp}/${profile}-${fixture}.c" \
      "${root}/test/native/${fixture}.rk"
    sources+=("${root}/test/native/${fixture}.rk")
    kernels+=("${tmp}/${profile}-${fixture}.c")
  done
  "${harness}" "${profile}" "${cases}" "${sources[@]}" >"${tmp}/${profile}-reference.c"
  # Each kernel unit compiles on its own, so its v128_t signatures and the
  # harness's vector types meet only at the WebAssembly v128 ABI.
  relaxed=()
  [[ "${profile}" == wasm-simd128-relaxed ]] && relaxed=(-mrelaxed-simd)
  clang --target=wasm32 -msimd128 "${relaxed[@]}" -O2 -ffreestanding -nostdlib -DRAKE_WASM_LINKAGE= \
    -Wl,--no-entry -Wl,--export=run_reference_cases \
    "${tmp}/${profile}-reference.c" "${kernels[@]}" -o "${tmp}/${profile}-reference.wasm"
  result="$(wasmtime run --invoke run_reference_cases "${tmp}/${profile}-reference.wasm" 2>/dev/null)"
  if [[ "${result}" != 0 ]]; then
    echo "${profile}: case on line $((result / 1000)) failed at $((result % 1000))" >&2
    exit 1
  fi
  echo "${profile} reference agreement under wasmtime"
done
