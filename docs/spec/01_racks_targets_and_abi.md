# Racks, targets, and binary boundaries

This document specifies Rake's target model and the binary boundary currently
implemented by the production native backend. Alpha releases may change that
boundary incompatibly.

## Native-register racks

On a CPU SIMD profile, one live rack occupies one fixed-width physical vector
register. The profile determines the register class and the lane count of each
element type.

| Profile | ISA | Register | f32 lanes | Status |
| --- | --- | --- | ---: | --- |
| `x86-sse2` | x86-64 SSE2 | XMM | 4 | planned |
| `x86-avx2` | x86-64 AVX2 and FMA3 | YMM | 8 | crunches and predicated rakes |
| `x86-avx512` | x86-64 AVX-512F | ZMM | 16 | planned |
| `aarch64-neon` | AArch64 NEON | vector | 4 | crunches and predicated rakes |
| `wasm-simd128` | WebAssembly SIMD128 | `v128` | 4 | crunches over f32, u8, i16 and i32 racks, emitted as C |

`native` resolves to the strongest production profile implemented for the
host. An explicit profile produces deterministic cross-target behavior. The
planned `scalar` profile is explicitly non-SIMD and doesn't carry the
native-register rack guarantee.

`--width` is a compatibility assertion. When present, it must equal the
profile-derived f32 lane count. A mismatch fails before native IR generation.
The compiler cannot satisfy the assertion by splitting, narrowing,
scalarizing, or selecting another ISA.

The reserved `lanes` expression denotes the rack lane count, and `@` denotes
the zero-based lane index. Both remain production-unavailable until their
typed-IR operations, scalar interpretation, target lowering, and disassembly
checks are complete.

## Production pipeline

