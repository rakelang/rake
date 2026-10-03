# Primitives, operations, and targets

A rack is one vector value on the current CPU and WebAssembly profiles.
Its type specifies its element: `f32s` is a
rack of `f32` lanes. The target profile gives its width. This page
defines the profiles, the operations each one compiles, the floating-point
rules and the calling conventions of scratches and rakes.

## Profiles

| Profile | Register | `f32` lanes | Status |
| --- | --- | ---: | --- |
| `x86-sse2` | one 128-bit XMM register, SSE2 | 4 | `f32s` scratches and rakes, as GNU assembly |
| `x86-avx2` | one 256-bit YMM register, AVX2 and FMA3 | 8 | `f32s` scratches and rakes, as GNU assembly |
| `x86-avx512` | one 512-bit ZMM register, AVX-512F | 16 | `f32s` scratches and rakes, as GNU assembly |
| `aarch64-neon` | one 128-bit vector register, AAPCS64 | 4 | `f32s` scratches and rakes, as GNU assembly |
| `wasm-simd128` | one `v128` | 4 | float and integer scratches and rakes, runs and whole programs, as C |
| `wasm-simd128-relaxed` | one `v128` | 4 | `wasm-simd128` and the relaxed SIMD operations |
| `scalar` | none | 1 | WIP*, without the one-register guarantee |

*WIP: work in progress.*

`--target native`, the default, chooses the strongest available profile:
AVX-512F, then AVX2 with FMA, then SSE2 on x86, or Advanced SIMD on AArch64.
A build for another machine specifies its profile. Other CPU architectures
and the scalar fallback remain WIP*. The compiler rejects unsupported targets.

`--width n` asserts the `f32` lane count. It must equal the profile's, and a
mismatch is an error before any code is generated. The compiler never meets
it by splitting or narrowing a rack.

GPU targets are designs, outside the implemented table above:

| Proposed profile | Rack | Boundary and status |
| --- | --- | --- |
| `nvidia-ptx-sm120` | 32 thread lanes | PTX 8.7 to ahead-of-time cubin, with final artifact verification. WIP* |
| Vulkan subgroup profiles | required 32- or 64-invocation subgroup | portable SPIR-V, with device verification for physical claims. Later design, WIP* |
| Direct physical GPU profile | specified wave/lane mapping | Rake-owned selection, allocation and sequencing for a documented ISA. Later design, WIP* |

A GPU lane's scalar arithmetic is the SIMT mapping, not CPU scalar fallback.
The [GPU contract](../GPU.md) defines the proposed operation set, masks,
collectives, memory rules and verification boundary. These profiles are not
accepted by the current compiler.

`lanes`, the lane count, and `@`, the lane index, are reserved and
unavailable on every profile.

## Float racks

These operations on `f32s` racks compile on each profile:

| Operation | `x86-sse2` | `x86-avx2` | `x86-avx512` | `aarch64-neon` | `wasm-simd128` |
| --- | :-: | :-: | :-: | :-: | :-: |
| `+` `-` `*` `/`, negation, `sqrt` | yes | yes | yes | yes | yes |
| comparisons, `and` `or` `not` on masks, `select`, `if` on a mask | yes | yes | yes | yes | yes |
| `fma(a, b, c)` | ISA limit† | yes | yes | yes | ISA limit† |
| `min` `max` `abs` `floor` `ceil` `trunc` `nearest` | WIP* | WIP* | WIP* | WIP* | yes |
| `exp` `log` `log2` `tanh` | WIP* | WIP* | WIP* | WIP* | yes |
| `if` on a uniform condition | WIP* | WIP* | WIP* | WIP* | yes |
| `sum` `product` `minimum` `maximum`, and the scans | yes | yes | yes | WIP* | yes |
| `all` `any` `bitmask`, `extract` `insert` `shuffle` | WIP* | WIP* | WIP* | WIP* | yes |

*WIP: work in progress. Compilation fails for these cells.* †SSE2 and strict
WebAssembly SIMD have no fused multiply-add instruction. Their rejection of
explicit `fma` preserves its single-rounding semantics, rather than indicating
an unfinished lowering. Relaxed WebAssembly SIMD is a separate opt-in profile.

A scratch or rake may return a rack or a mask on every profile, a scalar from
a reduction on the x86 profiles and `wasm-simd128`, and a `bool` from `all` or
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
| `*` | WIP* | yes | yes | yes | yes | yes |
| negation | WIP* | yes | yes | WIP* | yes | WIP* |
| `abs` | yes | yes | yes | WIP* | yes | WIP* |
| `min` `max` | yes | yes | yes | WIP* | WIP* | WIP* |
| comparisons, and so `select` and `bitmask` | yes | yes | yes | WIP* | yes | WIP* |
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
scratch accumulate(sums: i32s, pair: i16s, weights: i16s) -> i32s:
  sums + dot(pair, weights)

scratch requantise(low: i32s, high: i32s, low_scale: f32s, high_scale: f32s) -> i16s:
  | a <| to_i32(to_f32(low) * low_scale)
  | b <| to_i32(to_f32(high) * high_scale)
  max(narrow(a, b), <0>)
