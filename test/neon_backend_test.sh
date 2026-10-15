#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${root}/_build/default/src/bin/main.exe"
cross="aarch64-unknown-linux-gnu"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

compile() {
  local name="$1"
  "${rakec}" --emit-asm --target aarch64-neon -o "${tmp}/${name}.s" \
    "${test_dir}/native/${name}.rk"
  "${rakec}" --verify-native --target aarch64-neon -o "${tmp}/${name}.o" \
    "${test_dir}/native/${name}.rk"
}

compile add
compile select
compile scalar_parameter
compile fused_fma
compile contracted_fma
compile predication

grep -Fq 'fadd v0.4s, v0.4s, v1.4s' "${tmp}/add.s"
grep -Fq 'dup v1.4s, v1.s[0]' "${tmp}/scalar_parameter.s"
grep -Fq 'bsl' "${tmp}/select.s"
if [[ "$("${cross}-objdump" -d --no-show-raw-insn "${tmp}/fused_fma.o" \
    | grep -c $'\tfmla')" -ne 1 ]]; then
  echo "explicit NEON FMA did not produce exactly one FMLA instruction" >&2
  exit 1
fi
if [[ "$("${cross}-objdump" -d --no-show-raw-insn "${tmp}/contracted_fma.o" \
    | grep -c $'\tfmla')" -ne 1 ]]; then
  echo "ordinary fused multiply-add graph did not select exactly one NEON FMLA" >&2
  exit 1
fi
if "${cross}-objdump" -d --no-show-raw-insn "${tmp}/predication.o" \
    | grep -Eq '\<(bl|blr|str|stp|sub[[:space:]]+sp|add[[:space:]]+sp)\>'; then
  echo "NEON predication introduced a call or stack operation" >&2
  exit 1
fi

echo "AArch64 NEON selection and object test passed"
