#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

run() {
  echo "release gate: $1"
  shift
  "$@"
}

run "build" dune build
run "capability evidence" bash test/check_capability_evidence.sh
run "release identity" bash tools/check_release_identity.sh
run "frontend and native-object conformance" bash test/conformance_test.sh
run "documentation examples" bash tools/check_documentation_examples.sh
run "Dune unit tests" dune runtest --force
run "target profiles" bash test/target_profile_test.sh
run "native semantic differential runtime" bash test/native_backend_test.sh
run "AArch64 NEON semantic differential runtime" bash test/neon_backend_test.sh
run "compiler/Tree-sitter parser differential" bash test/parser_differential.sh
run "website" bash tools/check_website.sh

echo "release gate: all compiler, semantic, machine, parser, documentation, and website checks passed"
