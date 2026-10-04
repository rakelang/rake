#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

check_website=true
case "$#:$*" in
  0:) ;;
  1:--compiler-only) check_website=false ;;
  *) echo 'usage: tools/release_gate.sh [--compiler-only]' >&2; exit 2 ;;
esac

run() {
  echo "release gate: $1"
  shift
  "$@"
}

run "build" dune build -j "${RAKE_BUILD_JOBS:-1}"
run "capability evidence" bash test/check_capability_evidence.sh
run "release identity" bash tools/check_release_identity.sh
run "frontend and native-object conformance" bash test/conformance_test.sh
run "documentation examples" bash tools/check_documentation_examples.sh
run "portable compiler tests" dune runtest -j "${RAKE_BUILD_JOBS:-1}" --force
run "native object integration tests" dune build -j "${RAKE_BUILD_JOBS:-1}" @runtest-native --force
run "WebAssembly object integration tests" dune build -j "${RAKE_BUILD_JOBS:-1}" @runtest-wasm --force
run "target profiles" bash test/target_profile_test.sh
run "native semantic differential runtime" bash test/native_backend_test.sh
run "SSE2, AVX2 and AVX-512 scalar-oracle agreement" bash test/x86_profiles_test.sh
run "AArch64 NEON semantic differential runtime" bash test/neon_backend_test.sh
run "native lane-transfer bits, lane bounds and scalar C ABI" bash test/native_lane_transfer_test.sh
run "native 32-bit integer semantics and vector C ABI" bash test/native_integer_rack_test.sh
run "native and WebAssembly numeric conversions and C ABI" bash test/native_conversion_test.sh
run "whole-program differential under wasmtime" bash test/program_test.sh
run "wasm32 run boundary and C interop" bash test/abi_test.sh
run "native program semantics and C ABI" bash test/native_program_test.sh
run "AVX2 and AVX-512 stream semantics and tail memory" bash test/native_stream_test.sh
run "native stream semantics, tail memory and bounded C comparison" bash demo/safe-root/run.sh
run "compiler/Tree-sitter parser differential" bash test/parser_differential.sh
if "$check_website"; then
  run "website" bash tools/check_website.sh
fi

echo "release gate: all selected checks passed"
