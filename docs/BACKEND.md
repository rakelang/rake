# Native backend contract

Rake's production compiler owns the path from typed vector operations to
scheduled target instructions. The language contract defines the permitted
source evaluation graphs; verified optimized native IR records the graph
selected for a target. The scalar interpreter independently executes explicit
operations and graph-stable fixtures. Native MIR, physical allocation,
assembly, and disassembly establish the generated-machine properties of an
accepted program.

```text
Rake source
  -> typed AST
  -> target-independent Rake vector SSA
  -> fused-graph substitution and target-costed rewriting
  -> profile legalization
  -> target machine IR
  -> instruction selection and scheduling
  -> register allocation
  -> post-allocation contract verification
  -> textual assembly
  -> system assembler and linker
```

The first production profile is `x86-avx2`. Its first ABI variant is
`x86_64-avx2-fma-sysv`; the shorter name is the compiler's profile identifier,
while the longer name fixes the platform calling convention. An `f32s` is exactly
one 256-bit YMM register with eight lanes, an `f64s` has four lanes, and
comparison masks remain YMM values. The profile requires AVX2 and FMA3. It
selects native vector operations or rejects the program: it must not split a
rack, scalarize an unsupported operation, or silently insert a fallback call.
An ordinary fused multiply-add graph may select one FMA3 instruction. Explicit
`fma` requires that instruction's one-rounding arithmetic semantics.

The second production profile is `aarch64-neon`. Its
`aarch64-neon-aapcs64` boundary maps an `f32s` to one four-lane 128-bit
vector register, passes as many as eight rack or uniform f32 arguments in
`v0` through `v7`, and returns a rack in `v0`. Its no-spill allocator uses the
24 caller-clobbered full-vector registers `v0` through `v7` and `v16` through
`v31`. Fused multiply-add graphs may select one `fmla`; explicit `fma` requires
its one-rounding semantics. GNU cross-binutils encode and inspect
the object, and a static AArch64 harness compares exact result bits under QEMU.

An angle-bracket `f32` parameter is uniform rather than a rack. On the SysV
boundary it occupies the next SSE-class argument slot as an XMM value. Its
source use emits `vbroadcastss` into one YMM rack. XMM and YMM names with the
same number alias one physical register, so allocation tracks both forms as a
single live register family.

## Pipeline invariants

- Rack identity survives every target-independent and machine-IR pass. Only an
  explicit extract, insert, reduction, scan, gather, scatter, or profile-defined
  layout operation may cross the rack/scalar or rack/memory boundary.
- Scalars, broadcasts, masks, and pointers have distinct IR types. Hidden
  broadcasts and lane extraction are verifier errors.
- Definitions dominate uses in the deliberately linear SSA form. Loops are
  structured regions, not arbitrary control-flow graphs.
- A block has exactly one terminator. Functions return; loop bodies yield.
- Fused provenance describes a contiguous, pure rack/mask SSA region. Calls,
  memory operations, loops, scalar results, spills, and reloads are forbidden.
  Fused names do not survive as evaluation boundaries. Graph optimization may
  apply any rewrite allowed by the language arithmetic contract before
  legalization. The current alpha substitutes transparent aliases, removes
  dead intermediates, and contracts multiply-add graphs to target-native FMA;
  general reassociation and algebraic restructuring remain unimplemented.
  Legalization checks the resulting operation set and the allocator rejects it
  when its live rack count exceeds the profile budget.
- Through provenance names a mask. Legalization classifies each masked
  operation as total, sanitizable, mask-native, or unsupported. Inactive lanes
  must not trap, access memory, or have observable effects.
- Target legalization is explicit and fallible. Every rejected obligation names
  the source construct, profile, and unsupported operation or resource limit.
- After allocation, a machine-code verifier proves rack register classes and
  spill-freedom for every rack value, plus fused-region call-freedom, required
  single-instruction operations, and absence of scalarized lane control flow
  before an object is accepted.

The initial IR is intentionally MIR-neutral. It represents arithmetic, FMA,
comparison and selection, rack memory and lane operations, shuffles, reductions,
scans, gather/scatter, calls, and structured loops without claiming that every
operation is already legal for AVX2. The profile support matrix, not mere IR
representability, decides acceptance.

## Authorities and ownership boundaries

The type checker proves source-level typing and capability obligations. The
typed native IR verifier proves rack identity, value types, dominance,
  structured control flow, and fused or predicated provenance. The native IR
  represents benign-operand substitution with an explicit `sanitize`
  operation, and its verifier rejects masked exception-capable operands that
  bypass that operation. The scalar interpreter evaluates explicit operations
  with the language's rounding rules. It is not a bit-exact oracle for an
  ordinary fused expression when optimization legally changes its rounding
  graph.
Runtime fixtures whose fused graphs admit alternate evaluation orders derive
their expected results from the verified optimized graph or choose inputs for
which every permitted graph agrees. Every extension to the executable surface
must add cases to this differential gate. The AVX2 and NEON predication gates also
check total sweep priority, exact result bits, inactive-lane floating-point
flags, and the absence of calls, stack use, spills, and scalar lane branches.

The target backend proves a different set of facts. Legalization and
instruction selection establish target support; allocation establishes the
physical register assignment; assembly records Rake's instruction decisions;
and disassembly verifies the encoded object. A frontend acceptance test cannot
stand in for any of these machine checks.

Rake initially owns vector SSA, rewriting, target legalization, instruction
selection, pressure-aware scheduling, register allocation, textual assembly
emission, and machine-contract verification. It intentionally delegates object
formats, relocation encoding, platform linking, and operating-system startup to
the system assembler and linker. Debug information and exception unwinding are
outside the initial backend.

The compiler has no alternate code-generation path. A construct that has
frontend semantics but lacks a complete native lowering remains
frontend-checkable and production-unavailable. Native compilation reports the
missing obligation at its source location.

## Pack and `run` boundary

Rake's intended first pack and `run` boundary is specified in
[`spec/02_packs_and_run.md`](spec/02_packs_and_run.md). It uses a
source-order structure-of-arrays descriptor, a caller-owned implicit output
stream, and the Linux x86-64 System V classifier. Full chunks remain YMM rack
operations. A tail must mask memory and sanitize inactive exceptional
arithmetic.

The current native backend still rejects `run`, pack traversal, stack, and pack
definitions before object emission. The published boundary becomes a
production capability only after typed-IR traversal, executable semantics,
AVX2 loop and tail lowering, runtime comparison, and object verification all
implement the normative contract.
