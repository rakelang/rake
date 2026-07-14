# Rake changelog

Rake uses alpha releases while its executable language and binary interfaces
are still changing. An alpha version names a testable compiler,
Tree-sitter grammar, documentation set, and website snapshot. It does not
promise source, ABI, or syntax compatibility with another alpha.

Design documents describe possible later language behavior. A proposal does
not acquire a release version until the compiler implements it and the
conformance suite covers it.

## 0.3.0-alpha.1 — in development

### Implemented and checked

- The checker publishes a frontend semantic-capability report. Native profiles
  apply a separate lowering and machine-contract gate.
- Named CPU profiles derive 128-, 256-, and 512-bit f32 rack widths. Production
  backends target eight-lane AVX2 and four-lane AArch64 NEON racks.
- The language contract defines permitted evaluation graphs, optimized native
  IR records target-dependent choices, and the scalar interpreter independently
  executes explicit operations and graph-stable fixtures.
- Frontend-supported `through` expressions have defined inactive-lane behavior.
- Sweeps require one final catch-all arm and preserve source-order priority.
- Fused bindings enforce a pure contiguous SSA expression contract. Transparent
  fused names are substituted before target-costed FMA contraction, while
  explicit `fma` retains required one-rounding semantics.
- The AVX2 backend owns typed SSA, instruction selection, no-spill YMM
  allocation, textual assembly, object assembly, and disassembly verification.
- The AArch64 NEON backend owns AAPCS64 selection, a 24-register no-spill
  allocation domain, GNU assembly, cross-object verification, and a static
  semantic differential under QEMU.
- Machine verification rejects calls, stack use, rack spills, scalarization,
  wrong register classes, instructions outside the profile allow-list, and an
  incorrect selected-FMA count.
- Native runtime tests compare bit-exact results from parsed Rake `crunch`
  definitions against Rake's independent executable semantics.
- Compiler and Tree-sitter parsing are compared over the shared syntax corpus.

### Removed

- The experimental MLIR/LLVM lowering and its command-line modes no longer act
  as a supported backend or correctness oracle.
- The toolchain-generated memref C wrapper is retired. `run` has no production
  binary interface until Rake's native traversal and ABI contract are complete.

### Parsed or proposed

- Records, tuples, logical mask reductions, reductions and scans outside AVX2,
  data rearrangement operations,
  lambdas, expression pipelines, and non-f32 numeric paths remain unavailable
  to executable programs even where the parser recognizes their syntax.
- AVX-512 and SSE2 production object output remain proposed.
- The broader control-flow design remains a proposal rather than part of this
  alpha's executable language.
