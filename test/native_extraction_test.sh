#!/usr/bin/env bash
# Compare every physical lane's bits with C, including the scalar return ABI.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for profile in x86-sse2 x86-avx2 x86-avx512 aarch64-neon; do
    case "$profile" in
        x86-sse2) lanes=4; flags=(-msse2 -mno-avx) ;;
        x86-avx2) lanes=8; flags=(-mavx2 -mfma) ;;
        x86-avx512) lanes=16; flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl) ;;
        aarch64-neon) lanes=4; flags=() ;;
    esac
    source="${tmp}/${profile}.rk"
    for ((lane=0; lane<lanes; ++lane)); do
        printf 'scratch extract_lane_%d(values: f32s) -> f32:\n  extract(values, %d)\n\n' "$lane" "$lane"
        printf 'scratch broadcast_lane_%d(values: f32s) -> f32s:\n  let <picked: f32> = extract(values, %d)\n  <picked>\n\n' "$lane" "$lane"
        printf 'scratch keep_source_lane_%d(values: f32s) -> f32s:\n  let <picked: f32> = extract(values, %d)\n  values + <picked>\n\n' "$lane" "$lane"
    done > "$source"
    "$rakec" --verify-native --target "$profile" -o "${tmp}/${profile}.o" "$source"
    if [[ "$profile" == aarch64-neon ]]; then
        aarch64-unknown-linux-gnu-gcc -O1 -static -ffp-contract=off -DLANES="$lanes" \
            -isystem "${RAKE_AARCH64_LIBC_DEV}/include" \
            -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib" \
            "${root}/test/native_extraction_runtime.c" "${tmp}/${profile}.o" -lm -o "${tmp}/${profile}"
        qemu-aarch64 "${tmp}/${profile}"
    else
        cc -O1 -ffp-contract=off "${flags[@]}" -DLANES="$lanes" \
            "${root}/test/native_extraction_runtime.c" "${tmp}/${profile}.o" -lm -o "${tmp}/${profile}"
        if [[ "$profile" == x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
            if [[ -z "${RAKE_SDE:-}" ]]; then
                echo "AVX-512 extraction runtime requires AVX-512F or RAKE_SDE" >&2
                exit 1
            fi
            "$RAKE_SDE" -skx -- "${tmp}/${profile}"
        else
            "${tmp}/${profile}"
        fi
    fi
    printf 'scratch outside(values: f32s) -> f32:\n  extract(values, %d)\n' "$lanes" > "${tmp}/outside.rk"
    if "$rakec" --emit-asm --target "$profile" "${tmp}/outside.rk" > "${tmp}/outside.log" 2>&1; then
        echo "$profile accepted a lane outside its physical rack" >&2
        exit 1
    fi
    grep -Fq "outside a ${lanes}-lane rack" "${tmp}/outside.log"
done
