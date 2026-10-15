# Primitives, operations, and targets

A rack is one vector value. Its type gives its element, so `f32s` is a rack
of `f32` lanes, and the target profile gives its width.

## Profiles

| Profile | Register | `f32` lanes | Status |
| --- | --- | ---: | --- |
| `x86-sse2` | one 128-bit XMM register, SSE2 | 4 | `f32s` and the 32-bit integer subset below, as GNU assembly |
| `x86-avx2` | one 256-bit YMM register, AVX2 and FMA3 | 8 | `f32s` and the 32-bit integer subset below, as GNU assembly |
| `x86-avx512` | one 512-bit ZMM register, AVX-512F | 16 | `f32s` and the 32-bit integer subset below, as GNU assembly |
| `aarch64-neon` | one 128-bit vector register, AAPCS64 | 4 | `f32s` and the 32-bit integer subset below, as GNU assembly |
| `wasm-simd128` | one `v128` | 4 | float and integer scratches and rakes, runs and whole programs, as C |
| `wasm-simd128-relaxed` | one `v128` | 4 | `wasm-simd128` and the relaxed SIMD operations |
| `scalar` | none | 1 | WIP*, without the one-register guarantee |

*WIP: work in progress, and the compiler rejects it.*

`--target native`, the default, chooses the strongest available profile:
AVX-512F, then AVX2 with FMA, then SSE2 on x86, or Advanced SIMD on AArch64.
The compiler rejects other targets, including the proposed
[GPU profiles](../GPU.md). `--width n` asserts the `f32` lane count, and a
mismatch with the profile is an error, because the compiler never splits or
narrows a rack.

## Float racks

Rake 0.7.0 compiles these operations on `f32s` racks:

| Operation | `x86-sse2` | `x86-avx2` | `x86-avx512` | `aarch64-neon` | `wasm-simd128` |
| --- | :-: | :-: | :-: | :-: | :-: |
| `+` `-` `*` `/`, negation, `sqrt`, `abs`, `min` `max`, `floor` `ceil` `trunc` `nearest` | yes | yes | yes | yes | yes |
| comparisons, `and` `or` `not` on masks, `select`, `if` on a mask | yes | yes | yes | yes | yes |
| `if` on a direct uniform `f32`, `i32` or `u32` comparison, or a Boolean uniform | yes | yes | yes | yes | yes |
| `to_i32` `to_u32` (nearest-even, saturating) | yes | yes | yes | yes | yes |
| `sum` `product` `minimum` `maximum`, the scans, `extract`, `insert`, `shuffle` | yes | yes | yes | yes | yes |
| `all` `any` `bitmask` on float comparison masks | yes | yes | yes | yes | yes |
| arithmetic on `f32`, `i32` and `u32` uniform results, and unary minus on `f32` and `i32` uniforms, in register kernels | yes | yes | yes | yes | yes |
| `fma(a, b, c)` | ISA limit† | yes | yes | yes | ISA limit† |
| `exp` `log` `log2` `tanh` | WIP* | WIP* | WIP* | WIP* | yes |

†`fma(a, b, c)` is `a * b + c` with one rounding. SSE2 and strict
WebAssembly SIMD have no fused multiply-add instruction, so they reject it.

A scratch or rake may return a rack, a mask, a scalar from a float reduction
or extraction, a `bool` from `all` or `any`, or a `u32` from `bitmask`. `%` has no float form, and `true` and
`false` have no rack form, so a mask comes from a comparison. `sin`, `cos`,
`tan`, `pow` and `atan2` type-check but have no lowering, so the compiler
rejects them on every profile.

`select(mask, a, b)` takes `a` in the mask's lanes and `b` elsewhere, and so
does `if mask then a else b`. `if <c> then a else b` with a uniform condition,
which can be a Boolean from `all` or `any`, chooses one rack for every
participating lane, as [control flow](05_control_flow.md) describes.

`abs` takes the magnitude of each lane, changing −0 to +0. It's a bitwise
operation, so it raises no floating-point exception.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch magnitudes(values: f32s) -> f32s:
  abs(values)
