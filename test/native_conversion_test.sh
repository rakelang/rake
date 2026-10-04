#!/usr/bin/env bash
# External C checks numerical semantics, register ABI and exact memory extents.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  compiler=gcc
  runner=()
  case "$profile" in
    x86-sse2) lanes=4; flags=(-msse2 -mno-avx -mno-fma) ;;
    x86-avx2) lanes=8; flags=(-mavx2 -mfma) ;;
    x86-avx512) lanes=16; flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl) ;;
    aarch64-neon)
      lanes=4
      compiler=aarch64-unknown-linux-gnu-gcc
      flags=(-march=armv8-a -static -isystem "${RAKE_AARCH64_LIBC_DEV}/include"
        -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib")
      runner=(qemu-aarch64)
      ;;
  esac
  if [[ "$profile" = x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
    : "${RAKE_SDE:?AVX-512 checks need AVX-512F hardware or pinned Intel SDE}"
    runner=("$RAKE_SDE" -skx --)
  fi
  "$rakec" --verify-native --target "$profile" -o "$tmp/conversion.o" "$root/test/abi/native_conversions.rk"
  # rounding_values.h also owns the float-rounding oracle, unused by this
  # integer-only conversion oracle. Keep that shared input corpus canonical.
  "$compiler" -std=gnu11 -O1 -fno-fast-math -ffp-contract=off -Wall -Wextra -Werror \
    -Wno-unused-function "${flags[@]}" -DLANES="$lanes" "$root/test/native_conversion_runtime.c" \
    "$tmp/conversion.o" -lm -o "$tmp/conversion"
  "${runner[@]}" "$tmp/conversion"
  "$rakec" --emit-c --target "$profile" -o "$tmp/conversion.c" "$root/test/abi/native_conversions.rk"
  "$compiler" -std=gnu11 -O1 -fno-fast-math -ffp-contract=off -Wall -Wextra -Werror \
    -Wno-unused-function "${flags[@]}" -DLANES="$lanes" "$root/test/native_conversion_runtime.c" \
    "$tmp/conversion.c" -lm -o "$tmp/conversion-c"
  "${runner[@]}" "$tmp/conversion-c"
  printf '%s conversion C oracle passed\n' "$profile"
done
for addressing in barrier plain; do
  "$rakec" --emit-c --target wasm-simd128 --wasm-addressing "$addressing" \
    -o "$tmp/conversions.c" "$root/test/abi/native_conversions.rk"
  clang --target=wasm32 -msimd128 -O2 -ffreestanding -nostdlib -Wall -Wextra -Werror \
    -DRAKE_WASM_LINKAGE= -Wno-unused-function -Wl,--no-entry -Wl,--export=test \
    "$tmp/conversions.c" "$root/test/abi/conversion.c" -o "$tmp/conversions.wasm"
  test "$(wasmtime run --invoke test "$tmp/conversions.wasm" 2>/dev/null)" = 0
  "$rakec" --verify-native --target wasm-simd128 --wasm-addressing "$addressing" \
    -o "$tmp/conversions-wasm.o" "$root/test/abi/native_conversions.rk"
  printf 'wasm-simd128 (%s) unsigned conversion C oracle passed\n' "$addressing"
done
