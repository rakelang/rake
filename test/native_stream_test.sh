#!/usr/bin/env bash
# Independent scalar C and guard pages check the selected traversal's values,
# descriptor ABI and active-lane memory effects for the x86 stream profiles.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for profile in x86-sse2 x86-avx2 x86-avx512; do
  case "${profile}" in
    x86-sse2) flags=(-msse2 -mno-avx -mno-fma) ;;
    x86-avx2) flags=(-mavx2 -mfma) ;;
    x86-avx512) flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl) ;;
  esac
  runner=()
  if [[ "${profile}" = x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
    : "${RAKE_SDE:?AVX-512 streams need AVX-512F hardware or the pinned Intel SDE oracle}"
    runner=("${RAKE_SDE}" -skx --)
  fi
  "${rakec}" --verify-native --target "${profile}" -o "${tmp}/roots.o" "${root}/demo/safe-root/safe_root.rk"
  gcc -std=gnu11 -O2 -ffp-contract=off -fno-fast-math -fno-math-errno \
    -Wall -Wextra -Werror "${flags[@]}" "${root}/demo/safe-root/safe_root.c" \
    "${root}/demo/safe-root/compare.c" "${tmp}/roots.o" -lm -o "${tmp}/roots"
  "${runner[@]}" "${tmp}/roots" --check-only
  "${rakec}" --verify-native --target "${profile}" -o "${tmp}/streams.o" "${root}/test/abi/native_streams.rk"
  objcopy --redefine-sym main=rake_stream_program_main "${tmp}/streams.o"
  gcc -std=gnu11 -O2 -ffp-contract=off -fno-fast-math -fno-math-errno \
    -Wall -Wextra -Werror "${flags[@]}" "${root}/test/abi/native_streams.c" \
    "${tmp}/streams.o" -lm -o "${tmp}/streams"
  "${runner[@]}" "${tmp}/streams"
  printf '%s stream ABI, memory and numerical semantics passed\n' "${profile}"
done
