# Primitives, operations, and targets

A rack is one vector value on the current CPU and WebAssembly profiles.
Its type specifies its element: `f32s` is a
rack of `f32` lanes. The target profile gives its width. This page
defines the profiles, the operations each one compiles, the floating-point
rules and the calling conventions of scratches and rakes.

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

The table shows operations on `f32s` racks in the development compiler.
Physical profiles gained `abs`, `min`, `max` and integral rounding after the 0.6.0-beta tag,
so the tagged compiler still rejects them on those profiles. Native float
extraction, insertion, static shuffles, mask reductions, uniform
conditionals and NEON folds are also development
features after that tag.

| Operation | `x86-sse2` | `x86-avx2` | `x86-avx512` | `aarch64-neon` | `wasm-simd128` |
| --- | :-: | :-: | :-: | :-: | :-: |
| `+` `-` `*` `/`, negation, `sqrt` | yes | yes | yes | yes | yes |
| comparisons, `and` `or` `not` on masks, `select`, `if` on a mask | yes | yes | yes | yes | yes |
| `fma(a, b, c)` | ISA limit† | yes | yes | yes | ISA limit† |
| `abs` | yes | yes | yes | yes | yes |
| `min` `max` | yes | yes | yes | yes | yes |
| `floor` `ceil` `trunc` `nearest` | yes | yes | yes | yes | yes |
| `to_i32` (nearest-even, saturating signed conversion) | yes | yes | yes | yes | yes |
| `to_u32` (nearest-even, saturating unsigned conversion) | yes | yes | yes | yes | yes |
| `exp` `log` `log2` `tanh` | WIP* | WIP* | WIP* | WIP* | yes |
| `if` on a direct uniform `f32` comparison | yes | yes | yes | yes | yes |
| `if` on a direct uniform `i32` or `u32` comparison | yes | yes | yes | yes | yes |
| `if` on a Boolean uniform condition | yes | yes | yes | yes | yes |
| `sum` `product` `minimum` `maximum`, and the scans | yes | yes | yes | yes | yes |
| `extract` | yes | yes | yes | yes | yes |
| `insert` | yes | yes | yes | yes | yes |
| `shuffle` | yes | yes | yes | yes | yes |
| `all` `any` `bitmask` on float comparison masks | yes | yes | yes | yes | yes |

*WIP: work in progress. Compilation fails for these cells.* †SSE2 and strict
WebAssembly SIMD have no fused multiply-add instruction. Their rejection of
explicit `fma` preserves its single-rounding semantics, rather than indicating
an unfinished lowering. Relaxed WebAssembly SIMD is a separate opt-in profile.

A scratch or rake may return a rack or a mask on every profile, a scalar from
a float reduction or extraction on every profile, a `bool` from `all` or
`any`, or a `u32` from `bitmask`. `%` has no float form, and `true` and `false` have
no rack form: a mask comes from a comparison. `sin`, `cos`, `tan`, `pow` and
`atan2` type-check but have no lowering, so the compiler rejects them on every
profile.

`select(mask, a, b)` takes `a` in the mask's lanes and `b` elsewhere, and so
does `if mask then a else b`. `if <c> then a else b` with a uniform condition
chooses one rack for every participating lane. Native uniform comparisons use
vector broadcasts and comparisons, with benign operands for untaken branch
work. [Control flow](05_control_flow.md) gives the supported forms.
Boolean uniforms expand their value bit into an all-lane mask before native
selection, including results of `all` and `any`.
`abs` takes the magnitude of each lane,
including changing −0 to +0. Native profiles clear the sign bit with a vector
bitwise operation, without floating-point arithmetic or exceptions.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch magnitudes(values: f32s) -> f32s:
  abs(values)
```

`min(a, b)` and `max(a, b)` are IEEE 754 minimum and maximum on every
implemented profile: a quiet NaN if either lane is NaN, and −0 below +0.
The native x86 profiles use vector comparisons and selections, with five
temporary registers included in the no-spill allocation check. NEON uses
full-width `fmin` and `fmax`.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch clamp(values: f32s, <low: f32>, <high: f32>) -> f32s:
  min(max(values, <low>), <high>)
```

