#!/usr/bin/env bash
# Native vector instructions must agree with an independent scalar oracle.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for profile in x86-sse2 x86-avx2 x86-avx512; do
    case "$profile" in
        x86-sse2) lanes=4; flags=(-msse2 -mno-avx) ;;
        x86-avx2) lanes=8; flags=(-mavx2 -mfma) ;;
        x86-avx512) lanes=16; flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl) ;;
    esac
    objects=()
    for fixture in add select scalar_parameter absolute extrema rounding reductions_scans multiple_through global_tines; do
        object="${tmp}/${profile}-${fixture}.o"
        "$rakec" --verify-native --target "$profile" -o "$object" "${root}/test/native/${fixture}.rk"
        objects+=("$object")
    done
    cc -O1 -ffp-contract=off "${flags[@]}" -DLANES="$lanes" \
        "${root}/test/x86_profiles_runtime.c" "${objects[@]}" -lm -o "${tmp}/${profile}"
    if [[ "$profile" == x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
        if [[ -z "${RAKE_SDE:-}" ]]; then
            echo "AVX-512 objects verified; runtime requires AVX-512F or RAKE_SDE" >&2
            exit 1
        fi
        "$RAKE_SDE" -skx -- "${tmp}/${profile}"
    else
        "${tmp}/${profile}"
    fi
done
if "$rakec" --emit-asm --target x86-sse2 "${root}/test/native/fused_fma.rk" >"${tmp}/fma.log" 2>&1; then
    echo "SSE2 incorrectly accepted an explicit single-rounding FMA" >&2
    exit 1
fi
grep -q 'no fused multiply-add' "${tmp}/fma.log"
