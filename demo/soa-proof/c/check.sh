#!/usr/bin/env bash

set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cc="${CC:-cc}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

common=(
  -O3 -std=c17 -Wall -Wextra -Wpedantic -Werror
  -ffp-contract=off -fno-lto
)

"${cc}" "${common[@]}" -march=x86-64 -msse2 -mno-avx \
  -c "${source_dir}/scalar.c" -o "${tmp}/scalar.o"
"${cc}" "${common[@]}" -march=x86-64 -msse2 -mno-avx \
  -c "${source_dir}/sse2.c" -o "${tmp}/sse2.o"
"${cc}" "${common[@]}" -march=x86-64 -mavx2 -mno-avx512f \
  -c "${source_dir}/avx2.c" -o "${tmp}/avx2.o"
"${cc}" "${common[@]}" -march=x86-64 -msse2 -mno-avx \
  -c "${source_dir}/helpers.c" -o "${tmp}/helpers.o"
"${cc}" "${common[@]}" -march=x86-64 -msse2 -mno-avx \
  -c "${source_dir}/selftest.c" -o "${tmp}/selftest.o"

"${cc}" "${tmp}/scalar.o" "${tmp}/sse2.o" "${tmp}/avx2.o" \
  "${tmp}/helpers.o" "${tmp}/selftest.o" -lm -o "${tmp}/selftest"
"${tmp}/selftest"

# Cross-profile compilation evidence does not require AVX-512 hardware.
"${cc}" "${common[@]}" -march=x86-64 -mavx512f \
  -c "${source_dir}/avx512.c" -o "${tmp}/avx512.o"