`floor`, `ceil`, `trunc` and `nearest` round each lane to an integral float
on every implemented profile. `floor` rounds towards negative infinity,
`ceil` towards positive infinity, and `trunc` towards zero. `nearest` chooses
the nearest integer with ties to even, so 1.5 becomes 2 and 2.5 also becomes 2.
A zero result retains the input's sign, including −0.5 rounding to −0.
Infinities stay unchanged and NaNs become quiet NaNs.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch whole_values(values: f32s) -> f32s:
  nearest(values)
```

`fma(a, b, c)` is `a * b + c` with one
rounding. It says the program depends on that rounding, which `wasm-simd128`
can't provide, so it rejects `fma` rather than computing it with two.

## Integer racks

Integer arithmetic on racks wraps. The development compiler adds a native
`i32s` and `u32s` subset after the 0.6.0-beta tag. Both types have four lanes
on SSE2 and NEON, eight on AVX2, or sixteen on AVX-512F.

| Native operation | `i32s` | `u32s` |
| --- | :-: | :-: |
| wrapping `+`, `-` and `*` | yes | yes |
| signed negation | yes | WIP* |
| signed `abs` | yes | WIP* |
| `min` and `max` (signed or unsigned) | yes | yes |
| `bit_and`, `bit_or`, `bit_xor`, `bit_andnot` | yes | yes |
| bit shifts with literal counts from 0 to 31 | yes | yes |
| six lane comparisons (signed or unsigned) | yes | yes |
| select an integer rack with a lane mask | yes | yes |
| `all`, `any`, `bitmask` of a comparison | yes | yes |
| integer literal broadcast | yes | yes |
| marked `i32` or `u32` uniform arguments and broadcasts | yes | yes |
| `if` on a direct comparison of marked uniforms | yes | yes |
| static one- and two-rack `shuffle` | yes | yes |
| `bitcast` between `i32s` and `u32s` | yes | yes |
| `to_f32` (`i32s` or `u32s` to `f32s`) | yes | yes |
| literal-index `extract` and `insert` | yes | yes |
| runtime shift counts | WIP* | WIP* |

These operations stay in full vector registers. Integer masks can select
float racks, and float masks can select integer racks. The
[native stream subset](02_packs_and_run.md#native-cpu-streams) accepts `f32`,
`i32` and `u32` columns while preserving each column's type.
Explicit `widen` also loads signed byte and 16-bit columns into `i32s`, or
unsigned ones into `u32s`. The stored type determines sign or zero extension.
The [traversal contract](02_packs_and_run.md#native-cpu-streams) covers its
compact memory transfers and partial racks.

`bitcast(u32s, values)` reinterprets an `i32s` rack's bits as unsigned words,
and `bitcast(i32s, values)` does the reverse. A lane containing −1 becomes
4294967295 without changing a bit. The native allocator needs no instruction
when it can reuse the input register, or a vector register copy when the
input remains live. Numerical conversion uses `to_f32`, `to_i32` or `to_u32` instead.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch unsigned_bits(values: i32s) -> u32s:
  bitcast(u32s, values)
```

An integer literal passed to a typed scratch or rake parameter takes that
parameter's element type. A `u32` parameter can therefore receive
`<4294967295>`, while an untyped literal retains the signed `i32` range.
The compiler checks the literal against that type's range. An explicitly
typed rack binding, such as `let values: u32s = <value>`, broadcasts the
uniform across every lane.

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

Signed negation wraps too: negating −2³¹ gives −2³¹ because +2³¹ doesn't fit
in a signed 32-bit lane. Unary minus takes signed integer racks only.

`abs` also wraps at that boundary: `abs(−2³¹)` retains the same lane bits
and the signed result is −2³¹. SSE2 computes `(x xor sign) - sign`, with
the sign extended across each lane and one allocated temporary vector
register. AVX2 and AVX-512F use `vpabsd`, and NEON uses `abs .4s`.

Multiplication keeps the low 32 bits of each lane's product. AVX2, AVX-512F
and NEON each use one packed multiply instruction. SSE2 uses two packed
even-lane multiplies and four shuffles to restore all four lanes in order.
It needs two temporary vector registers, and refuses a rack expression that
would require spills. None of these profiles uses a scalar loop for `*`.

