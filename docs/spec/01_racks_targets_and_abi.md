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

The `x86-avx2` and `aarch64-neon` backends expose four inspection points:

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
