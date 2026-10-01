#!/usr/bin/env bash
# The wasm32 C boundary of runs (docs/spec/02_packs_and_run.md): test/abi's
# harness calls runs.rk's runs from C and returns 0, or the failing check.
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for addressing in barrier plain; do
  "${rakec}" --emit-asm --target wasm-simd128 --wasm-addressing "${addressing}" -o "${tmp}/runs.c" "${test_dir}/abi/runs.rk"
  clang --target=wasm32 -msimd128 -O2 -ffreestanding -nostdlib -Wl,--no-entry -Wl,--export=test \
    -o "${tmp}/abi.wasm" "${tmp}/runs.c" "${test_dir}/abi/harness.c"
  result="$(wasmtime run --invoke test "${tmp}/abi.wasm" 2>/dev/null)" \
    || { echo "abi (${addressing}): the harness trapped" >&2; exit 1; }
  test "${result}" = 0 || { echo "abi (${addressing}): check ${result} failed" >&2; exit 1; }
done
# Slow code calling C (interop.rk): its main returns 0, or the failing check.
"${rakec}" --emit-asm --target wasm-simd128 -o "${tmp}/interop.c" "${test_dir}/abi/interop.rk"
clang --target=wasm32 -msimd128 -O2 -ffreestanding -nostdlib -Wl,--no-entry -Wl,--export=__main_void \
  -I"${test_dir}/abi" -o "${tmp}/interop.wasm" "${tmp}/interop.c" "${test_dir}/abi/interop.c"
result="$(wasmtime run --invoke __main_void "${tmp}/interop.wasm" 2>/dev/null)" \
  || { echo "interop: the program trapped" >&2; exit 1; }
test "${result}" = 0 || { echo "interop: check ${result} failed" >&2; exit 1; }
"${rakec}" --verify-native --target wasm-simd128 -o "${tmp}/runs.o" "${test_dir}/abi/runs.rk"
"${rakec}" --verify-native --target wasm-simd128 -o "${tmp}/interop.o" "${test_dir}/abi/interop.rk"
echo "run boundary test passed"
