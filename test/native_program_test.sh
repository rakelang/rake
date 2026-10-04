#!/usr/bin/env bash
# Semantic correctness: the selected-profile interpreter supplies scalar and
# mixed-program answers. External agreement: independent C checks layout and
# ABI calls; hand-derived lane counts check native reductions.
set -euo pipefail
ulimit -c 0
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
argument_source="${test_dir}/abi/process_arguments.rk"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

printf '%s\n' '#include <stdint.h>' '#include <stdio.h>' \
  'extern int32_t rake_program_main(void);' \
  'int main(void) { printf("%d\n", rake_program_main()); return 0; }' \
  >"${tmp}/result.c"

for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  if [[ "${profile}" = aarch64-neon ]]; then
    cc=aarch64-unknown-linux-gnu-gcc
    objcopy=aarch64-unknown-linux-gnu-objcopy
    link_flags=(-static -isystem "${RAKE_AARCH64_LIBC_DEV}/include" \
      -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib")
    runner=(qemu-aarch64)
  else
    cc=gcc
    objcopy=objcopy
    link_flags=()
    runner=()
    if [[ "${profile}" = x86-avx512 ]]; then
      : "${RAKE_SDE:?AVX-512 scalar programs require the same SDE oracle as x86_profiles_test.sh}"
      runner=("${RAKE_SDE}" -skx --)
    fi
  fi

  for name in slow_tier frames speck const_pointers; do
    source="${test_dir}/program/${name}.rk"
    expected="$("${rakec}" --interpret "${source}")"
    "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/${name}.o" "${source}"
    "${objcopy}" --redefine-sym main=rake_program_main "${tmp}/${name}.o"
    "${cc}" -O2 "${link_flags[@]}" "${tmp}/result.c" "${tmp}/${name}.o" -lm -o "${tmp}/${name}"
    actual="$("${runner[@]}" "${tmp}/${name}")"
    test "${actual}" = "${expected}" || {
      echo "${profile} ${name}: compiled ${actual}, interpreter ${expected}" >&2; exit 1;
    }
  done

  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/interop.o" "${test_dir}/abi/native_slow.rk"
  "${cc}" -O2 "${link_flags[@]}" "${test_dir}/abi/native_slow.c" "${tmp}/interop.o" -pthread -o "${tmp}/interop"
  "${runner[@]}" "${tmp}/interop"

  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/callbacks.o" "${test_dir}/abi/callbacks.rk"
  "${cc}" -O2 -Wall -Wextra -Werror "${link_flags[@]}" "${test_dir}/abi/callbacks.c" "${tmp}/callbacks.o" -o "${tmp}/callbacks"
  "${runner[@]}" "${tmp}/callbacks"
  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/opaque.o" "${test_dir}/abi/opaque.rk"
  "${cc}" -O2 -Wall -Wextra -Werror "${link_flags[@]}" "${test_dir}/abi/opaque.c" "${tmp}/opaque.o" -o "${tmp}/opaque"
  "${runner[@]}" "${tmp}/opaque"
  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/unions.o" "${test_dir}/abi/unions.rk"
  "${cc}" -O2 -Wall -Wextra -Werror "${link_flags[@]}" "${test_dir}/abi/unions.c" "${tmp}/unions.o" -o "${tmp}/unions"
  "${runner[@]}" "${tmp}/unions"
  expected="$("${rakec}" --interpret "${test_dir}/program/callbacks.rk")"
  test "${expected}" = 31
  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/local-callbacks.o" "${test_dir}/program/callbacks.rk"
  "${cc}" -O2 "${link_flags[@]}" "${tmp}/local-callbacks.o" -o "${tmp}/local-callbacks"
  actual=0; "${runner[@]}" "${tmp}/local-callbacks" || actual=$?
  test "${actual}" = "${expected}"

  # Verification applies to the embedded kernels in the final mixed object.
  "${rakec}" --verify-native --target "${profile}" -o "${tmp}/mixed.o" "${test_dir}/abi/native_mixed.rk"
  "${cc}" -O2 "${link_flags[@]}" "${tmp}/mixed.o" -o "${tmp}/mixed"
  expected="$("${rakec}" --interpret --target "${profile}" "${test_dir}/abi/native_mixed.rk")"
  actual=0; "${runner[@]}" "${tmp}/mixed" || actual=$?
  test "${actual}" = "${expected}" && test "${actual}" = 3 || {
    echo "${profile} mixed C boundary: compiled ${actual}, interpreter ${expected}, expected 3" >&2; exit 1;
  }
  # The public C product also uses the caller's own C toolchain.
  "${rakec}" --emit-c --target "${profile}" -o "${tmp}/mixed.c" "${test_dir}/abi/native_mixed.rk"
  "${cc}" -std=gnu11 -O2 -ffp-contract=off -fno-fast-math -Werror "${link_flags[@]}" \
    "${tmp}/mixed.c" -lm -o "${tmp}/mixed-c"
  actual=0; "${runner[@]}" "${tmp}/mixed-c" || actual=$?
  test "${actual}" = 3 || {
    echo "${profile} emitted C boundary: compiled ${actual}, expected 3" >&2; exit 1;
  }
  if [[ "${profile}" != aarch64-neon ]]; then
    "${rakec}" --verify-native --target "${profile}" -o "${tmp}/mixed.o" "${test_dir}/abi/native_mixed_x86.rk"
    "${cc}" -O2 "${link_flags[@]}" "${tmp}/mixed.o" -o "${tmp}/mixed"
    expected="$("${rakec}" --interpret --target "${profile}" "${test_dir}/abi/native_mixed_x86.rk")"
    case "${profile}" in
      x86-sse2) oracle=28 ;;
      x86-avx2) oracle=56 ;;
      x86-avx512) oracle=112 ;;
    esac
    actual=0; "${runner[@]}" "${tmp}/mixed" || actual=$?
    test "${actual}" = "${expected}" && test "${actual}" = "${oracle}" || {
      echo "${profile} mixed reduction: compiled ${actual}, interpreter ${expected}, expected ${oracle}" >&2; exit 1;
    }
  fi

  "${rakec}" --emit-obj --target "${profile}" -o "${tmp}/arguments.o" "${argument_source}"
  "${cc}" -O2 "${link_flags[@]}" "${tmp}/arguments.o" -o "${tmp}/arguments"
  "${cc}" -O2 "${link_flags[@]}" "${test_dir}/abi/process_arguments.c" -o "${tmp}/argument-oracle"
  for case in empty words bytes; do
    case "${case}" in
      empty) args=() ;;
      words) args=(alpha '' --flag) ;;
      bytes) args=('λ' '雪' 'a b') ;;
    esac
    expected="$("${rakec}" --interpret "${argument_source}" -- "${args[@]}")"
    actual=0; "${runner[@]}" "${tmp}/arguments" "${args[@]}" || actual=$?
    oracle=0; "${runner[@]}" "${tmp}/argument-oracle" "${args[@]}" || oracle=$?
    test "${actual}" = "${expected}" && test "${actual}" = "${oracle}" || {
      echo "${profile} arguments (${case}): compiled ${actual}, interpreter ${expected}, C ${oracle}" >&2; exit 1;
    }
  done
done

# These cases must retain their interpreter traps in the native C lowering.
for name in add_overflow convert_range divide_zero float_convert index_bounds addr_bounds slice_bounds null_callback; do
  source="${test_dir}/program/trap/${name}.rk"
  if "${rakec}" --interpret "${source}" >"${tmp}/trap.log" 2>&1; then
    echo "${name}: interpreter did not trap" >&2; exit 1
  fi
  grep -q trap "${tmp}/trap.log"
  "${rakec}" --emit-obj --target x86-sse2 -o "${tmp}/trap.o" "${source}"
  gcc "${tmp}/trap.o" -lm -o "${tmp}/trap"
  trap_status=0
  { "${tmp}/trap"; } >"${tmp}/trap.log" 2>&1 || trap_status=$?
  test "${trap_status}" = 132 || {
    echo "${name}: expected SIGILL trap, got status ${trap_status}" >&2; exit 1;
  }
done
echo "native scalar/mixed-program semantic and C ABI checks passed"
