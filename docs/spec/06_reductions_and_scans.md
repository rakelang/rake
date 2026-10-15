# Reductions and scans

A reduction combines every lane of a rack into one scalar. A scan returns a
rack whose lane `i` holds the reduction of lanes 0 to `i`. Both are spelled
as identifiers rather than operators, so they're easy to find in code and to
read aloud.

| Form | Operand | Result | Each step |
| --- | --- | --- | --- |
| `sum(x)` | `f32s` | `f32` | binary32 addition |
| `product(x)` | `f32s` | `f32` | binary32 multiplication |
| `minimum(x)` | `f32s` | `f32` | strict minimum |
| `maximum(x)` | `f32s` | `f32` | strict maximum |
| `sum(x)` | `i32s` / `u32s` | matching `i32` / `u32` | wrapping 32-bit addition |
| `product(x)` | `i32s` / `u32s` | matching `i32` / `u32` | wrapping 32-bit multiplication |
| `minimum(x)` / `maximum(x)` | `i32s` / `u32s` | matching `i32` / `u32` | signed / unsigned extrema |
| `all(m)` | mask | `bool` | and |
| `any(m)` | mask | `bool` | or |
| `bitmask(m)` | mask | `u32` | one bit per lane |
| `scan_sum(x)` | `f32s` | `f32s` | binary32 addition |
| `scan_product(x)` | `f32s` | `f32s` | binary32 multiplication |
| `scan_minimum(x)` | `f32s` | `f32s` | strict minimum |
| `scan_maximum(x)` | `f32s` | `f32s` | strict maximum |
| `scan_sum(x)` | `i32s` / `u32s` | same rack type | wrapping 32-bit addition |
| `scan_product(x)` | `i32s` / `u32s` | same rack type | wrapping 32-bit multiplication |
| `scan_minimum(x)` / `scan_maximum(x)` | `i32s` / `u32s` | same rack type | signed / unsigned extrema |

Nothing converts an operand to fit. `extract(x, lane)`, defined in [primitives, operations, and targets](01_primitives_operations_and_targets.md),
also turns a rack into a scalar.

A scratch can return a reduction's scalar, and in a run `let <x: T> = ...`
binds one as a uniform. This WebAssembly run computes the spread once, then
broadcasts it into the output rack:

<!-- rake-check: run 103 -->
```rake
scratch top(values: f32s) -> f32:
  maximum(values)

run prefix_sums(x: []f32, out: mut []f32):
  out[<0>] <- scan_sum(x[<0>])

run spread(x: []f32, out: mut []f32):
  let <width: f32> = top(x[<0>]) - minimum(x[<0>])
  out[<0>] <- <width>

slow main() -> i32:
  values: [4]f32 := [1.0, 2.0, 3.0, 4.0]
  sums: [4]f32 := [0.0; 4]
  prefix_sums(values, sums)
  width: [4]f32 := [0.0; 4]
  spread(values, width)
  return i32(sums[3] * 10.0 + width[0])
```

Register kernels also accept arithmetic on uniform results, so subtracting a
rack's minimum from its maximum produces one `f32` value:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch spread(values: f32s) -> f32:
  maximum(values) - minimum(values)

scratch adjusted_counts(counts: u32s) -> u32s:
  let <offset: u32> = extract(counts, 0) * <4294967295> + 1
  counts + <offset>

scratch negative_total(values: f32s) -> f32:
  -sum(values)
