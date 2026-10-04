#!/usr/bin/env bash
# Independent scalar C and guard pages check the selected traversal's values,
# descriptor ABI and active-lane memory effects for physical CPU profiles.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  test "$("${rakec}" --interpret --target "${profile}" "${root}/test/abi/native_streams.rk")" = 160
  compiler=gcc
  object_copy=objcopy
  runner=()
  case "${profile}" in
    x86-sse2) flags=(-msse2 -mno-avx -mno-fma) ;;
    x86-avx2) flags=(-mavx2 -mfma) ;;
    x86-avx512) flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl) ;;
    aarch64-neon)
      compiler=aarch64-unknown-linux-gnu-gcc
      object_copy=aarch64-unknown-linux-gnu-objcopy
      flags=(-march=armv8-a -static -isystem "${RAKE_AARCH64_LIBC_DEV}/include"
        -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib")
      runner=(qemu-aarch64)
      ;;
  esac
  if [[ "${profile}" = x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
    : "${RAKE_SDE:?AVX-512 streams need AVX-512F hardware or the pinned Intel SDE oracle}"
    runner=("${RAKE_SDE}" -skx --)
  fi
  "${rakec}" --verify-native --target "${profile}" -o "${tmp}/roots.o" "${root}/demo/safe-root/safe_root.rk"
  "${compiler}" -std=gnu11 -O2 -ffp-contract=off -fno-fast-math -fno-math-errno \
    -Wall -Wextra -Werror "${flags[@]}" "${root}/demo/safe-root/safe_root.c" \
    "${root}/demo/safe-root/compare.c" "${tmp}/roots.o" -lm -o "${tmp}/roots"
  "${runner[@]}" "${tmp}/roots" --check-only
  "${rakec}" --verify-native --target "${profile}" -o "${tmp}/streams.o" "${root}/test/abi/native_streams.rk"
  "${object_copy}" --redefine-sym main=rake_stream_program_main "${tmp}/streams.o"
  "${compiler}" -std=gnu11 -O2 -ffp-contract=off -fno-fast-math -fno-math-errno \
    -Wall -Wextra -Werror "${flags[@]}" "${root}/test/abi/native_streams.c" \
    "${tmp}/streams.o" -lm -o "${tmp}/streams"
  "${runner[@]}" "${tmp}/streams"
  printf '%s stream ABI, memory and numerical semantics passed\n' "${profile}"
done

for addressing in barrier plain; do
  "${rakec}" --emit-c --target wasm-simd128 --wasm-addressing "${addressing}" \
    -o "${tmp}/streams.c" "${root}/test/abi/native_streams.rk"
  clang --target=wasm32 -msimd128 -O2 -ffreestanding -nostdlib -Wl,--no-entry \
    -Wl,--export=__main_void -o "${tmp}/streams.wasm" "${tmp}/streams.c"
  test "$(wasmtime run --invoke __main_void "${tmp}/streams.wasm" 2>/dev/null)" = 160
done
# Clang folds the composed shift pair and repeated integer additions into
# packed operations the Wasm run verifier does not yet prove across bindings.
# These execution checks do not claim a Wasm final-object certificate.
printf 'stream composition passed on WebAssembly in both addressing modes\n'
