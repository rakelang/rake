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

# Process arguments use WASI's real command startup, including argv[argc].
: "${RAKE_WASI_LIBC:?process startup checks need WASI libc from the development shell}"
: "${RAKE_WASI_LIBC_DEV:?process startup checks need WASI headers from the development shell}"
"${rakec}" --emit-asm --target wasm-simd128 -o "${tmp}/arguments.c" "${test_dir}/abi/process_arguments.rk"
for source in arguments argument-oracle; do
  input="${tmp}/arguments.c"
  if [[ "${source}" = argument-oracle ]]; then input="${test_dir}/abi/process_arguments.c"; fi
  clang --target=wasm32-wasi -msimd128 -O2 -nostdlib \
    -isystem "${RAKE_WASI_LIBC_DEV}/include" -L"${RAKE_WASI_LIBC}/lib" \
    "${RAKE_WASI_LIBC}/lib/crt1-command.o" "${input}" -lc -o "${tmp}/${source}.wasm"
done
for case in empty words bytes; do
  case "${case}" in
    empty) args=() ;;
    words) args=(alpha '' --flag) ;;
    bytes) args=('λ' '雪' 'a b') ;;
  esac
  expected="$("${rakec}" --interpret "${test_dir}/abi/process_arguments.rk" -- "${args[@]}")"
  actual=0; wasmtime run "${tmp}/arguments.wasm" "${args[@]}" || actual=$?
  oracle=0; wasmtime run "${tmp}/argument-oracle.wasm" "${args[@]}" || oracle=$?
  test "${actual}" = "${expected}" && test "${actual}" = "${oracle}" || {
    echo "WASI arguments (${case}): compiled ${actual}, interpreter ${expected}, C ${oracle}" >&2; exit 1;
  }
done
echo "run boundary test passed"
