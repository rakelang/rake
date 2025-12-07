# Tines, Through Blocks, and Sweep

This document specifies the semantics of Rake's control flow primitives for divergent execution: tines, through blocks, and sweep.

## Overview

Rake uses a declarative approach to express divergent control flow within SIMD lanes:

1. **Tines** declare named boolean masks based on predicates
2. **Through blocks** execute code under a specific mask, producing a result
3. **Sweep** collects results from different tines into a single value

This model allows the compiler to emit efficient vectorized code while giving programmers a clear mental model for lane-divergent behavior.

## Tines

A tine declares a named mask (boolean vector) based on a predicate:

```rake
| tine name := predicate
```

The predicate evaluates to a mask where each lane is `true` if the condition holds for that lane's data.

### Tine Evaluation Order and Priority

**Important**: Tines are evaluated and applied in declaration order. When multiple tines could match a lane, the **first declared tine wins**.

This priority rule affects sweep blocks (see below) where the select chain is built in declaration order. For example:

```rake
| tine positive := x > 0.0
| tine small := x < 10.0
```

For a value `x = 5.0`:
- Both `positive` and `small` would match
- In a sweep, `positive` takes precedence because it was declared first

### Predicate Composition

Tines can reference other tines to build composed predicates:

```rake
| tine hot := temp > 100.0
| tine wet := humidity > 0.8
| tine steam := #hot && #wet
```

The `#name` syntax references another tine's mask value.

## Through Blocks

A through block executes statements under a mask and produces a result:

```rake
through tine_name [else passthru]:
    statements...
-> result_binding
```

### Masked Execution Semantics

Through blocks use `arith.select` to implement masked execution. This means:

1. The body is **always evaluated** for all lanes
2. The final result is selected between the computed value (where mask is true) and the passthrough value (where mask is false)

This approach is correct and efficient for **side-effect-free** code, which is enforced for all rake/crunch functions (they must be pure).

### Implementation: arith.select vs vector.mask

The current implementation uses `arith.select` rather than `vector.mask` for through blocks:

```mlir
// Through block emission
%result = arith.select %mask, %computed, %passthru : vector<8xi1>, vector<8xf32>
```

**Rationale**:
- `arith.select` is simpler and sufficient for pure computations
- Since rake/crunch functions cannot have side effects, there is no observable difference between "computing but not using" versus "not computing"
- LLVM can often optimize away unused computations

**When vector.mask would be needed**:
- If Rake ever supports side-effecting operations inside through blocks (e.g., memory writes, I/O)
- For operations where computation itself has costs even if result is discarded (though LLVM handles this for most cases)

### GPU Mode

In GPU scalar mode, through blocks may emit `scf.if` instead of `arith.select`, allowing actual branch divergence. This is handled automatically by the emitter based on the emission mode.

## Sweep

A sweep block collects results from multiple tines into a single value:

```rake
sweep:
    | tine1 -> value1
    | tine2 -> value2
    | _ -> default_value
-> result_binding
```

### Sweep Arm Priority (First Match Wins)

Sweep arms are evaluated in **declaration order**, and the first matching tine determines the value for each lane. This is implemented as a nested `arith.select` chain:

```mlir
// For sweep with arms: positive -> a, negative -> b, _ -> c
%sel0 = arith.select %negative_mask, %b, %c : ...
%result = arith.select %positive_mask, %a, %sel0 : ...
```

The chain is built from last-to-first, so earlier-declared arms take priority.

### Catch-All Arm (`_`)

The catch-all arm (`| _ -> value`) provides a default for lanes that don't match any named tine.

**Warning**: If no catch-all arm is present, lanes not matching any tine will have **undefined values** (initialized to zero in the current implementation, but this should not be relied upon). The type checker emits a warning when a sweep lacks a catch-all arm.

### Type Consistency

All sweep arms must produce values of compatible types. The type checker enforces that arm types match, with appropriate scalar-to-rack broadcasting.

## Example: Ray-Sphere Intersection

```rake
rake intersect ray <sphere> -> hit:
    // Setup
    let oc = ray.origin - sphere.center
    let a = dot(ray.dir, ray.dir)
    let b = 2.0 * dot(oc, ray.dir)
    let c = dot(oc, oc) - sphere.radius * sphere.radius
    let disc = b * b - 4.0 * a * c

    // Tines declare masks
    | tine miss := disc < 0.0
    | tine hit := disc >= 0.0

    // Through blocks compute per-tine results
    through hit:
        let t = (-b - sqrt(disc)) / (2.0 * a)
        let point = ray.origin + t * ray.dir
        let normal = (point - sphere.center) / sphere.radius
    -> intersection

    // Sweep collects results
    sweep:
        | hit -> Hit { t := t, point := point, normal := normal }
        | miss -> Miss {}
        | _ -> Miss {}  // Explicit catch-all (optional but recommended)
    -> hit
```

## Design Notes

### Why First-Match Semantics?

The first-match-wins rule was chosen for several reasons:

1. **Predictability**: Programmers can reason about priority by reading top-to-bottom
2. **Efficiency**: Generates a linear select chain, no need for mutual exclusivity checks
3. **Flexibility**: Allows overlapping conditions when useful

If you need mutually exclusive conditions, structure your predicates accordingly:

```rake
| tine cold := temp < 32.0
| tine warm := temp >= 32.0 && temp < 80.0  // Explicitly exclude cold
| tine hot := temp >= 80.0
```

### Future Considerations

- **Mutual exclusivity checking**: Could add an optional lint/check for overlapping tines
- **Parallel tine evaluation**: Current semantics allow but don't require short-circuit evaluation
- **Nested tines**: Currently through blocks cannot contain new tine declarations