The `x86-avx2` and `aarch64-neon` backends expose four inspection points, and
`wasm-simd128` exposes the same four with the differences described under
[WebAssembly boundary](#webassembly-boundary):

- `--emit-native-ir` emits typed rack-preserving SSA;
- `--emit-asm` emits Rake-selected GNU assembly syntax for the profile;
- `--emit-obj` asks the system assembler to encode that assembly; and
- `--verify-native` disassembles and verifies the encoded object.

The current native slice accepts `f32s` `crunch` definitions and predicated
`f32s` `rake` definitions with rack and uniform scalar parameters.
Unsupported source constructs, operations, target profiles, and register
pressure are compile-time errors. The backend has no lowering that represents
a rack with narrower vectors, scalar lanes, helper calls, or spill slots.

For every accepted object, verification checks the target instruction
allow-list, rack register class, lack of calls and stack use, and the exact FMA
count selected from both ordinary fused graphs and explicit `fma` operations.
The scalar interpreter provides independent executable semantics for the
implemented expression subset. The runtime suite parses the same `crunch` and
`rake` definitions and compares exact binary32 result bits where the arithmetic
graph fixes them. Object tests separately prove that the optimizer contracts
the ordinary two-binding multiply-add example to one FMA. A future runtime
fixture whose permitted optimized graph changes rounding must take its expected
bits from that verified graph rather than treating the unoptimized interpreter
order as authoritative.
Every newly admitted operation must extend this differential gate;
disassembly separately checks the promised machine form.

## Byte racks, shuffles and bitmasks

This section is a proposal. It is implemented for `wasm-simd128` only.

A `u8s` rack holds one unsigned byte per lane, sixteen lanes on a 128-bit
profile. Two `u8s` racks compare lane by lane, and a `u8s` rack compares with an
integer literal, which is broadcast. Comparison yields a mask whose lane width
is the byte.

`shuffle(a, [i0, ...])` and `shuffle(a, b, [i0, ...])` build a rack from
static lane indices. With two racks, indices from the lane count upward select
from `b`, as if the racks were laid end to end. The index list must have one
entry per lane, and each index must name a lane of the inputs.

`bitmask(mask)` returns a `u32` with one bit per lane, lane zero in bit zero.
It is a reduction. Its result is a scalar and ends rack-valued work.

```text
crunch occupied_bits(tiles: u8s) -> u32:
  return bitmask(tiles != <0>)
```

## Integer racks and dot products

This section is a proposal. It is implemented for `wasm-simd128` only.

An `i16s` rack holds eight signed 16-bit lanes and an `i32s` rack four signed
32-bit lanes on a 128-bit profile. They carry integer arithmetic, such as an
8-bit network's 16-bit activations and 32-bit sums:

- `a + b` and `a - b` of equal `i16s` or `i32s` racks wrap on overflow.
- `min(a, b)` and `max(a, b)` compare signed lanes. Either operand may be an
  integer literal, which is broadcast in the other's element type.
- `dot(a, b)` takes two `i16s` racks and returns an `i32s` rack whose lane `i`
  is `a[2i] * b[2i] + a[2i+1] * b[2i+1]`, wrapping.
- `narrow(a, b)` takes two `i32s` racks and returns one `i16s` rack, `a`'s
  lanes then `b`'s, each saturated to the 16-bit range.
- `widen_low(x)` and `widen_high(x)` take the low or high eight lanes of a `u8s`
  rack, zero-extended to an `i16s` rack.
- `to_f32(x)` converts an `i32s` rack to `f32s`, rounding to nearest.
  `to_i32(x)` converts an `f32s` rack to `i32s`, rounding to nearest with ties
  to even and saturating to the 32-bit range; NaN becomes zero.

On `wasm-simd128` each of these is one instruction, except `to_i32`, which is
`f32x4.nearest` then `i32x4.trunc_sat_f32x4_s`.

```text
crunch accumulate(sums: i32s, pair: i16s, weights: i16s) -> i32s:
  return sums + dot(pair, weights)

crunch requantise(low: i32s, high: i32s, low_scale: f32s, high_scale: f32s) -> i16s:
  | a <| to_i32(to_f32(low) * low_scale)
  | b <| to_i32(to_f32(high) * high_scale)
  return max(narrow(a, b), <0>)
```

## WebAssembly boundary

WebAssembly has no fixed register file. Its locals are typed and unlimited,
so `wasm-simd128` has no register allocation and no spills to rule out. Selection
schedules the value stack: a value used once is computed where it is used, and
a value used more than once is computed at its first use and kept in a local
with `local.tee`.

`--emit-asm` writes C rather than assembly text: each selected instruction
becomes the matching `wasm_simd128.h` intrinsic, in selection order, inside a
`static inline` function whose parameters and result are `v128_t`, `uint32_t`
or `float`. Defining `RAKE_WASM_LINKAGE` changes that linkage. C is the output
because some wasm32 C toolchains, including the one inside the unswbc judge,
accept only C source and reject `v128` inline-assembly operands. Clang keeps
the right to choose locals and to exchange one vector instruction for an
equivalent one, such as a splatted zero for `v128.const`.

`--verify-native` compiles that C with `$RAKE_WASM_CC` (default `clang`) for
`wasm32` with SIMD128, disassembles it with `$RAKE_WASM_OBJDUMP` (default
`llvm-objdump`), and accepts a function only if its body is locals, constants
and non-memory SIMD instructions: no calls, loads, stores, branches or stack
pointer traffic.

## Function boundary

The initial `x86_64-avx2-fma-sysv` crunch convention provides eight SSE-class
argument slots. Parameters consume those slots in source order. An `f32s` rack
uses the slot's YMM register and an angle-bracket `f32` scalar uses its XMM
register. For example:

```text
crunch f(a: f32s, <scale: f32>, b: f32s) -> f32s:
```

This receives `a` in `ymm0`, `scale` in `xmm1`, and `b` in `ymm2`. The XMM and
YMM names for one slot alias the same physical register. An explicit scalar use
broadcasts with `vbroadcastss` before
rack arithmetic. A ninth SSE-class argument would require stack passing, so the
compiler rejects that boundary. One `f32s` result returns in `ymm0`.

The angle brackets remain present in both `<scale: f32>` and `<scale>`. They
make the uniform value and its eventual broadcast visible during review rather
than leaving that cost implicit in an ordinary identifier.

The `aarch64-neon-aapcs64` convention uses `v0` through `v7` for rack and
uniform f32 arguments and returns one rack in `v0`. A scalar parameter occupies
the low `s` lane of its argument register and an explicit scalar use broadcasts
with `dup`. The no-spill allocator uses `v0` through `v7` and `v16` through
`v31`. It excludes `v8` through `v15` because AAPCS64 makes their low halves
callee-saved, which would require save and restore storage.

This convention is an internal alpha boundary exercised by C interoperability
tests. It does not yet constitute a stable foreign-function interface.

`rake` uses the same rack/scalar argument and rack-result boundary as `crunch`.
`run` definitions have no production binary boundary in the current backend.
The native backend rejects `run` before object emission. The normative
design for the first pack and `run` boundary is published in
[`02_packs_and_run.md`](02_packs_and_run.md). It specifies the canonical source
syntax, source-order pack descriptor, output stream, pointer and
stride rules, ownership and aliasing, count behavior, safe tails, symbol, Linux
x86-64 System V classifier, and acceptance matrix.

Publishing the design does not make it executable. Production status requires
the interpreter, typed native IR, target lowering, runtime differential tests,
and object verifier to implement every rule in that document.

An earlier experimental path generated C wrappers around rank-one memref
descriptors with toolchain-owned symbol names. That convention is retired and
does not specify the Rake ABI.
