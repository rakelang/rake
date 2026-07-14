# Recommended implementation work packages

These ten packages extend Rake from its first AVX2 crunch slice to the complete
vector-language goal contract. Each package must preserve the central rule:
one live rack occupies one physical register of the selected target's native
vector class. Unsupported obligations cause source-located compilation errors.

Every package treats the language contract as source-semantic authority and the
verified optimized graph as the record of target-dependent evaluation choices.
The scalar interpreter independently executes explicit operations and
graph-stable fixtures. Native MIR, allocation, textual assembly, and
disassembly establish machine behavior. Frontend acceptance by itself is never
a production completion criterion.

## WP-01: Consolidate capabilities and semantic authority

**Objective:** Give every parsed feature one stable capability identity and one
end-to-end support state.

**Work:**

- Define states for parsed, frontend-semantic, interpreter-executable,
  native-lowerable, and production-verified support.
- Make target and element type part of each support decision.
- Reject unavailable operations before native IR emission with the feature ID,
  source location, target profile, and failed obligation.
- Remove alternative backend states and toolchain-owned ABI claims from public
  capability output.

**Acceptance:** The capability report, checker diagnostics, test manifest,
specification, README, release notes, and website describe the same boundary.

## WP-02: Complete typed native IR and scalar interpretation

**Objective:** Represent and execute every core language operation without
depending on target code generation.

**Work:**

- Complete rack, mask, scalar, pointer, layout, memory, lane, shuffle,
  reduction, scan, gather/scatter, compress/expand, call, and structured-loop
  operations.
- Preserve source locations and fused, through, sweep, and tail provenance.
- Verify types, definitions-before-uses, region terminators, dominance,
  provenance contiguity, and explicit rack/scalar boundaries.
- Extend the scalar interpreter with exact f32/f64 rounding, exceptional-value
  behavior, masked evaluation, memory bounds, and layout semantics.

**Acceptance:** Each typed operation has positive, negative, boundary, NaN,
infinity, signed-zero, and masked-off interpretation fixtures as applicable.

## WP-03: Lower predicated rake control flow

**Objective:** Make tine, through, and total sweep semantics production-native.

**Work:**

- Lower tines to typed mask values and retain mask provenance through MIR.
- Classify operations as total, sanitizable, mask-native, or unsupported.
- Sanitize inactive operands before exceptional arithmetic.
- Implement source-priority total sweeps with vector selection.
- Reject effects, invalid inactive memory, and unsafe speculative calls.

**Acceptance:** Runtime results and floating-point exception flags match the
interpreter. Disassembly contains no per-lane scalar branch, helper call, spill,
or scalar cleanup.

## WP-04: Enforce fused data-flow contracts

**Objective:** Carry source fused regions through native code generation as
verified machine obligations.

**Work:**

- Preserve contiguous fused provenance through rewriting, scheduling,
  instruction selection, and allocation.
- Reject memory, calls, effects, scalar results, noncontiguous regions, and
  register pressure beyond the profile budget.
- Substitute fused names and optimize the resulting graph with target operation
  costs, including reassociation, factoring, distribution, common-subexpression
  elimination, strength reduction, and fused instruction formation.
- Retain the implemented alias-substitution and multiply-add contraction pass
  as the first checked slice while adding those broader rewrites incrementally.
- Select exactly one native fused instruction when the optimized graph or an
  explicit `fma` requires it.

**Acceptance:** Post-allocation MIR and disassembly prove call-freedom,
spill-freedom, rack register classes, contiguity, and exact selected-FMA counts.

## WP-05: Specify and implement native `run` traversal

**Objective:** Compile stack and pack traversal without a toolchain-owned
wrapper ABI.

**Work:**

- Specify symbol naming, argument ordering, pointer representation, scalar
  types, results, alignment, stride, aliasing, mutability, and ownership.
- Lower `for chunk in pack using racks up to <count>:` to a full-rack loop plus
  a safe tail.