```

`min(a, b)` and `max(a, b)` are IEEE 754 minimum and maximum: a quiet NaN if
either lane is NaN, and −0 below +0.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch clamp(values: f32s, <low: f32>, <high: f32>) -> f32s:
  min(max(values, <low>), <high>)
```

`floor`, `ceil`, `trunc` and `nearest` round each lane to an integral float.
`floor` rounds towards negative infinity,
`ceil` towards positive infinity, and `trunc` towards zero. `nearest` chooses
the nearest integer with ties to even, so 1.5 becomes 2 and 2.5 also becomes 2.
A zero result keeps the input's sign, infinities stay unchanged and NaNs
become quiet NaNs.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch whole_values(values: f32s) -> f32s:
  nearest(values)
```

## Integer racks

Integer arithmetic on racks wraps. The physical profiles compile this
`i32s` and `u32s` subset, with the same lane counts as `f32s`:

| Native operation | `i32s` | `u32s` |
| --- | :-: | :-: |
| wrapping `+`, `-` and `*`, `min` and `max`, the six lane comparisons | yes | yes |
| `bit_and`, `bit_or`, `bit_xor`, `bit_andnot`, and bit shifts by a literal from 0 to 31 or a uniform `u32` | yes | yes |
| selection with a lane mask, and `all`, `any` and `bitmask` of a comparison | yes | yes |
| literal and marked uniform broadcasts, and `if` on a direct comparison of uniforms | yes | yes |
| static one- and two-rack `shuffle`, literal-index `extract` and `insert` | yes | yes |
| `bitcast` to `i32s`, `u32s` or `f32s`, and `to_f32` | yes | yes |
| reductions and inclusive scans | yes | yes |
| negation and `abs` | yes | WIP* |

Rack work stays in full vector registers, with no scalar loop over lanes,
and the compiler rejects a kernel that would need to spill.
[The backend](../BACKEND.md) lists each profile's instruction sequences.
Integer and float masks can select either kind of rack. The
[native stack runs](02_packs_and_run.md#stack-runs) accept `f32`, `i32` and
`u32` columns, and `widen` loads signed byte and 16-bit columns into `i32s`,
or unsigned ones into `u32s`.

`bitcast` keeps every bit while changing the rack's element type, so −1 in
an `i32s` lane becomes 4294967295 in `u32s`. Float zero signs and NaN
payloads survive a round trip without raising a floating-point exception.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch unsigned_bits(values: i32s) -> u32s:
  bitcast(u32s, values)

scratch float_bits(values: f32s) -> u32s:
  bitcast(u32s, values)

scratch floats_from_bits(values: u32s) -> f32s:
  bitcast(f32s, values)
```

An integer literal passed to a typed parameter takes that parameter's type
and range, so a `u32` parameter can receive `<4294967295>`, while an untyped
literal keeps the signed `i32` range. A typed rack binding, such as
`let values: u32s = <value>`, broadcasts the uniform across every lane.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch unsigned_identity(<value: u32>) -> u32:
  <value>

scratch unsigned_limit() -> u32:
  unsigned_identity(<4294967295>)

scratch repeated_bits(<value: u32>) -> u32s:
  let values: u32s = <value>
  values
```

Negation and `abs` wrap too, so both give −2³¹ for −2³¹, and unary minus
takes signed racks only. Multiplication keeps the low 32 bits of each
product. `u32s` comparisons, `min` and `max` order lanes from 0 to 2³²−1,
so a lane with bit 31 set is larger than one without it.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch increment(values: u32s) -> u32s:
  values + <1>

scratch negate(values: i32s) -> i32s:
  -values

scratch magnitude(values: i32s) -> i32s:
  abs(values)

scratch product(a: u32s, b: u32s) -> u32s:
  a * b

scratch clamp_signed(values: i32s) -> i32s:
  min(max(values, <-17>), <29>)

scratch clamp_unsigned(values: u32s) -> u32s:
  min(max(values, <2147483648>), <4294967294>)

scratch greater(a: i32s, b: i32s) -> i32s:
  if a > b then a else b

scratch negative_bits(values: i32s) -> u32:
  bitmask(values < <0>)

scratch unsigned_high_bits(values: u32s) -> u32:
  bitmask(values >= <2147483648>)
```

