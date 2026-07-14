# Rake goal contract

Rake is a vector-first systems language for writing explicit single-instruction,
multiple-data (SIMD) programs. Its purpose is to let a programmer state the
machine-level vector structure of an algorithm without dropping into intrinsics
or assembly.

This document defines the language goals. A release capability report says
which goals a compiler build implements. An implementation may reject a program
or target profile that it cannot compile according to this contract. It must
not silently weaken a rack, fused region, or rake into scalar code.

## Native racks

A rack is one native vector register in the selected target profile. The
profile fixes the register width and derives the lane count from the element
type. For example, a 256-bit profile gives an `f32s` rack eight lanes and an
`f64s` rack four lanes.

The compiler must reject a rack type or operation when the target would split,
narrow, or scalarize it. A scalar target is a separate, explicit profile and is
never described as SIMD. Cross-target compilation uses a named reproducible
profile rather than the feature set of whichever machine happens to run the
compiler.

Every live rack occupies one physical register of the selected profile's native
vector register class. Register allocation must not represent one rack with
multiple registers or memory. Post-allocation machine IR and disassembly are
the acceptance evidence for the register class, instruction family, absence of
splitting, and absence of scalarization.

## Explicit scalars

Plural primitive types identify racks. Angle brackets identify uniform scalar
declarations, uses, and broadcasts. Seeing many scalar markers in a kernel
should provoke the question: could these values vary by lane, or be stored and
processed more efficiently? The type checker must reject an implicit rack-to-scalar
or scalar-to-rack conversion that would hide data movement, lane selection, or
broadcasting.

`lanes` reports the lane count derived from the target profile and element
type. `@` produces the zero-based lane indices for the surrounding rack type.

## Predicated rake control flow

Tines are named masks. The `#` resembles a perforated mask: values pass through
the lanes whose holes are open. A `through` region computes a candidate under
a tine, and `return sweep:` selects one candidate for every lane. Source-order
priority and the final catch-all arm make the result deterministic.

On native vector profiles, rake control flow must remain vector predication. A
backend may use target masked instructions or benign-operand substitution, but
it must not turn lane choices into per-lane scalar branches. Inactive lanes
must not cause floating-point exceptions, invalid memory access, or observable
side effects.

The compiler must reject a masked operation when the selected profile cannot
preserve both the semantic rule and the native-rack rule.

## Fused regions

Contiguous `| name <| expression` bindings describe one pure vector data-flow
graph. The right-hand expression visibly flows into the name on its left, and
the leading bars align consecutive stages. A supported
fused region has no machine calls and no spill or reload of its intermediate
values. Its result remains in the target rack register class. The compiler must
reject a region that exceeds the target's supported operation set or register
budget.

Fused names are transparent data-flow aliases. They do not impose evaluation,
storage, instruction, or rounding boundaries. The backend substitutes those
names and applies target-costed algebraic rewrites, including FMA formation,
across the complete region. Ordinary floating-point operators permit the
backend to choose the lowest-cost legal evaluation graph, so different targets
may round intermediate results at different points.

Explicit `fma(a, b, c)` has required one-rounding semantics. It is necessary
when correctness depends on that operation, while an ordinary multiply-add
graph may become FMA automatically. Rake does not offer a mode that asks the
backend to preserve a slower sequence of ordinary arithmetic operations.

Compiler reports and post-register-allocation machine-code checks provide the
acceptance evidence for these guarantees.

## Vector operations

Rake's core vector vocabulary includes:

- arithmetic, comparisons, masks, and mathematical primitives;
- lane count, lane indices, extraction, and insertion;
- named reductions and prefix scans such as `sum` and `scan_sum`;
- named shuffles, zips, shifts, and rotates;
- automatically selected and source-required fused multiply-add;
- gather, scatter, compression, and expansion; and
- stack, pack, and single data layouts.

Each operation has a type rule, inactive-lane rule, target support matrix, and
verified lowering. An operation may be unavailable on a profile that lacks a
native implementation. The compiler reports that restriction before emitting
backend IR.

## Explicit data layout

`stack` represents columnar structure-of-arrays data and `pack Stack`
represents storage traversed with `for chunk in pack using racks up to
<count>:`. Layout conversions and memory operations must be explicit
in source or in a documented calling convention.

Tail handling may use masked memory operations. It must not read or write past
the logical element count, raise floating-point exceptions from inactive lanes,
or create another observable inactive-lane effect. The normative pack and
`run` design, including its ownership and ABI rules, is specified in
[`spec/02_packs_and_run.md`](spec/02_packs_and_run.md). That published design
does not claim production support before its executable and machine-code gates
pass.

## Predictable compilation

The production Rake compiler owns every lowering decision from typed source
through Rake SSA, target machine IR, register allocation, scheduling, and
textual assembly. The system assembler encodes the selected instructions and
constructs the object file. It must not select instructions, allocate
registers, introduce spills, or scalarize racks.

Rake compilation is inspectable from source through typed Rake SSA, target
machine IR before and after register allocation, textual assembly, and object
code disassembly. The language contract is the source-semantic authority. The
verified optimized graph fixes target-dependent evaluation choices, while the
scalar interpreter independently executes explicit operations and graphs whose
rounding order is fixed. Post-allocation machine IR, assembly, and object-code
disassembly are the machine authority. Named target profiles, declared
arithmetic semantics, compiler reports, and conformance tests make performance
properties reproducible.

The compiler proves the properties it claims for an accepted program. When it
cannot prove a required property, compilation fails with the source construct,
target profile, failed obligation, and available alternatives.

Representative benchmarks may describe measured performance only when their
source, target profile, compiler version, command, input size, and comparison
baseline are recorded together.
