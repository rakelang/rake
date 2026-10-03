#!/usr/bin/env bash
# Whole-program differential: every test/program/*.rk runs main in Rake's
# executable semantics (rakec --interpret) and as WebAssembly compiled from
# the C rakec emits, in both run addressings, under wasmtime; the results
# must agree. Each program's verified object must also pass verification.
# Programs under test/program/trap/ must trap in both.
# The mixed native ABI fixture also checks its scalar/vector composition on WASM.
set -euo pipefail
shopt -s nullglob

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
cc="${RAKE_TEST_CC:-clang}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "program differential: $*" >&2
  exit 1
}

link() {
  "${cc}" --target=wasm32 -msimd128 -O2 -ffreestanding -nostdlib -Wl,--no-entry \
    -Wl,--export=__main_void -I"$(dirname "$2")" -o "$3" "$1"
}

run_wasm() {
  wasmtime run --invoke __main_void "$1" 2>/dev/null
}

count=0
for source in "${test_dir}"/program/*.rk "${test_dir}"/abi/native_mixed.rk; do
  name="$(basename "${source}" .rk)"
  expected="$("${rakec}" --interpret "${source}")" || fail "${name}: interpreter failed"
  for addressing in barrier plain; do
    "${rakec}" --emit-asm --target wasm-simd128 --wasm-addressing "${addressing}" \
      -o "${tmp}/${name}.c" "${source}"
    link "${tmp}/${name}.c" "${source}" "${tmp}/${name}.wasm"
    actual="$(run_wasm "${tmp}/${name}.wasm")" || fail "${name} (${addressing}): wasm trapped"
    test "${actual}" = "${expected}" \
      || fail "${name} (${addressing}): wasm returned ${actual}, the interpreter ${expected}"
  done
  "${rakec}" --verify-native --target wasm-simd128 -o "${tmp}/${name}.o" "${source}"
  count=$((count + 1))
done

for source in "${test_dir}"/program/trap/*.rk; do
  name="$(basename "${source}" .rk)"
  if output="$("${rakec}" --interpret "${source}" 2>&1)"; then
    fail "${name}: the interpreter returned ${output} instead of trapping"
  fi
  grep -q "trap" <<<"${output}" || fail "${name}: the interpreter failed without trapping: ${output}"
  "${rakec}" --emit-asm --target wasm-simd128 -o "${tmp}/${name}.c" "${source}"
  link "${tmp}/${name}.c" "${source}" "${tmp}/${name}.wasm"
  if result="$(run_wasm "${tmp}/${name}.wasm")"; then
    fail "${name}: wasm returned ${result} instead of trapping"
  fi
  count=$((count + 1))
done

echo "whole-program differential passed (${count} programs)"