WebAssembly supports a wider integer operation set, shown in the next table.
On its 128-bit register a `u8s` rack has 16 lanes, `i16s` 8, `i32s` and
`u32s` 4, and `i64s` and `u64s` 2.

| Operation | `u8s` | `i16s` | `i32s` | `u32s` | `i64s` | `u64s` |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| `+` `-` | yes | yes | yes | yes | yes | yes |
| `*` | WIP* | yes | yes | yes | yes | yes |
| negation | WIP* | yes | yes | WIP* | yes | WIP* |
| `abs` | yes | yes | yes | WIP* | yes | WIP* |
| `min` `max` | yes | yes | yes | yes | WIP* | WIP* |
| comparisons, and so `select` and `bitmask` | yes | yes | yes | yes | yes | WIP* |
| bitwise operations and bit shifts | yes | yes | yes | yes | yes | yes |
| `shuffle` `extract` `insert` | yes | yes | yes | yes | yes | yes |
| `sum` `product` `minimum` `maximum` | WIP* | WIP* | yes | yes | WIP* | WIP* |
| `scan_sum` `scan_product` `scan_minimum` `scan_maximum` | WIP* | WIP* | yes | yes | WIP* | WIP* |

`u8s` and `u32s` lanes compare unsigned, and the other integer racks
compare signed. `abs` of a `u8s` rack treats its lanes as signed bytes, and
no integer rack divides. Reductions and scans wrap, and their extrema
follow the input's signedness. An integer literal beside an integer rack is
broadcast in the rack's element type, as in `a + 1` or `min(a, <0>)`.

Conversions between integer and float racks:

- `dot(a, b)` takes two `i16s` racks and returns an `i32s` rack whose lane
  `i` is `a[2i] * b[2i] + a[2i+1] * b[2i+1]`, wrapping.
- `narrow(a, b)` takes two `i32s` racks and returns one `i16s` rack, `a`'s
  lanes then `b`'s, each saturated to the 16-bit range.
- `widen_low(x)` and `widen_high(x)` take the low or high eight lanes of a
  `u8s` rack, zero-extended to an `i16s` rack.
- `to_f32(x)` converts an `i32s` or `u32s` rack to `f32s`, rounding to nearest with
  ties to even.
- `to_i32(x)` converts an `f32s` rack to `i32s`, rounding to nearest with ties
  to even and saturating to the 32-bit range. NaN becomes zero.
- `to_u32(x)` converts an `f32s` rack to `u32s`, with the same rounding rule.
  Negative values and NaNs become zero, and values above 4294967295 saturate
  to that endpoint.
- `bitcast(i32s, x)` keeps the bits of a rack and changes its element type.