Signed `min` and `max` choose the smaller or larger lane value, including
−2³¹ and 2³¹−1. AVX2, AVX-512F and NEON each use a full-width packed
instruction. SSE2 compares the lanes with `pcmpgtd` and selects their bits
using vector logical operations, with one allocated mask register.

Unsigned `min` and `max` order lane values from 0 to 2³²−1, so values with
bit 31 set remain larger than those without it. AVX2 and AVX-512F use
`vpminud` and `vpmaxud`, and NEON uses `umin .4s` and `umax .4s`.
SSE2 flips bit 31 in two temporary copies before comparing them, then uses
the comparison mask to select the original lane bits. Those two copies and
the mask require three allocated temporary registers.

Both `i32s` and `u32s` support all six lane comparisons. An unsigned lane
orders 2³¹ above 2³¹−1 and 2³²−1 above both. SSE2 and AVX2 flip bit 31 in
two allocated temporary racks, then compare the transformed lanes as signed
integers. AVX-512F uses `vpcmpud`, and NEON uses `cmhi` or `cmhs` for
unsigned ordering. Equality compares the original lane bits.

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

`u8s` and `u32s` lanes compare unsigned, and the other supported integer
comparisons are signed.
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
- `to_f32(x)` converts an `i32s` or `u32s` rack to `f32s`, rounding to nearest with
  ties to even.
- `to_i32(x)` converts an `f32s` rack to `i32s`, rounding to nearest with ties
  to even and saturating to the 32-bit range. NaN becomes zero.
- `to_u32(x)` converts an `f32s` rack to `u32s`, with the same rounding rule.
  Negative values and NaNs become zero, and values above 4294967295 saturate
  to that endpoint.
- `bitcast(i32s, x)` keeps the bits of a rack and changes its element type.

On WebAssembly each numerical conversion above is one instruction except
`to_i32` and `to_u32`, which use `f32x4.nearest` then the signed or unsigned
`i32x4.trunc_sat_f32x4` instruction. A bitcast
reuses the same `v128` bits without a numerical conversion instruction.

