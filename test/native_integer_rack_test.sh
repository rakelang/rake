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
        for operation in add sub mul and or xor andnot; do
            case "$operation" in
                add) expression='a + b' ;; sub) expression='a - b' ;; mul) expression='a * b' ;;
                and) expression='bit_and(a, b)' ;; or) expression='bit_or(a, b)' ;;
                xor) expression='bit_xor(a, b)' ;;
                andnot) expression='bit_andnot(a, b)' ;;
            esac
            printf 'scratch %s_%s(a: %s, b: %s) -> %s:\n  %s\n\n' \
                "$kind" "$operation" "$kind" "$kind" "$kind" "$expression"
        done
        printf 'scratch %s_increment(a: %s) -> %s:\n  a + <1>\n\n' "$kind" "$kind" "$kind"
        printf 'scratch %s_keep_inputs(a: %s, b: %s) -> %s:\n  | changed <| a - b\n  | mixed <| bit_xor(changed, a)\n  mixed + b\n\n' "$kind" "$kind" "$kind" "$kind"
        printf 'scratch %s_multiply_keep_inputs(a: %s, b: %s) -> %s:\n  | product <| a * b\n  | mixed <| bit_xor(product, a)\n  mixed + b\n\n' "$kind" "$kind" "$kind" "$kind"
        printf 'scratch %s_multiply_keep_left(a: %s, b: %s) -> %s:\n  let product = a * b\n  product + a\n\n' "$kind" "$kind" "$kind" "$kind"
        printf 'scratch %s_square(a: %s) -> %s:\n  a * a\n\n' "$kind" "$kind" "$kind"
        printf 'scratch %s_andnot_keep_inputs(a: %s, b: %s) -> %s:\n  | cleared <| bit_andnot(a, b)\n  | mixed <| bit_xor(cleared, a)\n  mixed + b\n\n' "$kind" "$kind" "$kind" "$kind"
        printf 'scratch %s_andnot_keep_left(a: %s, b: %s) -> %s:\n  let cleared = bit_andnot(a, b)\n  cleared + a\n\n' "$kind" "$kind" "$kind" "$kind"
        printf 'scratch %s_andnot_same(a: %s) -> %s:\n  bit_andnot(a, a)\n\n' "$kind" "$kind" "$kind"
        printf 'scratch %s_andnot_literal(a: %s) -> %s:\n  bit_andnot(<1431655765>, a)\n\n' "$kind" "$kind" "$kind"
        for pattern in reverse rotate repeat identity weave mixed right; do
            indices=()
            for ((lane=0; lane<lanes; ++lane)); do
                case "$pattern" in
                    reverse) selected=$((lanes - 1 - lane)) ;;
                    rotate) selected=$(((lane + 1) % lanes)) ;;
                    repeat) selected=$((lanes - 1)) ;;
                    identity) selected=$lane ;;
                    weave) selected=$((lane / 2 + (lane % 2) * lanes)) ;;
                    mixed) selected=$(((7 * lane + 3) % (2 * lanes))) ;;
                    right) selected=$((2 * lanes - 1 - lane)) ;;
                esac
                indices+=("$selected")
            done
            joined="$(IFS=,; printf '%s' "${indices[*]}")"
            if [[ "$pattern" == weave || "$pattern" == mixed || "$pattern" == right ]]; then
                printf 'scratch %s_shuffle_%s(a: %s, b: %s) -> %s:\n  shuffle(a, b, [%s])\n\n' \
                    "$kind" "$pattern" "$kind" "$kind" "$kind" "$joined"
            else
                printf 'scratch %s_shuffle_%s(a: %s) -> %s:\n  shuffle(a, [%s])\n\n' \
                    "$kind" "$pattern" "$kind" "$kind" "$joined"
            fi
            if [[ "$pattern" == mixed ]]; then
                printf 'scratch %s_shuffle_keep_inputs(a: %s, b: %s) -> %s:\n  | changed <| shuffle(a, b, [%s])\n  | retained <| bit_xor(changed, a)\n  retained + b\n\n' \
                    "$kind" "$kind" "$kind" "$kind" "$joined"
                printf 'scratch %s_shuffle_same_input(a: %s) -> %s:\n  shuffle(a, a, [%s])\n\n' \
                    "$kind" "$kind" "$kind" "$joined"
            fi
        done
    done > "$source"
    printf 'scratch unsigned_andnot_all(a: u32s) -> u32s:\n  bit_andnot(<4294967295>, a)\n\n' >> "$source"
    for kind in i32s u32s; do
        for count in {0..31}; do
            for operation in left right right_signed; do
                printf 'scratch %s_shift_%s_%s(a: %s) -> %s:\n  shift_bits_%s(a, %s)\n\n' \
                    "$kind" "$operation" "$count" "$kind" "$kind" "$operation" "$count" >> "$source"
            done
        done
        printf 'scratch %s_shift_keep_input(a: %s) -> %s:\n  | incremented <| a + <1>\n  | shifted <| shift_bits_right_signed(incremented, 7)\n  shifted + a\n\n' "$kind" "$kind" "$kind" >> "$source"
    done
    printf 'scratch signed_shift_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then shift_bits_left(a, 31) else shift_bits_right_signed(b, 31)\n\n' >> "$source"
    printf 'scratch signed_andnot_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then bit_andnot(a, b) else bit_andnot(b, a)\n\n' >> "$source"
    for operation in min max; do
        printf 'scratch signed_%s(a: i32s, b: i32s) -> i32s:\n  %s(a, b)\n\nscratch signed_%s_keep_inputs(a: i32s, b: i32s) -> i32s:\n  | chosen <| %s(a, b)\n  | mixed <| bit_xor(chosen, a)\n  mixed + b\n\nscratch signed_%s_keep_left(a: i32s, b: i32s) -> i32s:\n  let chosen = %s(a, b)\n  chosen + a\n\nscratch signed_%s_same(a: i32s) -> i32s:\n  %s(a, a)\n\n' \
            "$operation" "$operation" "$operation" "$operation" "$operation" "$operation" "$operation" "$operation" >> "$source"
    done
    printf 'scratch signed_clamp(a: i32s) -> i32s:\n  min(max(a, <-17>), <29>)\n\nscratch signed_extreme_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then max(a, <0>) else min(b, <0>)\n\nscratch signed_extreme_literal_first(a: i32s) -> i32s:\n  max(<0>, min(<29>, a))\n\n' >> "$source"
    printf 'scratch signed_multiply_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then a * b else (a + <1>) * (b - <1>)\n\n' >> "$source"
    printf 'scratch signed_negate(a: i32s) -> i32s:\n  -a\n\nscratch signed_negate_keep_input(a: i32s) -> i32s:\n  | negative <| -a\n  bit_xor(negative, a)\n\nscratch signed_negate_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then -a else -b\n\n' >> "$source"
    printf 'scratch signed_absolute(a: i32s) -> i32s:\n  abs(a)\n\nscratch signed_absolute_keep_input(a: i32s) -> i32s:\n  | magnitude <| abs(a)\n  bit_xor(magnitude, a)\n\nscratch signed_absolute_incremented(a: i32s) -> i32s:\n  abs(a + <1>)\n\nscratch signed_absolute_twice(a: i32s) -> i32s:\n  abs(abs(a))\n\nscratch signed_absolute_selected(a: i32s, b: i32s) -> i32s:\n  if a < b then abs(a) else abs(b)\n\n' >> "$source"
    for comparison in lt le gt ge eq ne; do
        case "$comparison" in
            lt) operator='<' ;; le) operator='<=' ;; gt) operator='>' ;;
            ge) operator='>=' ;; eq) operator='=' ;; ne) operator='!=' ;;
        esac
        printf 'scratch signed_%s(a: i32s, b: i32s) -> i32s:\n  if a %s b then a else b\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch signed_%s_bits(a: i32s, b: i32s) -> u32:\n  bitmask(a %s b)\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch signed_%s_keep_inputs(a: i32s, b: i32s) -> i32s:\n  let chosen = if a %s b then a else b\n  chosen + a - b\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch unsigned_%s(a: u32s, b: u32s) -> u32s:\n  if a %s b then a else b\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch unsigned_%s_bits(a: u32s, b: u32s) -> u32:\n  bitmask(a %s b)\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch unsigned_%s_keep_inputs(a: u32s, b: u32s) -> u32s:\n  | chosen <| if a %s b then a else b\n  | retained <| chosen + a\n  retained - b\n\n' "$comparison" "$operator" >> "$source"
        printf 'scratch unsigned_%s_literal(a: u32s) -> u32:\n  bitmask(a %s <2147483648>)\n\nscratch unsigned_%s_literal_first(a: u32s) -> u32:\n  bitmask(<2147483648> %s a)\n\n' "$comparison" "$operator" "$comparison" "$operator" >> "$source"
    done
    printf 'scratch unsigned_equal_self(a: u32s) -> u32:\n  bitmask(a = a)\n\nscratch unsigned_less_self(a: u32s) -> u32:\n  bitmask(a < a)\n\ntine #unsigned_high(values: u32s) means values >= <2147483648>\n\nrake unsigned_gap_flags(values: u32s) -> f32s:\n  tine #high means #unsigned_high(values)\n  through #high into high:\n    <1.0>\n  through #high gaps into low:\n    <2.0>\n  sweep:\n    | #high => high\n    | #high gaps => low\n\nscratch unsigned_all(a: u32s, b: u32s) -> bool:\n  all(a < b)\n\nscratch unsigned_any(a: u32s, b: u32s) -> bool:\n  any(a < b)\n\n' >> "$source"
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
