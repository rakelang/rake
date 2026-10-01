# Racks and targets

A rack is one vector register. Its type names its element, as `f32s` names a
rack of `f32` lanes, and the target profile gives its width. This page
defines the profiles, the operations each one compiles, the floating-point
rules and the calling conventions of crunches and rakes.

## Profiles

| Profile | Register | `f32` lanes | Status |
| --- | --- | ---: | --- |
| `x86-avx2` | one 256-bit YMM register, AVX2 and FMA3 | 8 | `f32s` crunches and rakes, as GNU assembly |
| `aarch64-neon` | one 128-bit vector register, AAPCS64 | 4 | `f32s` crunches and rakes, as GNU assembly |
| `wasm-simd128` | one `v128` | 4 | float and integer crunches and rakes, runs and whole programs, as C |
| `wasm-simd128-relaxed` | one `v128` | 4 | `wasm-simd128` and the relaxed SIMD operations |
| `x86-sse2` | one 128-bit XMM register | 4 | planned |
| `x86-avx512` | one 512-bit ZMM register | 16 | planned |
| `scalar` | none | 1 | planned, without the one-register guarantee |

`--target native`, the default, chooses `x86-avx2` on a host with AVX2 and
FMA and `aarch64-neon` on a host with Advanced SIMD, and fails elsewhere. A
build for another machine names its profile. The compiler rejects code for a
planned profile.

`--width n` asserts the `f32` lane count. It must equal the profile's, and a
mismatch is an error before any code is generated. The compiler never meets
it by splitting or narrowing a rack.

`lanes`, the lane count, and `@`, the lane index, are reserved and
unavailable on every profile.

## Float racks

These operations on `f32s` racks compile on each profile:

| Operation | `x86-avx2` | `aarch64-neon` | `wasm-simd128` |
| --- | :-: | :-: | :-: |
| `+` `-` `*` `/`, negation, `sqrt` | yes | yes | yes |
| comparisons, `and` `or` `not` on masks, `select`, `if` on a mask | yes | yes | yes |
| `fma(a, b, c)` | yes | yes | no |
| `min` `max` `abs` `floor` `ceil` `trunc` `nearest` | no | no | yes |
| `exp` `log` `log2` `tanh` | no | no | yes |
| `if` on a uniform condition | no | no | yes |
| `sum` `product` `minimum` `maximum`, and the scans | yes | no | yes |
| `all` `any` `bitmask`, `extract` `insert` `shuffle` | no | no | yes |

A crunch or rake may return a rack or a mask on every profile, a scalar from
a reduction on `x86-avx2` and `wasm-simd128`, and a `bool` from `all` or
`any` on `wasm-simd128`. `%` has no float form, and `true` and `false` have
no rack form: a mask comes from a comparison. `sin`, `cos`, `tan`, `pow` and
`atan2` type-check but have no lowering, so the compiler rejects them on every
profile.

`select(mask, a, b)` takes `a` in the mask's lanes and `b` elsewhere, and so
does `if mask then a else b`. `if <c> then a else b` with a uniform condition
chooses one rack for every lane. On `wasm-simd128`, `min(a, b)` and
`max(a, b)` are IEEE 754 minimum and maximum: NaN if either lane is NaN, and
−0 below +0. `floor`, `ceil`, `trunc` and `nearest` round to an integral
value, `nearest` with ties to even. `fma(a, b, c)` is `a * b + c` with one
rounding. It says the program depends on that rounding, which `wasm-simd128`
can't provide, so it rejects `fma` rather than computing it with two.

## Integer racks

Integer racks are implemented for `wasm-simd128` only. On its 128-bit
register a `u8s` rack has 16 lanes, `i16s` 8, `i32s` and `u32s` 4, and `i64s`
and `u64s` 2. Integer arithmetic on racks wraps.

| Operation | `u8s` | `i16s` | `i32s` | `u32s` | `i64s` | `u64s` |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| `+` `-` | yes | yes | yes | yes | yes | yes |
| `*` | no | yes | yes | yes | yes | yes |
| negation | no | yes | yes | no | yes | no |
| `abs` | yes | yes | yes | no | yes | no |
| `min` `max` | yes | yes | yes | no | no | no |
| comparisons, and so `select` and `bitmask` | yes | yes | yes | no | yes | no |
| bitwise operations and bit shifts | yes | yes | yes | yes | yes | yes |
| `shuffle` `extract` `insert` | yes | yes | yes | yes | yes | yes |

