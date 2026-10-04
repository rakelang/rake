# Reductions and scans

A reduction combines every lane of a rack into one scalar. A scan returns a
rack whose lane `i` holds the reduction of lanes 0 to `i`. Both have identifiers
rather than operators, so they are easy to find in code and to read aloud.

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

Nothing converts an operand to fit. Arithmetic reductions and scans accept
float or 32-bit integer racks, and `all` and `any`
require masks. `extract(x, lane)` and
`bitmask(m)`, defined in [primitives, operations, and targets](01_primitives_operations_and_targets.md),
also turn a rack into a scalar.

A scratch can return a reduction's scalar. In a run, `let <x: T> = ...` binds
one as a uniform. The following WebAssembly run computes the spread once,
then broadcasts it into the output rack:

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

Rake 0.7.0 also accepts arithmetic on uniform results inside
register kernels. For example, subtracting a rack's minimum from its maximum
produces one `f32` value:

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

Physical profiles broadcast the scalar operands into full racks, use packed
arithmetic and keep the completed result as a uniform. `f32` supports
addition, subtraction, multiplication and division with a binary32 rounding
at each step. `i32` and `u32` support wrapping addition, subtraction and
multiplication. Use a marked uniform when the scalar meets a rack, as
`<offset>` does above. Unary minus also accepts `f32` and `i32` uniforms,
including reduced or extracted values. Float negation flips the sign bit,
preserving zero signs and NaN payloads. Signed negation wraps, so negating
−2147483648 gives −2147483648. Arithmetic under a partial lane mask remains WIP*,
including inside a masked traversal. This support is included in Rake 0.7.0.

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
A rack always has lanes, so there is no empty case and no identity value.

Mask reductions use associative bitwise operations, so their implementation
may combine lane groups in a tree. `all` and `any` give the same truth value
in any order. `bitmask` preserves each lane's bit position.

Integer reductions return the same element type as their input, and integer
scans return the same rack type. Addition and multiplication wrap modulo 2³²,
including on signed inputs. Extrema retain
the input's signed or unsigned ordering. These operations are associative,
so their implementation can combine lane groups in a tree without changing
the result. A reduction includes every lane, including values across the
subdivisions of an AVX register. An integer scan includes lanes 0 through `i`
in its result at lane `i`. For a rack holding `[2, 3, 1, 4]`, `scan_sum`
gives `[2, 5, 6, 10]`.
Each call starts a new prefix at lane 0. Carrying a running prefix from one
traversal chunk to the next is separate work in the traversal's body.

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
under a mask. They are rejected in a `through` block and in a traversal,
where the tail's mask would apply. They are also outside fused bindings: a
reduction leaves the rack, and a scan orders its lanes.

| Profile | Reductions and scans | `all`, `any`, `bitmask` on float masks |
| --- | :-: | :-: |
| `x86-sse2` | yes | yes |
| `x86-avx2` | yes | yes |
| `x86-avx512` | yes | yes |
| `aarch64-neon` | yes | yes |
| `wasm-simd128` | yes | yes |

NEON reductions and scans, and native mask reductions, are included in
Rake 0.7.0.

Rake 0.7.0 also supports all four reductions and inclusive
scans on `i32s` and `u32s` across these profiles. Scans and reductions at other integer
widths remain WIP* (*work in progress*).

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch running_total(values: f32s) -> f32s:
  scan_sum(values)
```

On SSE2, AVX2 and AVX-512, a float fold takes three, seven or fifteen ordered
steps respectively. The steps use shuffles,
permutations, blends and packed arithmetic, and a reduction's scalar returns
in `xmm0`.

NEON also takes three ordered steps. Each broadcasts the next lane into a
complete register with `dup`, then applies full-width arithmetic to the
running prefix. A scan inserts that prefix into the corresponding lane with
`ins`. A reduction returns the low `f32` lane of `v0`, following AAPCS64.
For strict extrema, `fmin` or `fmax` supplies the numerical result, followed
by a quiet comparison and selection of `0x7fc00000` if it is NaN.
The allocator accounts for these intermediate registers, and the object
verifier permits their lane transfers only in selected cross-lane functions.

Native mask reductions use two packed permutation-and-combine stages on
SSE2 and NEON, three on AVX2, or four on AVX-512F. `all` combines with AND,
and `any` with OR, then converts the result to zero or one with a vector
mask. `bitmask` first assigns each true lane its bit weight, then combines
the weights with OR. One temporary vector register is included in the
no-spill allocation check. Only the completed result crosses into the C
integer return register. Independent C checks every possible lane mask at
each physical width, including complement and composed masks.

Integer reductions use the existing full-width shuffles and packed arithmetic
or extrema. Each stage combines disjoint lane groups, and the completed value
crosses the integer C return boundary through a lane extraction. No scalar
lane arithmetic is introduced.

Integer scans combine prefixes at distances 1, 2, 4 and 8 as the rack width
requires. Each packed stage shuffles earlier prefixes into place and fills
the initial lanes with the operation's neutral value. Full-width transfers
include prefixes that cross AVX register subdivisions. An independent
sequential C fold checks every prefix's wrapping bits and signedness,
including computations that use the original rack again.

On `wasm-simd128`, each of a float reduction's three steps moves lane `i`
to lane 0 with one `i8x16.shuffle` and combines it with the running value. A
scan keeps the running prefix in a rack and, for lanes 1 to 3, combines the
previous prefix with lane `i` and shuffles the result into lane `i`. A
minimum or maximum step is `f32x4.min` or `f32x4.max`, then an `f32x4.ne`
self-comparison of each operand, a `v128.or` and a `v128.bitselect` of the
canonical NaN, because WebAssembly leaves a NaN result's payload unspecified.
`all` and `any` are the mask width's `all_true` and `v128.any_true`.
The physical profiles share an independent scalar C oracle that checks
left-fold rounding, zero signs, canonical extrema and NaNs at every position.
`test/program/vector_tier.rk` compares the four reductions, `scan_sum`,
`scan_maximum`, `all`, `any` and `bitmask` with the interpreter.
