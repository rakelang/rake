#!/usr/bin/env bash
# Semantic correctness: the existing interpreter supplies scalar-program
# answers. External agreement: independently compiled C supplies struct/ABI
# layout and calls the Rake object in both directions, on x86 and AArch64.
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

  for name in slow_tier frames speck; do
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
for name in add_overflow convert_range divide_zero float_convert index_bounds slice_bounds; do
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
echo "native slow-program semantic and C ABI checks passed"
