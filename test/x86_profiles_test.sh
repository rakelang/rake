#!/usr/bin/env bash
# Native vector instructions must agree with an independent scalar oracle.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
source "${root}/test/profile.sh"
for profile in x86-sse2 x86-avx2 x86-avx512; do
    use_profile "$profile"
    objects=()
    for fixture in add select scalar_parameter absolute extrema rounding reductions_scans multiple_through global_tines; do
        object="${tmp}/${profile}-${fixture}.o"
        "$rakec" --verify-native --target "$profile" -o "$object" "${root}/test/native/${fixture}.rk"
        objects+=("$object")
    done
    cc -O1 -ffp-contract=off "${flags[@]}" -DLANES="$lanes" \
        "${root}/test/x86_profiles_runtime.c" "${objects[@]}" -lm -o "${tmp}/${profile}"
    "${runner[@]}" "${tmp}/${profile}"
done
if "$rakec" --emit-asm --target x86-sse2 "${root}/test/native/fused_fma.rk" >"${tmp}/fma.log" 2>&1; then
    echo "SSE2 incorrectly accepted an explicit single-rounding FMA" >&2
    exit 1
fi
grep -q 'no fused multiply-add' "${tmp}/fma.log"
