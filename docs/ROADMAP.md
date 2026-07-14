# Rake implementation roadmap

Rake's roadmap extends native production coverage until it matches the language
goal contract. A feature becomes production-executable only when one compiler
revision contains its type rules, typed-IR form, scalar-interpreter semantics,
target legalization, allocation rules, assembly emission, disassembly checks,
and conformance fixtures.

Frontend acceptance records that a program has defined source semantics. It
doesn't establish that a target can execute the program while preserving
Rake's register and instruction guarantees.

## Implemented native foundation

The first `x86-avx2` slice provides:

- target profiles with profile-derived rack widths;
- typed rack and mask SSA with source locations and verification;
- scalar f32 interpretation with explicit per-operation rounding and FMA;
- uniform f32 crunch parameters, SysV SSE-class argument assignment, and
  explicit `vbroadcastss` lowering;
- straight-line arithmetic, fused-graph FMA contraction, comparison, selection,
  square root, mask logic, broadcast, and source-required FMA lowering;
- native tines, inactive-lane-safe through blocks, and total priority sweeps;
- AVX2/FMA3 instruction selection and no-spill YMM allocation;
- Intel-syntax assembly and system-assembler object creation; and
- disassembly verification for calls, stack use, spills, scalarization,
  register width, instruction allow-lists, and selected-FMA counts.

## Implemented: predicated rake semantics

Native AVX2 `rake`, `through`, and `sweep` preserve lane predication through:

1. Lower tine declarations to typed mask SSA.
2. Classify every through-body operation as total, sanitizable, mask-native, or
   unsupported for each target profile.
3. Sanitizing inactive operands before supported partial operations such as
   division and square root. Logarithm remains rejected until it has a native,
   no-call implementation.
4. Lower total source-priority sweeps without per-lane branches.
5. Interpret inactive-lane behavior, including floating-point exceptions.
6. Reject calls, effects, or operations without a sound masked lowering.
7. Verify the absence of scalar lane branches and unsafe inactive-lane memory.

## Next: native memory traversal

The Rake-owned binary and memory design for `stack`, `pack`, and `run` is now
specified in [`spec/02_packs_and_run.md`](spec/02_packs_and_run.md). It fixes
the descriptor field order, pointer and stride rules, ownership, permitted
aliasing, count behavior, implicit output stream, symbol, and first Linux
x86-64 System V classifier. Full racks use native vector loads and stores.
Tails use masked memory and sanitized inactive arithmetic so that they neither
cross the logical bound nor raise inactive-lane floating-point exceptions.

The implementation must keep traversal structure in typed IR, make
the loop and tail mask visible in MIR, execute boundary sizes in semantic
tests, and inspect disassembly for vector memory operations and the absence of
scalar cleanup loops. `run` remains production-unavailable until those gates
pass.

## Next: complete vector vocabulary

Each core vector operation needs one end-to-end contract:

- lane count, lane indices, extraction, and insertion;
- logical mask reductions and strict reductions or prefix scans on profiles
  other than AVX2;
- shuffles, interleaves, shifts, and rotates;
- gather and scatter;
- compression and expansion; and
- the remaining arithmetic and mathematical primitives.

An operation may lower to several native vector instructions when its published
profile contract permits that sequence. It may not lower to scalar lanes,
helper calls, split racks, or memory temporaries. The capability report names
unsupported profile/operation pairs.

## Next: additional profiles

`x86-avx512` and `x86-sse2` each need their own legalization,
instruction selection, allocator constraints, assembly syntax, ABI variant,
object verification, and target-specific runtime fixtures. Shared typed IR and
semantic interpretation remain profile-independent.

AVX-512 should use native mask registers where they strengthen predication and
tail handling. SSE2 support must reject operations whose only implementation
would violate the no-split, no-call, or no-spill contract.

## Release gates

A release capability changes from unavailable to supported only when:

- the normative specification gives the operation's types and semantics;
- malformed and unavailable uses have source-located diagnostics;
- the scalar interpreter covers ordinary, boundary, and exceptional inputs;
- native runtime output matches the interpreter;
- allocation and disassembly establish the target contract;
- documentation labels frontend-only and production-executable examples; and
- the capability catalog, tests, release notes, and website agree.

Representative benchmarks remain a separate gate. Every published result must
record the source, compiler version, target profile, command, input size,
machine, and comparison baseline.
