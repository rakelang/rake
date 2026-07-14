# Fused-flow bindings

A binding gives a computed value a name. A later reference uses that compiler
value again; it does not imply a pointer, memory location, copy, or reload.
Physical storage is a separate lowering decision. An ordinary compiler may keep
a live value in a register or temporarily write it to memory and reload it, an
operation called a spill.

A fused-flow binding has the form:

```text
| name: type <| expression
```

The type annotation is optional. Read `<|` from right to left: the expression
flows into `name`. Consecutive leading bars align the stages as a visible data
path:

<!-- rake-example:crunch:start -->
```rake
crunch advance(positions: f32s, velocities: f32s) -> f32s:
  | scaled: f32s <| velocities * <0.5>
  | result: f32s <| positions + scaled
  return result
```
<!-- rake-example:crunch:end -->

`<|` exists only on a fused-flow binding. It requires the compiler to preserve
a verified, contiguous vector computation. The name is still an SSA value
rather than a storage location, evaluation point, or rounding boundary.

The two bindings above describe the same fused graph as this single binding:

```text
| result: f32s <| positions + velocities * <0.5>
```

`scaled` improves readability. The compiler substitutes its expression into
later fused uses before choosing instructions.

Every accepted rack already obeys Rake's one-register and no-spill rules,
including racks introduced with an ordinary `let`. A consecutive chain of
fused-flow bindings adds purity, connectedness, contiguity, and call-freedom as
explicit obligations for the whole region.

## Contract

A fused-flow binding is immutable and fail-closed. The compiler either proves
the contract at compile time or rejects the statement; there is no best-effort
fallback.

Verification requires all of the following:

1. `name` is fresh in the current SSA scope.
2. `expression` is pure: it cannot read or write observable mutable memory or
   invoke a function whose effects are unknown.
3. Every nested operation has a supported inline expression shape.
4. Every call targets a compiler-known pure operation with a compliant native
   lowering on the selected profile.

The ordinary type and target capability checks still apply. User-defined calls
require an effect contract before they can enter a fused region. Memory
operations, mutation, cross-lane reductions and scans, and unverified
rearrangements remain outside it.

A rejection names the binding and the failed obligation:

```text
Fused-flow contract for 'name' rejected: reason
```

## Evidence through lowering

Native lowering emits an accepted expression as a contiguous sequence of typed
rack or mask SSA operations. Each operation retains the region identity and
source location through legalization, instruction selection, and register
allocation.

The region may not contain a call, spill, reload, hidden scalar lane operation,
or unsupported instruction. Its live racks must fit the profile's physical
register budget. If they do not, compilation fails at the source location that
exceeded the budget.

The general native-rack rule already forbids spills for rack values. A fused
region additionally makes purity, contiguity, call-freedom, and any promised
single-instruction operation explicit verification obligations.

## Graph optimization and explicit arithmetic

Ordinary arithmetic operators describe the fused graph's mathematical
dataflow. They do not prescribe instruction boundaries or observable
intermediate rounding. After substituting fused names, the language permits the
backend to use commutation, association, factoring, distribution, common-subexpression
elimination, strength reduction, and fused instruction formation to find the
lowest-cost legal graph for the selected profile. Different profiles may
therefore round an ordinary floating-point expression at different points.

That paragraph defines the language contract, not the current optimizer's full
coverage. The 0.3 alpha substitutes transparent fused aliases, removes the
resulting dead intermediate, and contracts multiply-add to FMA using a static
per-target operation cost. General reassociation, factoring, distribution,
common-subexpression elimination, and strength reduction remain implementation
work. Until they land, “fastest” means the cheapest graph among the rewrites the
compiler currently knows, with verification of the selected machine form.

For example, the two-stage `advance` graph normally contracts to one native
fused multiply-add on AVX2 or AArch64 NEON. Its optimized native SSA contains
`rack.fma` and no separate multiply or add. A multiply that has another consumer
remains available to that consumer while the addition may still become an FMA.

`fma(a, b, c)` is needed when correctness depends specifically on multiplying
`a` by `b`, adding `c`, and rounding once. It states arithmetic semantics rather
than requesting an optimization that the compiler would otherwise overlook.
The `x86-avx2` and `aarch64-neon` profiles must select one native fused
multiply-add instruction for that operation. Object verification checks every
FMA selected by the optimizer as well as every source-required FMA. A profile
without a verified native fused instruction rejects an explicit `fma`.

Rake has no slower arithmetic mode. A program that depends on a particular
operation must name that operation; otherwise the backend chooses the fastest
legal lowering known to its target cost model.

Strict reductions and scans are separate named operations. Their published
ascending-lane order is a correctness boundary and is not opened to fused-flow
reassociation merely because their input was produced by a fused region.