`u8s` lanes compare unsigned, and the other integer racks compare signed.
`abs` of a `u8s` rack treats its lanes as signed bytes. No integer rack
divides, and the reductions and scans take float racks only. An integer
literal beside an integer rack is broadcast in the rack's element type, as in
`a + 1` or `min(a, <0>)`.

Conversions between integer and float racks:

- `dot(a, b)` takes two `i16s` racks and returns an `i32s` rack whose lane
  `i` is `a[2i] * b[2i] + a[2i+1] * b[2i+1]`, wrapping.
- `narrow(a, b)` takes two `i32s` racks and returns one `i16s` rack, `a`'s
  lanes then `b`'s, each saturated to the 16-bit range.
- `widen_low(x)` and `widen_high(x)` take the low or high eight lanes of a
  `u8s` rack, zero-extended to an `i16s` rack.
- `to_f32(x)` converts an `i32s` rack to `f32s`, rounding to nearest.
- `to_i32(x)` converts an `f32s` rack to `i32s`, rounding to nearest with ties
  to even and saturating to the 32-bit range. NaN becomes zero.
- `bitcast(i32s, x)` keeps the bits of a rack and changes its element type.

Each is one instruction except `to_i32`, which is `f32x4.nearest` then
`i32x4.trunc_sat_f32x4_s`.

<!-- rake-check: verify wasm-simd128 -->
```rake
crunch accumulate(sums: i32s, pair: i16s, weights: i16s) -> i32s:
  return sums + dot(pair, weights)

crunch requantise(low: i32s, high: i32s, low_scale: f32s, high_scale: f32s) -> i16s:
  | a <| to_i32(to_f32(low) * low_scale)
  | b <| to_i32(to_f32(high) * high_scale)
  return max(narrow(a, b), <0>)
```

## Bitwise operations and bit shifts

`bit_and(a, b)`, `bit_or(a, b)` and `bit_xor(a, b)` combine two integer racks
of one type bit by bit, and `bit_andnot(a, b)` keeps the bits of `a` that `b`
doesn't set. `shift_bits_left(x, n)` moves each lane's bits towards its high
end, filling with zeros. `shift_bits_right(x, n)` moves them towards the low
end, filling with zeros, and `shift_bits_right_signed(x, n)` fills with the
sign bit. The count is an integer literal below the lane's width in bits, or
a uniform `u32` taken modulo that width.

These shift bits within a lane. The reserved names `shift_left`,
`shift_right`, `rotate_left` and `rotate_right` are for moving whole lanes,
and are unavailable.

<!-- rake-check: verify wasm-simd128 -->
```rake
crunch step_east(here: u64s, open: u64s, board: u64s, <carry: u32>) -> u64s:
  let moving = bit_and(here, open)
  let moved = bit_or(shift_bits_left(moving, 1), shift_bits_right(moving, <carry>))
  return bit_or(here, bit_and(moved, board))
```

## Shuffles and bitmasks

`shuffle(a, [i0, i1, ...])` builds a rack from lanes of `a` chosen by static
indices, one for each lane. `shuffle(a, b, [i0, i1, ...])` chooses from both,
with `b`'s lanes numbered after `a`'s as if the two racks were laid end to
end.

`bitmask(mask)` returns a `u32` with one bit for each lane, lane zero in bit
zero. Like a reduction, its result is a scalar.

<!-- rake-check: verify wasm-simd128 -->
```rake
crunch occupied_bits(tiles: u8s) -> u32:
  return bitmask(tiles != <0>)

crunch reversed(values: f32s) -> f32s:
  return shuffle(values, [3, 2, 1, 0])
```

## Floating-point values

Float arithmetic is IEEE 754 binary32, rounded to nearest with ties to even.
Every comparison with a NaN operand is false, `!=` included, so `a != b`
means that `a` and `b` are ordered and different.

`wasm-simd128` contracts nothing, so the target and `rakec --interpret`
agree on every result bit that isn't a NaN. `x86-avx2` and `aarch64-neon`
contract a multiply and an add into one fused multiply-add when both are in
one fused region, as [fused bindings](04_fused_bindings.md) describe, and
the result then has the fused rounding. A NaN result's sign and payload
aren't specified, except where an operation defines them, as the strict
minimum and maximum of [reductions and scans](07_reductions_and_scans.md) do.

