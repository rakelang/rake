#!/usr/bin/env bash
# External C checks numerical semantics, register ABI and exact memory extents.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
source "${root}/test/profile.sh"
for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  use_profile "$profile"
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
