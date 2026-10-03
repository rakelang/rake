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
| `all(m)` | mask | `bool` | and |
| `any(m)` | mask | `bool` | or |
| `scan_sum(x)` | `f32s` | `f32s` | binary32 addition |
| `scan_product(x)` | `f32s` | `f32s` | binary32 multiplication |
| `scan_minimum(x)` | `f32s` | `f32s` | strict minimum |
| `scan_maximum(x)` | `f32s` | `f32s` | strict maximum |

Nothing converts an operand to fit: the arithmetic forms reject masks and
integer racks, and `all` and `any` reject racks. `extract(x, lane)` and
`bitmask(m)`, defined in [primitives, operations, and targets](01_primitives_operations_and_targets.md),
also turn a rack into a scalar.

A scratch can return a reduction's scalar. In a run, `let <x: T> = ...` binds
one as a uniform, and arithmetic on reductions there is scalar work:

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

## Lane order

For a rack `x` of `N` lanes:

```text
p[0] = x[0]
p[i] = step(p[i - 1], x[i])    for i from 1 to N - 1
```

A reduction returns `p[N - 1]`, and a scan returns `p[0]` to `p[N - 1]`, so
every scan is inclusive. The fold always runs from lane 0 upwards. No
implementation may use a tree, reassociate, contract, or keep a wider
intermediate, so each addition and multiplication rounds to binary32 in turn.
A rack always has lanes, so there is no empty case and no identity value.

## Strict minimum and maximum

Each step of `minimum`, `maximum`, `scan_minimum` and `scan_maximum`:

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

| Profile | Reductions and scans | `all`, `any` |
| --- | :-: | :-: |
| `x86-sse2` | yes | WIP* |
| `x86-avx2` | yes | WIP* |
| `x86-avx512` | yes | WIP* |
| `aarch64-neon` | yes | WIP* |
| `wasm-simd128` | yes | yes |

*WIP: work in progress. The compiler rejects these operations on these profiles.*

NEON reductions and scans are available in the development compiler after
0.6.0-beta. The tagged compiler still rejects them.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch running_total(values: f32s) -> f32s:
  scan_sum(values)
```

On SSE2, AVX2 and AVX-512, a fold takes three, seven or fifteen ordered
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

On `wasm-simd128`, each of a reduction's three steps moves lane `i`
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