`exp`, `log`, `log2` and `tanh` are fixed sequences of binary32 operations,
Cephes' single-precision polynomials. The interpreter, the slow tier's C and
the rack code all compute them this way, so they agree bit for bit.

## Relaxed SIMD

`--target wasm-simd128-relaxed` adds four operations:
`relaxed_madd(a, b, c)` and `relaxed_nmadd(a, b, c)` compute `a * b + c` and
`-(a * b) + c`, rounded once or twice as the machine chooses, and
`relaxed_min(a, b)` and `relaxed_max(a, b)` return the machine's choice when a
lane is NaN or both are zeros of opposite sign. `wasm-simd128` rejects them at
the call, its verifier rejects a relaxed instruction in any object, and none
is available inside a `through` block. The emitted C compiles its functions
with `target("relaxed-simd")`.

<!-- rake-check: verify wasm-simd128-relaxed -->
```rake
crunch blend(a: f32s, b: f32s, weight: f32s) -> f32s:
  return relaxed_madd(a - b, weight, b)
```

## Calling conventions

A crunch or rake is a function that C can call. Its parameters arrive in
registers and its result returns in one. No profile passes an argument on
the stack, so a function that would need to is rejected.

On `x86-avx2`, the function is a hidden global symbol following the System V
convention. Parameters take the eight SSE-class argument registers in source
order: an `f32s` rack or a mask in `ymm0` to `ymm7`, a uniform `f32` in the
low lane of `xmm0` to `xmm7`. A rack or mask result returns in `ymm0`, and an
`f32` result in `xmm0`. In this crunch, `a` arrives in `ymm0`, `scale` in
`xmm1` and `b` in `ymm2`:

<!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
```rake
crunch scaled_sum(a: f32s, <scale: f32>, b: f32s) -> f32s:
  return a * <scale> + b
```

On `aarch64-neon`, parameters take `v0` to `v7` in source order, a uniform
`f32` in the low lane of its register, and the result returns in `v0`. The
register allocator uses `v0` to `v7` and `v16` to `v31`, because AAPCS64
makes the low halves of `v8` to `v15` callee-saved, and saving them would need
the stack.

On `wasm-simd128`, the function is C, `static inline` unless
`RAKE_WASM_LINKAGE` is defined. A rack or mask is a `v128_t`, a uniform `f32`
a `float`, a 64-bit uniform a `uint64_t`, and any other uniform, `bool` or
`bitmask` result a `uint32_t`.

Each uniform keeps its brackets at its declaration, `<scale: f32>`, and at its
use, `<scale>`. The use is where the broadcast happens: `vbroadcastss` on
AVX2, `dup` on NEON and a splat on wasm.

A run's boundary is in [packs and runs](02_packs_and_run.md#wasm32-boundary),
and a whole program's in [the slow tier](09_slow_tier.md). The x86 and AArch64
backends compile neither runs nor slow code.

## Verification

`--verify-native` assembles the emitted code, or compiles the emitted C,
then disassembles the object and checks every function:

- `x86-avx2`: only instructions from the profile's list, no calls, no stack
  register, no memory operand except a constant load relative to `rip`, every
  rack in a whole YMM register, cross-lane instructions only in reductions and
  scans, and exactly the fused multiply-adds the compiler selected.
- `aarch64-neon`: only listed instructions, no calls, no stack, no `v8` to
  `v15`, no general or scalar float registers, loads only of literal
  constants, every rack in a whole 128-bit register, no lane extraction except
  the `dup` of a uniform, and exactly the selected fused multiply-adds.
- `wasm-simd128`: a crunch or rake contains only locals, constants, and SIMD
  and scalar register instructions, with no calls, memory or branches.

The C compiler and disassembler are `$RAKE_WASM_CC` (default `clang`) and
`$RAKE_WASM_OBJDUMP` (default `llvm-objdump`). Clang may exchange one vector
instruction for an equivalent one, such as a splatted zero for a constant, or
compute arithmetic on splats of uniforms as scalars and splat the result. The
verifier accepts both, because both stay in registers.
