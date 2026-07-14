# Proposal: general control flow

This document proposes control-flow forms beyond Rake's tine, through, sweep,
and pack-traversal constructs. The syntax is reserved for design work and is
not part of the executable language contract. The capability report lists the
forms implemented by a compiler revision.

## Value-producing conditionals

Proposed syntax:

```rake,proposal
let result = if condition then value1 else value2
```

A conditional produces one value. Its condition and branches must belong to
one of two explicitly different semantic classes.

### Scalar condition

A scalar boolean selects one branch. Only the selected branch is evaluated.
This form is suitable for scalar orchestration outside lane-dependent kernel
work. Its typed IR uses a structured conditional whose two regions yield the
same type.

### Rack mask

A rack mask selects a value independently in each lane. Both candidate
computations must be pure and safe under the active mask. The semantics are the
same as a one-arm `through` followed by total selection: inactive lanes cannot
raise floating-point exceptions, access invalid memory, or produce effects.

Native lowering must retain vector predication. A target may select between
already-total candidate racks, sanitize unsafe operands, or use native masked
instructions. The backend must reject a branch whose operations cannot satisfy
the inactive-lane rule. Per-lane scalar branches are forbidden.

The existing tine/through/sweep syntax remains the primary form for divergent
kernel work because it names masks and totality explicitly.

## Fixed-count iteration

Proposed syntax:

```rake,proposal
repeat <i: i32> from <0> up to <4>:
  body
```

Angle brackets mark the scalar induction variable and scalar bounds. Bounds and
step must be compile-time constants in the first implementation. The loop body
may yield typed loop-carried values; mutation is not required to express an
accumulator.

The typed native IR represents the loop as a structured region with explicit
initial values, induction value, carried values, and yields. Target
legalization chooses full unrolling, partial unrolling, or a scalar loop around
whole-rack operations. The choice must preserve every live rack as one native
register. A loop inside a rack computation cannot become separate per-lane
iteration.

Unrolling is a pressure-aware target decision. No fixed universal trip-count
threshold is part of the language contract. The allocator may reject a forced
unroll when its live racks exceed the profile budget.

## Interaction with pack traversal

`for chunk in input using f32s up to <count>:` traverses pack storage in
native-rack chunks and is distinct from a source-level fixed-count loop. A
future general loop around pack traversal repeats whole traversals. A future
loop inside a crunch or rake repeats vector operations on the same racks.

Native `run` lowering remains responsible for full-rack iteration, safe tails,
pointer validity, and the binary boundary specified in
[`02_packs_and_run.md`](02_packs_and_run.md). Safe tails cover both bounded
memory access and suppression of floating-point exceptions from inactive
lanes. General loop syntax cannot weaken those obligations. The current native
backend does not implement this traversal contract yet.

## Acceptance requirements

Neither proposed form becomes executable merely because the parser recognizes
it. Production acceptance requires:

1. complete type and scope rules;
2. scalar-interpreter semantics for results, effects, and exceptional values;
3. typed-IR verification for structured regions and dominance;
4. per-profile legalization and register-pressure handling;
5. native runtime comparison with the interpreter; and
6. assembly/disassembly checks for vector register classes, calls, spills,
   scalar lane branches, and any promised unrolling.
