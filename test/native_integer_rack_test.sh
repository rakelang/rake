#!/usr/bin/env bash
# Check integer lowering and the SIMD C ABI against independently computed bits.
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
    for kind in i32s u32s; do
        for operation in add sub and or xor; do
            case "$operation" in
                add) expression='a + b' ;; sub) expression='a - b' ;;
                and) expression='bit_and(a, b)' ;; or) expression='bit_or(a, b)' ;;
                xor) expression='bit_xor(a, b)' ;;
            esac
            printf 'scratch %s_%s(a: %s, b: %s) -> %s:\n  %s\n\n' \
                "$kind" "$operation" "$kind" "$kind" "$kind" "$expression"
        done
        printf 'scratch %s_increment(a: %s) -> %s:\n  a + <1>\n\n' "$kind" "$kind" "$kind"
        printf 'scratch %s_keep_inputs(a: %s, b: %s) -> %s:\n  | changed <| a - b\n  | mixed <| bit_xor(changed, a)\n  mixed + b\n\n' "$kind" "$kind" "$kind" "$kind"
    done > "$source"
    for comparison in lt le gt ge eq ne; do
        case "$comparison" in
            lt) operator='<' ;; le) operator='<=' ;; gt) operator='>' ;;
            ge) operator='>=' ;; eq) operator='=' ;; ne) operator='!=' ;;
        esac
        printf 'scratch signed_%s(a: i32s, b: i32s) -> i32s:\n  if a %s b then a else b\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch signed_%s_bits(a: i32s, b: i32s) -> u32:\n  bitmask(a %s b)\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch signed_%s_keep_inputs(a: i32s, b: i32s) -> i32s:\n  let chosen = if a %s b then a else b\n  chosen + a - b\n\n' "$comparison" "$operator" >> "$source"
    done
    printf 'scratch select_float(a: i32s, b: i32s, first: f32s, second: f32s) -> f32s:\n  if a < b then first else second\n\nscratch select_integer(a: f32s, b: f32s, first: i32s, second: i32s) -> i32s:\n  if a > b then first else second\n\ntine #integer_negative(values: i32s) means values < <0>\n\nrake integer_gaps(values: i32s) -> i32s:\n  tine #negative means #integer_negative(values)\n  through #negative into shifted:\n    values - <1>\n  through #negative gaps into shifted_gaps:\n    values + <1>\n  sweep:\n    | #negative => shifted\n    | #negative gaps => shifted_gaps\n\n' >> "$source"
    "$rakec" --verify-native --target "$profile" -o "${tmp}/${profile}.o" "$source"
    if [[ "$profile" == aarch64-neon ]]; then
        aarch64-unknown-linux-gnu-gcc -O1 -static -DLANES="$lanes" \
            -isystem "${RAKE_AARCH64_LIBC_DEV}/include" \
            -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib" \
            "${root}/test/native_integer_rack_runtime.c" "${tmp}/${profile}.o" -o "${tmp}/${profile}"
        qemu-aarch64 "${tmp}/${profile}"
    else
        cc -O1 "${flags[@]}" -DLANES="$lanes" \
            "${root}/test/native_integer_rack_runtime.c" "${tmp}/${profile}.o" -o "${tmp}/${profile}"
        if [[ "$profile" == x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
            : "${RAKE_SDE:?AVX-512 runtime checks require capable hardware or Intel SDE}"
            "$RAKE_SDE" -skx -- "${tmp}/${profile}"
        else
            "${tmp}/${profile}"
        fi
    fi
done