`to_f32`, `to_i32` and `to_u32` also compile on the physical profiles, in
register kernels and native stack runs. Inactive lanes inside `through` and
partial racks convert zero instead of their value, while an active
signalling NaN can raise invalid-operation and an active conversion can
raise inexact, under the caller's
[floating-point environment](#floating-point-values).

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch signed_floats(values: i32s) -> f32s:
  to_f32(values)

scratch unsigned_floats(values: u32s) -> f32s:
  to_f32(values)

scratch rounded_integers(values: f32s) -> i32s:
  to_i32(values)

scratch rounded_unsigned_integers(values: f32s) -> u32s:
  to_u32(values)
```

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
of one type bit by bit, and `bit_andnot(a, b)` computes `a & ~b`. Either
operand can be a marked uniform of the same type, and the result is a rack
even when both are.

`shift_bits_left(x, n)` moves each lane's bits towards its high end, filling
with zeros. `shift_bits_right(x, n)` moves them towards the low end, filling
with zeros, and `shift_bits_right_signed(x, n)` fills with the sign bit. The
count is an integer literal below the lane's width in bits, or a uniform
`u32` taken modulo that width.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch clear_bits(values: u32s, <removed: u32>) -> u32s:
  bit_andnot(values, <removed>)
```

The signed right shift copies each lane's high bit, even in a `u32s` rack.
A runtime `<amount: u32>` uses its low five bits on 32-bit lanes, so 32
means zero and 4294967295 means 31.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch high_bits(values: u32s) -> u32s:
  shift_bits_right(values, 24)

scratch sign_bits(values: i32s) -> i32s:
  shift_bits_right_signed(values, 31)

scratch shifted(values: u32s) -> u32s:
  shift_bits_left(values, 7)

scratch shifted_by(values: u32s, <amount: u32>) -> u32s:
  shift_bits_left(values, <amount>)
```

The reserved `shift_left`, `shift_right`, `rotate_left` and `rotate_right`
would move whole lanes, and are unavailable.

<!-- rake-check: verify wasm-simd128 -->
```rake
scratch step_east(here: u64s, open: u64s, board: u64s, <carry: u32>) -> u64s:
  let moving = bit_and(here, open)
  let moved = bit_or(shift_bits_left(moving, 1), shift_bits_right(moving, <carry>))
  bit_or(here, bit_and(moved, board))
```

## Lane extraction

`extract(values, 3)` takes lane 3 of a rack and returns its scalar value.
The index is an integer literal within the profile's width: 0–3 on SSE2 and
NEON, 0–7 on AVX2 and 0–15 on AVX-512. The physical profiles support `f32s`,
`i32s` and `u32s`, and WebAssembly all its rack types.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch fourth(values: f32s) -> f32:
  extract(values, 3)

scratch add_fourth(values: f32s) -> f32s:
  let <picked: f32> = extract(values, 3)
  values + <picked>

scratch fourth_unsigned(values: u32s) -> u32:
  extract(values, 3)
```

Extraction preserves every bit, including a signalling NaN, without raising
an exception, and an integer result keeps the rack's signedness. Native
stack runs reject extraction for now (WIP*).

## Lane insertion

`insert(values, 3, <replacement>)` produces a rack with lane 3 replaced by
a uniform of the same element type, and leaves `values` unchanged. The index
follows the same rules as extraction.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch replace_fourth(values: f32s, <replacement: f32>) -> f32s:
  insert(values, 3, <replacement>)

scratch copy_first_to_fourth(values: f32s) -> f32s:
  let <picked: f32> = extract(values, 0)
  insert(values, 3, <picked>)

scratch replace_fourth_unsigned(values: u32s, <replacement: u32>) -> u32s:
  insert(values, 3, <replacement>)
```

Insertion also preserves bits without raising an exception, and it's WIP*
in native stack runs.

## Shuffles

`shuffle(a, [i0, i1, ...])` builds a rack from lanes of `a` chosen by static
indices, one for each lane. `shuffle(a, b, [i0, i1, ...])` chooses from both,
with `b`'s lanes numbered after `a`'s as if the two racks were laid end to
end. Indices may repeat or omit input lanes, and the list needs one index
per output lane. The compiler reports a wrong count or an out-of-range index
at the shuffle. Shuffles support the same rack types as extraction.

<!-- rake-check: verify x86-sse2 aarch64-neon wasm-simd128 -->
```rake
scratch reversed(values: f32s) -> f32s:
  shuffle(values, [3, 2, 1, 0])

scratch interleaved(a: f32s, b: f32s) -> f32s:
  shuffle(a, b, [0, 4, 1, 5])

scratch interleaved_bits(a: u32s, b: u32s) -> u32s:
  shuffle(a, b, [0, 4, 1, 5])
```

These lists have four indices for the 128-bit profiles. AVX2 needs eight,
and AVX-512 sixteen:

<!-- rake-check: verify x86-avx2 -->
```rake
scratch rotated(values: f32s) -> f32s:
  shuffle(values, [1, 2, 3, 4, 5, 6, 7, 0])

scratch rotated_bits(values: i32s) -> i32s:
  shuffle(values, [1, 2, 3, 4, 5, 6, 7, 0])
```

Shuffles can cross the AVX2 register's 128-bit halves, and preserve each
lane's bits without raising an exception. They're WIP* in native stack runs.

## Bitmasks

`bitmask(mask)` returns a `u32` with one bit for each lane, lane zero in bit
zero, and zero above the lane count. `all(mask)` returns true when every
lane is true, and `any(mask)` when at least one is.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch positive_bits(values: f32s) -> u32:
  bitmask(values > <0.0>)

scratch every_positive(values: f32s) -> bool:
  all(values > <0.0>)

scratch some_positive(values: f32s) -> bool:
  any(values > <0.0>)
```

Boolean results are exactly zero or one. Inside a register kernel, a
`bitmask` result supports wrapping addition, subtraction and multiplication,
and further scalar operations are WIP*. Cross-lane reductions are forbidden
in a `through` block, and mask reductions are WIP* in native stack runs.
Masks from integer racks other than `i32s` and `u32s` reduce on WebAssembly
only:

<!-- rake-check: verify wasm-simd128 -->
```rake
scratch occupied_bits(tiles: u8s) -> u32:
  bitmask(tiles != <0>)
```

## Floating-point values

Float arithmetic is IEEE 754 binary32, rounded to nearest with ties to even.
Every comparison with a NaN operand is false, `!=` included, so `a != b`
means that `a` and `b` are ordered and different.

Native kernels inherit the caller's floating-point environment, and Rake
doesn't change it. The caller needs to select round-to-nearest with ties to
even and disable flushing subnormals to zero: `FTZ` and `DAZ` clear in
x86's `MXCSR`, and `FZ` clear in AArch64's `FPCR`. NEON also needs
`FPCR.AH` clear where it exists, because that bit changes `fmin` and
`fmax`'s NaN and signed-zero rules, as the
[Arm instruction reference](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
describes.

Native comparisons, `min` and `max` raise invalid-operation only for a
signalling NaN in an active lane.

`wasm-simd128` contracts nothing, so the target and `rakec --interpret`
agree on every result bit that isn't a NaN. `x86-avx2`, `x86-avx512` and
`aarch64-neon` contract an `f32` multiply and an add into one fused
multiply-add when both are in one fused region, as
[fused bindings](04_fused_bindings.md) describe, and the result then has the
fused rounding. A NaN result's sign and payload aren't specified, except
where an operation defines them, as the strict minimum and maximum of
[reductions and scans](06_reductions_and_scans.md) do.

`exp`, `log`, `log2` and `tanh` use Cephes' single-precision polynomials as
fixed binary32 sequences, so the interpreter, the slow tier's C and the rack
code agree bit for bit.

## Relaxed SIMD

`--target wasm-simd128-relaxed` adds four operations.
`relaxed_madd(a, b, c)` and `relaxed_nmadd(a, b, c)` compute `a * b + c` and
`-(a * b) + c`, rounded once or twice as the machine chooses.
`relaxed_min(a, b)` and `relaxed_max(a, b)` return the machine's choice when
a lane is NaN or both are zeros of opposite sign. `wasm-simd128` rejects them,
and its verifier rejects any relaxed instruction. None is available inside a
`through` block.

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
convention. Rack, mask and `f32` parameters take the eight SSE-class argument
registers in their order of appearance. A uniform `f32` occupies the low
lane of an XMM register. A rack or mask uses XMM on SSE2, YMM on AVX2, or
ZMM on AVX-512. Native `i32s` and `u32s` use the same register class as
`f32s`, with a 32-bit integer in each lane. The result uses register zero of
the same class, or `xmm0` for a scalar `f32`. `all` and `any` return C
`bool` in `al`, with the full `eax` set to zero or one, and `bitmask`
returns `uint32_t` in `eax`.

`i32`, `u32` and `bool` uniforms take the six C integer argument registers,
`edi`, `esi`, `edx`, `ecx`, `r8d` and `r9d`, counted separately from the
SIMD registers, and move into vector registers at entry. An `i32` or `u32`
result returns in `eax`. A C `bool` argument's upper register bits are
unspecified, so Rake reads only its value bit. This follows the
[System V AMD64 ABI](https://gitlab.com/x86-psABIs/x86-64-ABI) and [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst).

| Profile | Rack arguments | Rack result | C caller flags |
| --- | --- | --- | --- |
| `x86-sse2` | `xmm0`–`xmm7` | `xmm0` | `-msse2` |
| `x86-avx2` | `ymm0`–`ymm7` | `ymm0` | `-mavx2 -mfma` |
| `x86-avx512` | `zmm0`–`zmm7` | `zmm0` | `-mavx512f` |

SSE2 reserves `xmm15` for instruction lowering and allocates the other 15
vector registers, while AVX2 has 16 and AVX-512 has 32.

In this scratch on AVX2, `a` arrives in `ymm0`, `scale` in `xmm1` and `b` in
`ymm2`:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch scaled_sum(a: f32s, <scale: f32>, b: f32s) -> f32s:
  a * <scale> + b
```

In this AVX2 scratch, `low` arrives in `edi`, `values` in `ymm0`, and `high`
in `esi`. Both uniforms take part in unsigned lane arithmetic:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch bounded_values(<low: u32>, values: u32s, <high: u32>) -> u32s:
  min(max(values, <low>), <high>)
```

On `aarch64-neon`, SIMD parameters take `v0` to `v7` in their order of
appearance, a uniform `f32` sits in the low lane of its register, and rack
and `f32` results return in `v0`. The integer results of `all`, `any` and
`bitmask` return in `w0`, following the C `bool` or `uint32_t` ABI. Integer
and Boolean uniforms take `w0` to `w7` with a separate counter, then move
into allocated vector registers at entry. Signed and unsigned 32-bit results
also return in `w0`. The register allocator uses `v0` to `v7` and `v16` to
`v31`, because AAPCS64 makes the low halves of `v8` to `v15` callee-saved,
and saving them would need the stack.

On `wasm-simd128`, the function is C, `static inline` unless
`RAKE_WASM_LINKAGE` is defined. A rack or mask is a `v128_t`, a uniform `f32`
a `float`, a 64-bit uniform a `uint64_t`, and any other uniform, `bool` or
`bitmask` result a `uint32_t`. A slow caller's boundary wrapper uses
`int32_t` for signed `i32` values, with the same bits.

A numeric uniform is broadcast across the rack at each use, such as
`<scale>`. A run's boundary is in
[packs and runs](02_packs_and_run.md#the-c-boundary), and a whole program's
in [the slow tier](08_slow_tier.md).

## Verification

`--verify-native` assembles the emitted code, or compiles the emitted C,
then disassembles the object and checks register kernels:

- x86 profiles: only instructions from the profile's list, no calls, no stack
  register, no memory operand except a constant load relative to `rip`, every
  rack in a whole XMM, YMM or ZMM register, cross-lane instructions only in
  selected reductions, scans, extractions, insertions and shuffles, and exactly
  the compiler's selected fused multiply-adds.
- `aarch64-neon`: only listed instructions, no calls, no stack, no `v8` to
  `v15`, no scalar arithmetic, loads only of literal constants, every rack in
  a whole 128-bit register, lane broadcasts and insertion only in selected
  cross-lane functions (reductions, scans, extractions, insertions and
  shuffles, plus uniform broadcasts), and exactly the selected fused
  multiply-adds.
- `wasm-simd128`: a scratch or rake contains only locals, constants, and SIMD
  and scalar register instructions, with no calls, memory or branches.

A native `bool`, `i32` or `u32` result has one additional permitted
instruction: the transfer from the low lane of vector register zero into the
platform's integer return register, immediately before `ret`. This exception
permits neither scalar arithmetic nor an intermediate scalar lane transfer.

On WebAssembly, clang may exchange one vector instruction for an equivalent
one, such as a splatted zero for a constant, or compute arithmetic on splats
of uniforms as scalars and splat the result. The verifier accepts both,
because both stay in registers.

Native stack runs have explicit loop and memory instructions. Their verifier
compares each complete function with the separately assembled selection,
including its literal bytes, and rejects unresolved relocations.
[The C boundary](02_packs_and_run.md#the-c-boundary) defines the callers'
obligations.