- Use explicit native vector loads and stores for full racks.
- Use masked tail memory operations and prohibit out-of-range access.
- Publish platform ABI variants rather than one accidental host convention.

**Acceptance:** C or assembly harnesses execute zero, short, exact-width,
multi-width, and tail lengths under sanitizers where available. Disassembly
shows vector memory operations and no scalar tail loop.

## WP-06: Complete the vector primitive vocabulary

**Objective:** Implement the operations promised by the language goal contract.

**Work:**

- Add lane count, lane indices, extraction, and insertion.
- Add reductions, prefix scans, shuffles, interleaves, shifts, and rotates.
- Add gather, scatter, compression, and expansion.
- Complete arithmetic, comparisons, masks, conversions, and mathematical
  primitives with explicit rounding and exceptional-value rules.
- State the permitted native instruction sequence for every profile/operation
  pair and reject pairs without a compliant sequence.

**Acceptance:** Interpreter comparison establishes values. MIR and disassembly
establish register width, absence of rack spills or scalarization, and any
single-instruction guarantee.

## WP-07: Add AVX-512 production support

**Objective:** Implement the `x86-avx512` profile with 512-bit racks and native
mask registers.

**Work:**

- Add AVX-512 legalization, instruction selection, scheduling, allocation,
  assembly, constants, ABI rules, and verifier allow-lists.
- Use k-mask operations for through selection, masked memory, and tails where
  they satisfy Rake semantics.
- Account for the target's vector and mask register budgets independently.

**Acceptance:** Runtime and interpreter results agree on supported hosts or an
emulator. Disassembly proves ZMM/k-register use, no split racks, no scalar tail,
no spills, and no helper calls.

## WP-08: Add AArch64 NEON and x86 SSE2 support

**Objective:** Implement the two 128-bit native profiles without importing
AVX2 assumptions.

**Work:**

- Give each profile explicit legalization and instruction sequences.
- Add platform assembly, register allocation, ABI variants, object assembly,
  and disassembly parsing.
- Reject operations that require forbidden calls, scalar lanes, rack splitting,
  or memory temporaries on either ISA.

**Acceptance:** Cross-target object inspection proves the register class and
instruction allow-list. Runtime comparison runs on matching hardware or a
validated emulator.

## WP-09: Build the conformance and machine-verification matrix

**Objective:** Make each published capability auditable at the appropriate
compiler stage.

**Work:**

- Classify fixtures as parser, checker, interpreter, native lowering, runtime,
  allocation-pressure, assembly, disassembly, or future design.
- Require focused negative tests for every rejection obligation.
- Compare graph-stable native results with the scalar interpreter, including
  exceptional and masked inputs; derive optimizer-sensitive expected bits from
  the verified optimized graph.
- Inspect encoded objects rather than relying only on emitted assembly text.
- Record target requirements so unavailable host hardware skips transparently.

**Acceptance:** Each supported capability maps to semantic and machine evidence
in the manifest. Removing either the lowering or verifier causes the relevant
fixture to fail.

## WP-10: Align specification, release identity, and website

**Objective:** Publish one accurate account of Rake's goals and executable
coverage.

**Work:**

- Keep normative semantics separate from implementation status.
- Label examples as frontend-only or production-executable.
- Generate capability tables from compiler-owned data where practical.
- Synchronize compiler, Tree-sitter grammar, documentation, package metadata,
  release notes, and website release identity.
- Publish benchmarks only with source, compiler revision, target profile,
  command, input, machine, and baseline.

**Acceptance:** Release checks detect stale versions, unsupported commands,
capability drift, retired ABI descriptions, and examples whose stated status
doesn't match the compiler.

## Integration order

WP-01 and WP-02 establish shared authority and should remain ahead of new
surface area. WP-03 through WP-06 extend AVX2 semantics and production
coverage. WP-07 and WP-08 add profiles after the shared operation contracts are
stable. WP-09 grows with every implementation package. WP-10 closes each
release slice and must never defer a known contradiction.