```

`f32` uniforms support addition, subtraction, multiplication and division,
with a binary32 rounding at each step, while `i32` and `u32` support wrapping
addition, subtraction and multiplication. When the scalar meets a rack, mark
it as a uniform, as `<offset>` is above. Unary minus also accepts `f32` and
`i32` uniforms. Float negation flips the sign bit, preserving zero signs and
NaN payloads, and signed negation wraps, so negating −2147483648 gives
−2147483648. Arithmetic under a partial lane mask, including inside a masked
stack run, remains WIP* (*work in progress*).

## Lane order

For a float rack `x` of `N` lanes:

```text
p[0] = x[0]
p[i] = step(p[i - 1], x[i])    for i from 1 to N - 1
```

A reduction returns `p[N - 1]`, and a scan returns `p[0]` to `p[N - 1]`, so
every scan is inclusive. The fold always runs from lane 0 upwards. No
implementation may use a tree, reassociate, contract, or keep a wider
intermediate, so each addition and multiplication rounds to binary32 in turn.
A rack always has lanes, so there's no empty case and no identity value.

Mask reductions use associative bitwise operations, so their implementation
may combine lane groups in a tree. `all` and `any` give the same truth value
in any order, and `bitmask` preserves each lane's bit position.

Integer addition and multiplication wrap modulo 2³², including on signed
inputs, and integer extrema keep the input's signed or unsigned ordering.
These operations are associative, so an implementation can combine lane
groups in a tree without changing the result. A reduction includes every
lane, including values across the subdivisions of an AVX register. For a rack
holding `[2, 3, 1, 4]`, `scan_sum` gives `[2, 5, 6, 10]`. Each call starts a
new prefix at lane 0, and carrying a running prefix from one rack to the next
is separate work, in a general run's loop.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch total_counts(counts: u32s) -> u32:
  sum(counts)

scratch lowest_score(scores: i32s) -> i32:
  minimum(scores)

scratch counts_so_far(counts: u32s) -> u32s:
  scan_sum(counts)

scratch best_so_far(scores: i32s) -> i32s:
  scan_maximum(scores)
```

## Floating-point minimum and maximum

For floats, each step of `minimum`, `maximum`, `scan_minimum` and `scan_maximum`:

1. returns the quiet NaN `0x7fc00000` when either operand is NaN,
2. for two zeros, returns −0 from `minimum` when either is −0, and from
   `maximum` only when both are,
3. otherwise returns the smaller or larger operand, and the left one when
   they are equal.

Once a NaN enters, every later prefix and the reduction are that NaN. A
backend can't use a machine minimum or maximum directly where its NaN or
signed-zero rule differs.

## Restrictions and profiles

Each lane of a reduction or scan depends on the others, so neither can run
under a mask. They're rejected in a `through` block and in a stack run, where
the tail's mask would apply. They're also outside fused bindings, because a
reduction leaves the rack and a scan orders its lanes.

Every profile supports the reductions, scans and mask reductions on `f32s`,
`i32s`, `u32s` and float masks. Scans and reductions at other integer widths
remain WIP*.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch running_total(values: f32s) -> f32s:
  scan_sum(values)
```

| Profile | Float reduction or scan | Mask reductions |
| --- | --- | --- |
| `x86-sse2` | 3 ordered steps | 2 permute-and-combine stages |
| `x86-avx2` | 7 ordered steps | 3 stages |
| `x86-avx512` | 15 ordered steps | 4 stages |
| `aarch64-neon` | 3 steps, each broadcasting the next lane with `dup` before full-width arithmetic, with `ins` placing a scan's prefix | 2 stages |
| `wasm-simd128` | 3 steps, each moving a lane into place with `i8x16.shuffle` | `all` and `any` as `all_true` and `v128.any_true` |

The x86 steps use shuffles, permutations, blends and packed arithmetic. Where
a machine minimum or maximum handles NaN differently, a comparison afterwards
selects `0x7fc00000`. NEON uses a quiet comparison after `fmin` or `fmax`,
while `wasm-simd128` follows `f32x4.min` or `f32x4.max` with an `f32x4.ne`
self-comparison of each operand, a `v128.or` and a `v128.bitselect`, because
WebAssembly leaves a NaN result's payload unspecified.

Mask reductions combine with AND for `all` and OR for `any`, then a vector
mask converts the result to zero or one. `bitmask` first gives each true lane
its bit weight, then combines the weights with OR. Integer reductions combine
disjoint lane groups with full-width shuffles and packed arithmetic or
extrema. Integer scans combine prefixes at distances 1, 2, 4 and 8 as the
rack width requires, filling the initial lanes with the operation's neutral
value and carrying prefixes across AVX register subdivisions.

Integer reductions introduce no scalar lane arithmetic. A float result
returns in `xmm0` on x86 and in the low lane of `v0` on NEON, following
AAPCS64, while integer and mask results cross into the C integer return
register only once complete. The allocator counts NEON's intermediate
registers and the mask reductions' one temporary vector register, and the
object verifier permits lane transfers only in selected cross-lane
functions.