`to_f32`, `to_i32` and `to_u32` also compile on all four physical CPU profiles,
in register kernels and the native stream subset. They preserve the lane
count. Signed `to_f32` uses a packed integer conversion. Unsigned conversion
uses a full-width unsigned instruction on AVX-512F and NEON. On SSE2 and
AVX2 it converts each lane's two 16-bit halves exactly, scales the high
half by 65,536 and adds the low half. Only that addition rounds. The
sequence uses three temporary vector registers, included in allocation
pressure. `to_i32` combines
packed comparisons, conversion and selections to preserve the saturation
and NaN rules above. It requires four temporary vector registers in addition
to its input and result, included in the no-spill allocation check.
`to_u32` also uses four temporaries. It removes NaNs, negatives and overflow
before conversion, then restores unsigned saturation with vector masks.
AVX-512F selects `vcvtps2udq`, and NEON selects `fcvtnu .4s`. SSE2 and AVX2
use signed conversion below 2³¹. Above that boundary, they subtract 2³¹
exactly, convert in parallel and restore the high integer bit.
All three conversions protect inactive lanes inside `through` and partial racks
by substituting zero before conversion. Active signalling NaNs can raise
invalid-operation exceptions, and an active conversion can raise inexact.
The caller's floating-point environment follows the
[native rounding contract](#floating-point-values).

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
of one type bit by bit, and `bit_andnot(a, b)` keeps the bits of `a` that `b`
doesn't set. A marked uniform of the same integer type can occupy either
operand. It broadcasts across the rack before the operation, as it does in
`min` and `max`. These built-ins produce a rack even when both operands are
uniforms.

`shift_bits_left(x, n)` moves each lane's bits towards its high
end, filling with zeros. `shift_bits_right(x, n)` moves them towards the low
end, filling with zeros, and `shift_bits_right_signed(x, n)` fills with the
sign bit. The count is an integer literal below the lane's width in bits, or
a uniform `u32` taken modulo that width.

The physical profiles implement `bit_andnot(a, b)` on `i32s` and `u32s`
with a full-width packed instruction. SSE2 uses `andnps`, AVX2 uses
`vandnps`, AVX-512F uses `vpandnd`, and NEON uses `bic .16b`.
The x86 instructions complement their first source, so Rake reverses the
instruction operands to preserve `a & ~b`.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch clear_bits(values: u32s, <removed: u32>) -> u32s:
  bit_andnot(values, <removed>)
```

The physical profiles support all three bit shifts on `i32s` and `u32s`
with literal counts from 0 to 31. Zero leaves the rack unchanged.
SSE2, AVX2 and AVX-512F use full-width packed shifts, and NEON uses
`shl`, `ushr` or `sshr` on four 32-bit lanes. The signed-right operation
copies each lane's high bit, even when the rack's element type is unsigned.
Runtime uniform counts remain WIP* on physical profiles.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch high_bits(values: u32s) -> u32s:
  shift_bits_right(values, 24)

scratch sign_bits(values: i32s) -> i32s:
  shift_bits_right_signed(values, 31)

scratch shifted(values: u32s) -> u32s:
  shift_bits_left(values, 7)
```

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

## Lane extraction

`extract(values, 3)` takes lane 3 of a rack and returns its scalar value.
Lane indices start at zero and must be integer literals within the selected
profile's width: 0–3 on SSE2 and NEON, 0–7 on AVX2, and 0–15 on AVX-512.
`wasm-simd128` supports extraction from its float and integer rack types.
The physical profiles support `f32s`, `i32s` and `u32s`.

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

The first scratch returns one scalar. The second broadcasts that scalar back
across the rack before adding it to the original values. Native extraction
uses full-width vector lane transfers, then returns the selected low lane
through the scalar C ABI. Integer results use the platform's integer return
register, and their signedness follows the input rack. The transfers preserve
every bit, including a signalling NaN in a float rack, without floating-point
arithmetic or exceptions.
Native stream traversal still rejects extraction until its partial-rack
participation contract is implemented.

## Lane insertion

`insert(values, 3, <replacement>)` produces a rack with lane 3 replaced by
the uniform of the same element type. Every other lane keeps its original
bits. The index is a literal with the same profile bounds as extraction, and `values` remains
available after the operation.

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

The first scratch replaces one lane with an argument. The second copies
the first lane into the fourth, leaving the other lanes unchanged. These
transfers preserve signed zeros and NaN payloads without floating-point
arithmetic or exceptions. The physical profiles support `f32s`, `i32s` and
`u32s`, while WebAssembly also supports its other integer racks. Native stream
insertion remains WIP* until its partial-rack participation contract is implemented.

## Shuffles

`shuffle(a, [i0, i1, ...])` builds a rack from lanes of `a` chosen by static
indices, one for each lane. `shuffle(a, b, [i0, i1, ...])` chooses from both,
with `b`'s lanes numbered after `a`'s as if the two racks were laid end to
end. Indices may repeat or omit input lanes. The list must contain exactly
the output rack's lane count, and each index must be within its one or two
input racks. The physical profiles support `f32s`, `i32s` and `u32s`.
WebAssembly also supports its other integer rack types.

<!-- rake-check: verify x86-sse2 aarch64-neon wasm-simd128 -->
```rake
scratch reversed(values: f32s) -> f32s:
  shuffle(values, [3, 2, 1, 0])

scratch interleaved(a: f32s, b: f32s) -> f32s:
  shuffle(a, b, [0, 4, 1, 5])

scratch interleaved_bits(a: u32s, b: u32s) -> u32s:
  shuffle(a, b, [0, 4, 1, 5])
```

These lists produce four lanes on the 128-bit profiles. AVX2 needs eight
indices, and AVX-512 needs sixteen. The compiler reports a width mismatch
or an out-of-range index at the shuffle's source line.

<!-- rake-check: verify x86-avx2 -->
```rake
scratch rotated(values: f32s) -> f32s:
  shuffle(values, [1, 2, 3, 4, 5, 6, 7, 0])

scratch rotated_bits(values: i32s) -> i32s:
  shuffle(values, [1, 2, 3, 4, 5, 6, 7, 0])
```

This rotation crosses the AVX2 register's 128-bit subdivisions. Shuffles
preserve each selected lane's bits, including signed zeros and signalling
NaN payloads, without floating-point arithmetic or exceptions. Integer
shuffles use the same bit-preserving transfers, including lanes whose high
bit is set. The selected
native sequences keep their temporary values in vector registers and count
those registers in the no-spill allocation check.
Native stream shuffles remain WIP* until their partial-rack participation
contract is implemented.

## Bitmasks

`bitmask(mask)` returns a `u32` with one bit for each lane, lane zero in bit
zero. `all(mask)` returns true when every lane is true, and `any(mask)` when
at least one is true. These results are scalars. A mask from a float
comparison has four bits on SSE2, NEON and WebAssembly, eight on AVX2, or
sixteen on AVX-512F. Bits above that width are zero.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch positive_bits(values: f32s) -> u32:
  bitmask(values > <0.0>)

scratch every_positive(values: f32s) -> bool:
  all(values > <0.0>)

scratch some_positive(values: f32s) -> bool:
  any(values > <0.0>)
```

Physical profiles reduce these masks with full-width permutations and bitwise
operations. The compiler checks one temporary vector register in addition to
the result. At the function boundary, the low 32 bits pass to `eax` on x86
or `w0` on AArch64. Boolean results are exactly zero or one. The object verifier
permits that transfer only immediately before the return of a source-declared
integer result. General scalar arithmetic on these results inside a native
scratch remains WIP*. Cross-lane reductions are forbidden in a `through`
block. Native stream mask reductions remain WIP* until their partial-rack
participation contract is implemented.

The native profiles also reduce `i32s` and `u32s` comparison masks. Masks from other
integer element types remain available on WebAssembly only:

<!-- rake-check: verify wasm-simd128 -->
```rake
scratch occupied_bits(tiles: u8s) -> u32:
  bitmask(tiles != <0>)
```

## Floating-point values

Float arithmetic is IEEE 754 binary32, rounded to nearest with ties to even.
Every comparison with a NaN operand is false, `!=` included, so `a != b`
means that `a` and `b` are ordered and different.

Native kernels inherit the caller's floating-point environment. The caller
must select round-to-nearest with ties to even and disable flushing subnormals
to zero: `FTZ` and `DAZ` are clear in x86's `MXCSR`, and `FZ` is clear in
AArch64's `FPCR`. NEON also requires `FPCR.AH` clear on processors with
alternative floating-point handling. That bit changes `fmin` and `fmax`'s
NaN and signed-zero rules, as the [Arm instruction reference](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
describes. Rake doesn't change these control registers on entry or exit.

Native CPU comparisons don't raise invalid-operation exceptions for quiet
NaNs. SSE2 implements `<` and `<=` by checking for ordered operands, making
unordered operands benign, then comparing the racks. NEON uses that approach
for its ordered inequalities and `!=`. Their extra mask and operand registers
are included in the allocator's pressure check. Signalling NaNs can still
raise an invalid-operation exception.

Native `min` and `max` likewise leave quiet NaNs quiet and raise invalid
for an active signalling NaN. Their masked lowering substitutes benign
operands in inactive lanes, so a signalling NaN in a gap cannot raise that
exception.

`wasm-simd128` contracts nothing, so the target and `rakec --interpret`
agree on every result bit that isn't a NaN. `x86-avx2`, `x86-avx512` and `aarch64-neon`
contract an `f32` multiply and an add into one fused multiply-add when both are in
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
convention. Rack, mask and `f32` parameters take the eight SSE-class argument
registers in their order of appearance. A uniform `f32` occupies the low lane of an XMM register. A rack or
mask uses XMM on SSE2, YMM on AVX2, or ZMM on AVX-512. Native `i32s` and
`u32s` use the same register class as `f32s`, with a 32-bit integer in each
lane. The result uses register
zero of the same class, or `xmm0` for a scalar `f32`.
`all` and `any` return C `bool` in `al`, with the full `eax` set to zero or
one. `bitmask` returns `uint32_t` in `eax`.

The development compiler also takes `i32`, `u32` and `bool` uniforms through the
six C integer argument registers: `edi`, `esi`, `edx`, `ecx`, `r8d` and `r9d`.
This counter advances independently of the SIMD counter. At entry, Rake
imports each integer's 32 bits into an allocated vector register. `<value>`
then broadcasts a numeric uniform's bits across the rack. The object verifier checks each
declared import at entry and refuses further integer-register transfers in
the body. An `i32` or `u32` result returns its low 32 bits in `eax`.
For a C `bool` argument, packed shifts retain only the Boolean value bit,
ignoring unspecified upper register bits. A Boolean condition then expands
that bit into a vector mask. This follows the
[System V AMD64 ABI](https://gitlab.com/x86-psABIs/x86-64-ABI) and
[AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst).

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

In this AVX2 scratch, `low` arrives in `edi`, `values` in `ymm0`, and `high`
in `esi`. Both uniforms participate in unsigned lane arithmetic:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch bounded_values(<low: u32>, values: u32s, <high: u32>) -> u32s:
  min(max(values, <low>), <high>)
```

On `aarch64-neon`, SIMD parameters take `v0` to `v7` in their order of appearance, a uniform
`f32` in the low lane of its register, and rack and `f32` results return in
`v0`. The integer results of `all`, `any` and `bitmask` return in `w0`, following
the C `bool` or `uint32_t` ABI. Integer and Boolean uniforms take `w0` to `w7` with a
separate counter, then move into allocated vector registers at entry.
Signed and unsigned 32-bit results also return in `w0`.
The register allocator uses `v0` to `v7` and
`v16` to `v31`, because AAPCS64
makes the low halves of `v8` to `v15` callee-saved, and saving them would need
the stack.

On `wasm-simd128`, the function is C, `static inline` unless
`RAKE_WASM_LINKAGE` is defined. A rack or mask is a `v128_t`, a uniform `f32`
a `float`, a 64-bit uniform a `uint64_t`, and any other uniform, `bool` or
`bitmask` result a `uint32_t`. A slow caller's boundary wrapper uses
`int32_t` for signed `i32` values, preserving the same bits.

Each uniform keeps its brackets at its declaration, `<scale: f32>`, and at its
use, `<scale>`. For numeric uniforms, the use is where the broadcast happens:
`vbroadcastss` on AVX2 and AVX-512, `shufps` on SSE2, `dup` on NEON and a
splat on wasm.

A run's boundary is in [packs and runs](02_packs_and_run.md#wasm32-boundary),
and a whole program's in [the slow tier](08_slow_tier.md). The x86 and AArch64
backends in the 0.6.0-beta tag compile neither runs nor slow code. The
unreleased development compiler adds native C programs with slow orchestration
and Rake-selected register kernels. Slow callers can pass uniform `f32`,
`i32`, `u32` or `bool` arguments and receive `f32`, `bool`, `i32` or `u32` results.
SSE2, AVX2, AVX-512 and NEON also support the
[native stream subset](02_packs_and_run.md#native-cpu-streams).
General native runs and other scalar kernel boundaries remain work in progress.

## Verification

`--verify-native` assembles the emitted code, or compiles the emitted C,
then disassembles the object and checks register kernels:

- x86 profiles: only instructions from the profile's list, no calls, no stack
  register, no memory operand except a constant load relative to `rip`, every
  rack in a whole XMM, YMM or ZMM register, cross-lane instructions only in
  selected reductions, scans, extractions, insertions and shuffles, and exactly the fused
  multiply-adds the compiler selected.
- `aarch64-neon`: only listed instructions, no calls, no stack, no `v8` to
  `v15`, no scalar arithmetic, loads only of literal
  constants, every rack in a whole 128-bit register, lane broadcasts and
  insertion only in selected cross-lane functions (reductions, scans,
  extractions, insertions and shuffles, plus uniform broadcasts), and exactly the selected fused
  multiply-adds.
- `wasm-simd128`: a scratch or rake contains only locals, constants, and SIMD
  and scalar register instructions, with no calls, memory or branches.

A native `bool`, `i32` or `u32` result has one additional permitted instruction:
the transfer from the low lane of vector register zero into the platform's
integer return register, immediately before `ret`. This exception permits
neither scalar arithmetic nor an intermediate scalar lane transfer.

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
