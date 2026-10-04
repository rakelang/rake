#!/usr/bin/env bash
# Compare cross-lane operations with independent C bits and register ABIs.
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
        printf 'scratch insert_lane_%d(values: f32s, <replacement: f32>) -> f32s:\n  insert(values, %d, <replacement>)\n\n' "$lane" "$lane"
        printf 'scratch insert_constant_lane_%d(values: f32s) -> f32s:\n  insert(values, %d, <-0.0>)\n\n' "$lane" "$lane"
        printf 'scratch insert_keep_source_lane_%d(values: f32s, <replacement: f32>) -> f32s:\n  let changed = insert(values, %d, <replacement>)\n  changed + values\n\n' "$lane" "$lane"
        printf 'scratch insert_keep_scalar_lane_%d(values: f32s, <replacement: f32>) -> f32s:\n  let changed = insert(values, %d, <replacement>)\n  changed + <replacement>\n\n' "$lane" "$lane"
        printf 'scratch relocate_lane_%d(values: f32s) -> f32s:\n  let <picked: f32> = extract(values, %d)\n  insert(values, %d, <picked>)\n\n' "$lane" "$(((lane + 1) % lanes))" "$lane"
        for kind in signed unsigned; do
            if [[ "$kind" == signed ]]; then scalar=i32; else scalar=u32; fi
            printf 'scratch extract_%s_lane_%d(values: %ss) -> %s:\n  extract(values, %d)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$lane"
            printf 'scratch broadcast_%s_lane_%d(values: %ss) -> %ss:\n  let <picked: %s> = extract(values, %d)\n  <picked>\n\n' "$kind" "$lane" "$scalar" "$scalar" "$scalar" "$lane"
            printf 'scratch keep_%s_lane_%d(values: %ss) -> %ss:\n  let <picked: %s> = extract(values, %d)\n  bit_xor(values, <picked>)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$scalar" "$lane"
            printf 'scratch insert_%s_lane_%d(values: %ss, <replacement: %s>) -> %ss:\n  insert(values, %d, <replacement>)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$scalar" "$lane"
            printf 'scratch insert_keep_%s_lane_%d(values: %ss, <replacement: %s>) -> %ss:\n  let changed = insert(values, %d, <replacement>)\n  bit_xor(bit_xor(changed, values), <replacement>)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$scalar" "$lane"
            printf 'scratch relocate_%s_lane_%d(values: %ss) -> %ss:\n  let <picked: %s> = extract(values, %d)\n  insert(values, %d, <picked>)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$scalar" "$(((lane + 1) % lanes))" "$lane"
            if [[ "$kind" == signed ]]; then constant=-2147483648; else constant=4294967295; fi
            printf 'scratch insert_constant_%s_lane_%d(values: %ss) -> %ss:\n  insert(values, %d, <%s>)\n\n' "$kind" "$lane" "$scalar" "$scalar" "$lane" "$constant"
        done
    done > "$source"
    printf 'scratch mask_all(values: f32s) -> bool:\n  all(values > <0.0>)\n\nscratch mask_any(values: f32s) -> bool:\n  any(values > <0.0>)\n\nscratch mask_bits(values: f32s) -> u32:\n  bitmask(values > <0.0>)\n\nscratch mask_gap_bits(values: f32s) -> u32:\n  bitmask(not (values > <0.0>))\n\nscratch mask_composed(values: f32s) -> u32:\n  let positive = values > <0.0>\n  let combined = positive or (values = <0.0>)\n  bitmask(combined and positive)\n\n' >> "$source"
    for comparison in lt le gt ge eq ne; do
        case "$comparison" in
            lt) operator='<' ;; le) operator='<=' ;;
            gt) operator='>' ;; ge) operator='>=' ;;
            eq) operator='=' ;; ne) operator='!=' ;;
        esac
        printf 'scratch uniform_%s(a: f32s, b: f32s, <left: f32>, <right: f32>) -> f32s:\n  if <left> %s <right> then a else b\n\n' "$comparison" "$operator" >> "$source"
    done
    printf 'scratch uniform_fused(a: f32s, b: f32s, <mode: f32>) -> f32s:\n  | shifted <| a + <1.0>\n  | chosen <| if <mode> > <0.0> then shifted else b\n  chosen + shifted\n\n' >> "$source"
    printf 'scratch boolean_choice(a: f32s, <first: bool>, b: f32s) -> f32s:\n  if <first> then a else b\n\nscratch boolean_fused(a: f32s, b: f32s, <first: bool>) -> f32s:\n  | chosen <| if <first> then a else b\n  chosen + a + b\n\nscratch boolean_any(a: f32s, b: f32s) -> f32s:\n  let <take: bool> = any(a > <0.0>)\n  if <take> then a else b\n\nscratch boolean_all(a: f32s, b: f32s) -> f32s:\n  if all(a > <0.0>) then a else b\n\nscratch boolean_identity(<value: bool>) -> bool:\n  <value>\n\nscratch boolean_guarded_roots(values: f32s, <positive: bool>) -> f32s:\n  if <positive> then sqrt(values) else -sqrt(-values)\n\nrake boolean_nested(values: f32s, <root: bool>) -> f32s:\n  tine #positive means values > <0.0>\n  through #positive into selected:\n    if <root> then sqrt(values) else values / <2.0>\n  sweep:\n    | #positive => selected\n    | #positive gaps => <0.0>\n\nscratch boolean_six_slots(<a: bool>, <b: bool>, <c: bool>, <d: bool>, <e: bool>, <f: bool>) -> f32s:\n  let first = if <a> then <1.0> else <0.0>\n  let second = if <b> then <2.0> else <0.0>\n  let third = if <c> then <4.0> else <0.0>\n  let fourth = if <d> then <8.0> else <0.0>\n  let fifth = if <e> then <16.0> else <0.0>\n  let sixth = if <f> then <32.0> else <0.0>\n  first + second + third + fourth + fifth + sixth\n\nscratch boolean_eight_vectors(a: f32s, b: f32s, c: f32s, d: f32s, e: f32s, f: f32s, g: f32s, h: f32s, <first: bool>) -> f32s:\n  if <first> then a + b + c + d + e + f + g + h else h\n\n' >> "$source"
    printf 'scratch boolean_and(<left: bool>, <right: bool>) -> bool:\n  <left> and <right>\n\nscratch boolean_or(<left: bool>, <right: bool>) -> bool:\n  <left> or <right>\n\nscratch boolean_not(<value: bool>) -> bool:\n  not <value>\n\nscratch mixed_and(values: f32s, <enabled: bool>) -> u32:\n  bitmask((values > <0.0>) and <enabled>)\n\nscratch mixed_or(values: f32s, <enabled: bool>) -> u32:\n  bitmask(<enabled> or (values > <0.0>))\n\n' >> "$source"
    printf 'scratch uniform_literal_right(a: f32s, b: f32s, <value: f32>) -> f32s:\n  if <value> > <0.0> then a else b\n\nscratch uniform_literal_left(a: f32s, b: f32s, <value: f32>) -> f32s:\n  if <0.0> < <value> then a else b\n\nscratch uniform_extracted(a: f32s, b: f32s) -> f32s:\n  let <first: f32> = extract(a, 0)\n  if <first> > <0.0> then a else b\n\nscratch uniform_guarded_roots(values: f32s, <mode: f32>) -> f32s:\n  if <mode> >= <0.0> then sqrt(values) else -sqrt(-values)\n\nrake uniform_nested(values: f32s, <left: f32>, <right: f32>) -> f32s:\n  tine #positive means values > <0.0>\n  through #positive else <0.0> into selected:\n    if <left> > <right> then sqrt(values) else values / <right>\n  sweep:\n    | #positive => selected\n    | _ => <0.0>\n\n' >> "$source"
    printf 'scratch compound_choice(a: f32s, b: f32s, <enabled: bool>, <left: f32>, <right: f32>) -> f32s:\n  if <enabled> and (not (<left> >= <right>) or <left> = <right>) then a else b\n\nscratch compound_and(a: f32s, b: f32s, <enabled: bool>, <value: f32>) -> f32s:\n  if <enabled> and <value> > <0.0> then a else b\n\nscratch compound_or(a: f32s, b: f32s, <enabled: bool>, <value: f32>) -> f32s:\n  if <enabled> or <value> > <0.0> then a else b\n\nrake compound_nested(values: f32s, <enabled: bool>, <value: f32>) -> f32s:\n  tine #positive means values > <0.0>\n  through #positive into selected:\n    if not <enabled> or <value> > <0.0> then sqrt(values) else values / <2.0>\n  sweep:\n    | #positive => selected\n    | #positive gaps => <0.0>\n\n' >> "$source"
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
            printf 'scratch shuffle_%s(a: f32s, b: f32s) -> f32s:\n  shuffle(a, b, [%s])\n\n' "$pattern" "$joined" >> "$source"
        else
            printf 'scratch shuffle_%s(a: f32s) -> f32s:\n  shuffle(a, [%s])\n\n' "$pattern" "$joined" >> "$source"
        fi
        if [[ "$pattern" == mixed ]]; then
            printf 'scratch shuffle_keep_inputs(a: f32s, b: f32s) -> f32s:\n  let changed = shuffle(a, b, [%s])\n  changed + a + b\n\n' "$joined" >> "$source"
            printf 'scratch shuffle_same_input(a: f32s) -> f32s:\n  shuffle(a, a, [%s])\n\n' "$joined" >> "$source"
        fi
    done
    cat "${root}/test/native/uniform_arithmetic.rk" >> "$source"
    cat "${root}/test/native/bitcast.rk" >> "$source"
    "$rakec" --verify-native --target "$profile" -o "${tmp}/${profile}.o" "$source"
    # A conforming caller may leave bits above the Boolean byte unspecified.
    # Return the raw integer register so the C oracle also checks normalisation.
    for truth in 0 1; do
        if [[ "$profile" == aarch64-neon ]]; then
            printf '.text\n.global poison_boolean_%s\n.type poison_boolean_%s, %%function\npoison_boolean_%s:\n  stp x29, x30, [sp, -16]!\n  mov w0, #%s\n  movk w0, #0xa5a5, lsl #16\n  bl boolean_identity\n  ldp x29, x30, [sp], 16\n  ret\n' "$truth" "$truth" "$truth" "$((256 + truth))"
        else
            printf '.text\n.global poison_boolean_%s\n.type poison_boolean_%s, @function\npoison_boolean_%s:\n  sub $8, %%rsp\n  mov $%s, %%edi\n  call boolean_identity\n  add $8, %%rsp\n  ret\n' "$truth" "$truth" "$truth" "$((0xa5a50100 + truth))"
        fi
    done > "${tmp}/boolean-caller.s"
    if [[ "$profile" == aarch64-neon ]]; then
        printf '.section .note.GNU-stack,"",%%progbits\n' >> "${tmp}/boolean-caller.s"
    else
        printf '.section .note.GNU-stack,"",@progbits\n' >> "${tmp}/boolean-caller.s"
    fi
    if [[ "$profile" == aarch64-neon ]]; then
        aarch64-unknown-linux-gnu-gcc -O1 -Wall -Wextra -Werror -static -ffp-contract=off -DLANES="$lanes" \
            -isystem "${RAKE_AARCH64_LIBC_DEV}/include" \
            -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib" \
            "${root}/test/native_lane_transfer_runtime.c" "${tmp}/${profile}.o" "${tmp}/boolean-caller.s" -lm -o "${tmp}/${profile}"
        qemu-aarch64 "${tmp}/${profile}"
    else
        cc -O1 -Wall -Wextra -Werror -ffp-contract=off "${flags[@]}" -DLANES="$lanes" \
            "${root}/test/native_lane_transfer_runtime.c" "${tmp}/${profile}.o" "${tmp}/boolean-caller.s" -lm -o "${tmp}/${profile}"
        if [[ "$profile" == x86-avx512 ]] && ! grep -qw avx512f /proc/cpuinfo; then
            if [[ -z "${RAKE_SDE:-}" ]]; then
                echo "AVX-512 lane-transfer runtime requires AVX-512F or RAKE_SDE" >&2
                exit 1
            fi
            "$RAKE_SDE" -skx -- "${tmp}/${profile}"
        else
            "${tmp}/${profile}"
        fi
    fi
    for operation in extract insert; do
        if [[ "$operation" == extract ]]; then
            printf 'scratch outside(values: f32s) -> f32:\n  extract(values, %d)\n' "$lanes" > "${tmp}/outside.rk"
        else
            printf 'scratch outside(values: f32s) -> f32s:\n  insert(values, %d, <1.0>)\n' "$lanes" > "${tmp}/outside.rk"
        fi
        if "$rakec" --emit-asm --target "$profile" "${tmp}/outside.rk" > "${tmp}/outside.log" 2>&1; then
            echo "$profile accepted $operation outside its physical rack" >&2
            exit 1
        fi
        grep -Fq "outside a ${lanes}-lane rack" "${tmp}/outside.log"
    done
    # Register insertion has no defined native stream-tail participation yet.
    printf 'pack Values {\n  f32: value;\n}\nrun replace_first(input: stack Values, <count: i32>) -> f32:\n  for row in input using f32s up to <count>:\n    yield insert(row.value, 0, <1.0>)\n' > "${tmp}/stream.rk"
    if "$rakec" --emit-c --target "$profile" "${tmp}/stream.rk" > "${tmp}/stream.log" 2>&1; then
        echo "$profile accepted insertion without a native stream-tail contract" >&2
        exit 1
    fi
    grep -Fq 'native stream reductions, scans, extractions, insertions and shuffles are work in progress' "${tmp}/stream.log"
    printf 'scratch malformed(a: f32s) -> f32s:\n  shuffle(a, [0])\n' > "${tmp}/malformed.rk"
    if "$rakec" --emit-asm --target "$profile" "${tmp}/malformed.rk" > "${tmp}/malformed.log" 2>&1; then
        echo "$profile accepted a short shuffle index list" >&2
        exit 1
    fi
    grep -Fq "${tmp}/malformed.rk:2:" "${tmp}/malformed.log"
    grep -Fq "a shuffle needs $lanes indices" "${tmp}/malformed.log"
    indices=()
    for ((lane=0; lane<lanes; ++lane)); do indices+=("$lanes"); done
    joined="$(IFS=,; printf '%s' "${indices[*]}")"
    printf 'scratch outside(a: f32s) -> f32s:\n  shuffle(a, [%s])\n' "$joined" > "${tmp}/outside.rk"
    if "$rakec" --emit-asm --target "$profile" "${tmp}/outside.rk" > "${tmp}/outside.log" 2>&1; then
        echo "$profile accepted an out-of-range shuffle index" >&2
        exit 1
    fi
    grep -Fq "${tmp}/outside.rk:2:" "${tmp}/outside.log"
    grep -Fq "shuffle index is outside its $lanes input lanes" "${tmp}/outside.log"
    indices=()
    for ((lane=0; lane<lanes; ++lane)); do indices+=("0"); done
    joined="$(IFS=,; printf '%s' "${indices[*]}")"
    printf 'pack Values {\n  f32: value;\n}\nrun shuffle_rows(input: stack Values, <count: i32>) -> f32:\n  for row in input using f32s up to <count>:\n    yield shuffle(row.value, [%s])\n' "$joined" > "${tmp}/stream.rk"
    if "$rakec" --emit-c --target "$profile" "${tmp}/stream.rk" > "${tmp}/stream.log" 2>&1; then
        echo "$profile accepted shuffle without a native stream-tail contract" >&2
        exit 1
    fi
    grep -Fq 'native stream reductions, scans, extractions, insertions and shuffles are work in progress' "${tmp}/stream.log"
done
