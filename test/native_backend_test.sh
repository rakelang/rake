#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${test_dir}/.." && pwd)"
rakec="${root}/_build/default/src/bin/main.exe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

source_file="${test_dir}/native/add.rk"
"${rakec}" --emit-native-ir --target x86-avx2 "${source_file}" >"${tmp}/add.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/add.s" "${source_file}"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/add.o" "${source_file}"

grep -Fq '%2 : rack<f32> = add %0, %1' "${tmp}/add.native"
grep -Fq 'vaddps ymm0, ymm0, ymm1' "${tmp}/add.s"

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/identity.o" \
  "${test_dir}/native/identity.rk"
objdump -d --no-show-raw-insn "${tmp}/identity.o" | grep -Fq $'\tret'

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/fma.o" \
  "${test_dir}/native/fused_fma.rk"
if [[ "$(objdump -d --no-show-raw-insn "${tmp}/fma.o" | grep -c $'\tvfmadd')" -ne 1 ]]; then
  echo "explicit FMA did not produce exactly one native FMA instruction" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/contracted_fma.rk" >"${tmp}/contracted.native"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/contracted.o" \
  "${test_dir}/native/contracted_fma.rk"
grep -Fq 'rack.fma' "${tmp}/contracted.native"
if grep -Eq ' = (mul|add) ' "${tmp}/contracted.native"; then
  echo "transparent fused alias survived FMA contraction" >&2
  exit 1
fi
if [[ "$(objdump -d --no-show-raw-insn "${tmp}/contracted.o" | grep -c $'\tvfmadd')" -ne 1 ]]; then
  echo "ordinary fused multiply-add graph did not select exactly one native FMA" >&2
  exit 1
fi

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/select.o" \
  "${test_dir}/native/select.rk"

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/scalar_parameter.rk" >"${tmp}/scalar.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/scalar.s" \
  "${test_dir}/native/scalar_parameter.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/scalar.o" \
  "${test_dir}/native/scalar_parameter.rk"
grep -Fq '%3 : rack<f32> = rack.broadcast %1' "${tmp}/scalar.native"
grep -Eq 'vbroadcastss[[:space:]]+ymm[0-9]+,[[:space:]]*xmm1' "${tmp}/scalar.s"
if objdump -d -M intel --no-show-raw-insn "${tmp}/scalar.o" | grep -Eq '\<(call|push|pop)\>'; then
  echo "scalar-parameter scratch introduced a call or stack operation" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/predication.rk" >"${tmp}/predication.native"
"${rakec}" --emit-asm --target x86-avx2 -o "${tmp}/predication.s" \
  "${test_dir}/native/predication.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/predication.o" \
  "${test_dir}/native/predication.rk"
grep -Fq ' = sanitize ' "${tmp}/predication.native"
grep -Fq 'mask.const false' "${tmp}/predication.native"
grep -Fq 'vblendvps' "${tmp}/predication.s"
if objdump -d -M intel --no-show-raw-insn "${tmp}/predication.o" \
    | grep -Eq '\<(call|push|pop|j[a-z]+|loop)[[:space:]]'; then
  echo "predicated rake introduced a call, stack operation, or lane branch" >&2
  exit 1
fi

"${rakec}" --emit-native-ir --target x86-avx2 \
  "${test_dir}/native/reductions_scans.rk" >"${tmp}/cross-lane.native"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/cross-lane.o" \
  "${test_dir}/native/reductions_scans.rk"
grep -Fq 'rack.reduce.add' "${tmp}/cross-lane.native"
grep -Fq 'rack.scan.max' "${tmp}/cross-lane.native"
objdump -d -M intel --no-show-raw-insn "${tmp}/cross-lane.o" \
  >"${tmp}/cross-lane.dis"
if grep -Eq '\<(vhaddps|call|push|pop)\>|\<(rsp|rbp)\>' "${tmp}/cross-lane.dis"; then
  echo "strict cross-lane lowering introduced reassociation, a call, or stack use" >&2
  exit 1
fi
if [[ "$(sed -n '/<strict_reduce_add>:/,/^$/p' "${tmp}/cross-lane.dis" | grep -c $'\tvaddps')" -ne 7 ]]; then
  echo "strict add reduction did not contain seven ordered additions" >&2
  exit 1
fi
if [[ "$(sed -n '/<strict_scan_add>:/,/^$/p' "${tmp}/cross-lane.dis" | grep -c $'\tvaddps')" -ne 7 ]]; then
  echo "strict add scan did not contain seven ordered additions" >&2
  exit 1
fi

if "${rakec}" --emit-asm --target scalar "${source_file}" >"${tmp}/bad.out" 2>"${tmp}/bad.err"; then
  echo "scalar profile unexpectedly reached the AVX2 production backend" >&2
  exit 1
fi
grep -Fq "profile 'scalar' has no production backend yet" "${tmp}/bad.err"

echo "AVX2 native backend selection and object test passed"
