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
  printf '%s conversion C oracle passed\n' "$profile"
done
