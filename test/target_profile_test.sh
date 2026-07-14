#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${project_root}/_build/default/src/bin/main.exe}"
fixture="${project_root}/test/native/add.rk"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

"${rakec}" --print-targets > "${tmp}/targets"
for profile in scalar x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
  grep -q "^${profile}[[:space:]]" "${tmp}/targets"
done

if "${rakec}" --target imaginary "${fixture}" > "${tmp}/unknown" 2>&1; then
  echo "unknown target profile was accepted" >&2
  exit 1
fi
grep -q "unknown target profile 'imaginary'" "${tmp}/unknown"

# Exercise both production profiles through Rake-owned SSA and verified
# objects rather than treating target-aware type checking as enough.
"${rakec}" --emit-native-ir --target x86-avx2 --width 8 "${fixture}" \
  > "${tmp}/avx2.native"
grep -Fq '%2 : rack<f32> = add %0, %1' "${tmp}/avx2.native"
"${rakec}" --verify-native --target x86-avx2 --width 8 \
  -o "${tmp}/avx2.o" "${fixture}"
test -s "${tmp}/avx2.o"

"${rakec}" --emit-native-ir --target aarch64-neon --width 4 "${fixture}" \
  > "${tmp}/neon.native"
grep -Fq '%2 : rack<f32> = add %0, %1' "${tmp}/neon.native"
"${rakec}" --verify-native --target aarch64-neon --width 4 \
  -o "${tmp}/neon.o" "${fixture}"
test -s "${tmp}/neon.o"
aarch64-unknown-linux-gnu-objdump -d --no-show-raw-insn "${tmp}/neon.o" \
  | grep -Fq $'\tfadd\tv0.4s, v0.4s, v1.4s'

# Native selects a host profile, but it must still reach the same production
# verifier when the host resolves to AVX2.
"${rakec}" --verify-native --target native -o "${tmp}/native.o" "${fixture}"
test -s "${tmp}/native.o"

assert_width_rejected() {
  local profile="$1" width="$2" expected="$3"
  if "${rakec}" --target "${profile}" --width "${width}" "${fixture}" \
      > "${tmp}/rejected" 2>&1; then
    echo "${profile} accepted incompatible --width ${width}" >&2
    exit 1
  fi
  grep -q "${expected}" "${tmp}/rejected"
}

assert_width_rejected x86-sse2 8 "one 128-bit native register = 4 f32 lanes"
assert_width_rejected x86-avx2 4 "one 256-bit native register = 8 f32 lanes"
assert_width_rejected x86-avx512 8 "one 512-bit native register = 16 f32 lanes"
assert_width_rejected aarch64-neon 8 "one 128-bit native register = 4 f32 lanes"

# Profiles without a production backend must fail explicitly rather than
# falling back to a checker-only or external-backend success.
for profile in scalar x86-sse2 x86-avx512; do
  if "${rakec}" --emit-obj --target "${profile}" \
      -o "${tmp}/${profile}.o" "${fixture}" > "${tmp}/${profile}.out" 2>&1; then
    echo "${profile} unexpectedly produced a production object" >&2
    exit 1
  fi
  grep -Eq 'no production backend|production backend.*unavailable' \
    "${tmp}/${profile}.out"
done

echo "target profile tests passed"