```

## Bitwise operations and bit shifts

`bit_and(a, b)`, `bit_or(a, b)` and `bit_xor(a, b)` combine two integer racks
of one type bit by bit, and `bit_andnot(a, b)` keeps the bits of `a` that `b`
doesn't set. `shift_bits_left(x, n)` moves each lane's bits towards its high
end, filling with zeros. `shift_bits_right(x, n)` moves them towards the low
end, filling with zeros, and `shift_bits_right_signed(x, n)` fills with the
sign bit. The count is an integer literal below the lane's width in bits, or
a uniform `u32` taken modulo that width.

These shift bits within a lane. The reserved identifiers `shift_left`,
`shift_right`, `rotate_left` and `rotate_right` are for moving whole lanes,
and are unavailable.

<!-- rake-check: verify wasm-simd128 -->
```rake
scratch step_east(here: u64s, open: u64s, board: u64s, <carry: u32>) -> u64s:
  let moving = bit_and(here, open)
  let moved = bit_or(shift_bits_left(moving, 1), shift_bits_right(moving, <carry>))
  bit_or(here, bit_and(moved, board))
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
scratch occupied_bits(tiles: u8s) -> u32:
  bitmask(tiles != <0>)

scratch reversed(values: f32s) -> f32s:
  shuffle(values, [3, 2, 1, 0])
```

## Floating-point values

Float arithmetic is IEEE 754 binary32, rounded to nearest with ties to even.
Every comparison with a NaN operand is false, `!=` included, so `a != b`
means that `a` and `b` are ordered and different.

Native CPU comparisons don't raise invalid-operation exceptions for quiet
NaNs. SSE2 implements `<` and `<=` by checking for ordered operands, making
unordered operands benign, then comparing the racks. NEON uses that approach
for its ordered inequalities and `!=`. Their extra mask and operand registers
are included in the allocator's pressure check. Signalling NaNs can still
raise an invalid-operation exception.

`wasm-simd128` contracts nothing, so the target and `rakec --interpret`
agree on every result bit that isn't a NaN. `x86-avx2`, `x86-avx512` and `aarch64-neon`
contract a multiply and an add into one fused multiply-add when both are in
one fused region, as [fused bindings](04_fused_bindings.md) describe, and
the result then has the fused rounding. A NaN result's sign and payload
aren't specified, except where an operation defines them, as the strict
minimum and maximum of [reductions and scans](06_reductions_and_scans.md) do.

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
scratch blend(a: f32s, b: f32s, weight: f32s) -> f32s:
  relaxed_madd(a - b, weight, b)
```

## Calling conventions

A scratch or rake is a function that C can call. Its parameters arrive in
registers and its result returns in one. No profile passes an argument on
the stack, so a function that would need to is rejected.

On x86, the function is a hidden global symbol following the System V
convention. Parameters take the eight SSE-class argument registers in source
order. A uniform `f32` occupies the low lane of an XMM register. A rack or
mask uses XMM on SSE2, YMM on AVX2, or ZMM on AVX-512. The result uses register
zero of the same class, or `xmm0` for a scalar `f32`.

| Profile | Rack arguments | Rack result | C caller flags |
| --- | --- | --- | --- |
| `x86-sse2` | `xmm0`–`xmm7` | `xmm0` | `-msse2` |
| `x86-avx2` | `ymm0`–`ymm7` | `ymm0` | `-mavx2 -mfma` |
| `x86-avx512` | `zmm0`–`zmm7` | `zmm0` | `-mavx512f` |

SSE2 reserves `xmm15` for two-address instruction lowering and allocates
source values to the other 15 registers. AVX2 has 16 vector registers and
AVX-512 has 32. The AVX-512 emitter also uses `k1` as an instruction-local
mask. Constant pools are aligned to the profile's 16-, 32- or 64-byte rack.

In this scratch on AVX2, `a` arrives in `ymm0`, `scale` in `xmm1` and `b` in
`ymm2`:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch scaled_sum(a: f32s, <scale: f32>, b: f32s) -> f32s:
  a * <scale> + b
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
AVX2 and AVX-512, `shufps` on SSE2, `dup` on NEON and a splat on wasm.

A run's boundary is in [packs and runs](02_packs_and_run.md#wasm32-boundary),
and a whole program's in [the slow tier](08_slow_tier.md). The x86 and AArch64
backends in the 0.6.0-beta tag compile neither runs nor slow code. The
unreleased development compiler adds native C programs with slow orchestration
and Rake-selected register kernels. Slow callers can pass uniform `f32`
arguments and receive `f32` results. SSE2, AVX2, AVX-512 and NEON also support the
[native stream subset](02_packs_and_run.md#native-cpu-streams).
General native runs and other scalar kernel boundaries remain work in progress.

## Verification

`--verify-native` assembles the emitted code, or compiles the emitted C,
then disassembles the object and checks register kernels:

- x86 profiles: only instructions from the profile's list, no calls, no stack
  register, no memory operand except a constant load relative to `rip`, every
  rack in a whole XMM, YMM or ZMM register, cross-lane instructions only in reductions and
  scans, and exactly the fused multiply-adds the compiler selected.
- `aarch64-neon`: only listed instructions, no calls, no stack, no `v8` to
  `v15`, no general or scalar float registers, loads only of literal
  constants, every rack in a whole 128-bit register, no lane extraction except
  the `dup` of a uniform, and exactly the selected fused multiply-adds.
- `wasm-simd128`: a scratch or rake contains only locals, constants, and SIMD
  and scalar register instructions, with no calls, memory or branches.

The C compiler and disassembler are `$RAKE_WASM_CC` (default `clang`) and
`$RAKE_WASM_OBJDUMP` (default `llvm-objdump`). Clang may exchange one vector
instruction for an equivalent one, such as a splatted zero for a constant, or
compute arithmetic on splats of uniforms as scalars and splat the result. The
verifier accepts both, because both stay in registers.

Native streams have explicit loop and memory instructions. Their verifier
compares each complete function with the separately assembled selection,
including its literal bytes, and rejects unresolved relocations. The
[native CPU stream contract](02_packs_and_run.md#native-cpu-streams)
defines their supported transfers and caller obligations.
