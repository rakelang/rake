# Control Flow Constructs

This document specifies the design for control flow constructs in Rake 0.3.0.

## 1. If/Else Expressions

### 1.1 Proposed Syntax

```rake
# Simple if/else expression
let result = if condition then value1 else value2

# Multi-line if/else
let result = if condition then
  expr1
else
  expr2

# Chained conditions
let result = if cond1 then val1
             else if cond2 then val2
             else val3
```

### 1.2 Semantics

If/else expressions are **value-producing**: they always return a value, and both branches must have compatible types.

- `condition` must be of type `mask` (scalar `i1` in GPU mode, `vector<Wxi1>` in CPU mode)
- Both branches must have the same type (or compatible types that can be unified)
- The expression returns a value, not a statement

### 1.3 MLIR Mapping

#### 1.3.1 Scalar Mode (GPU, width=1)

In scalar mode, if/else maps to `scf.if`:

```mlir
%result = scf.if %condition -> (f32) {
  // true branch
  %val1 = ...
  scf.yield %val1 : f32
} else {
  // false branch
  %val2 = ...
  scf.yield %val2 : f32
}
```

`scf.if` naturally handles scalar conditionals and produces a result.

#### 1.3.2 Vector Mode (CPU, width > 1)

In vector mode, if/else maps to `arith.select`:

```mlir
// Evaluate both branches
%true_val = ...   ; value if condition is true
%false_val = ...  ; value if condition is false

// Select based on mask (per-lane)
%result = arith.select %mask, %true_val, %false_val : vector<8xi1>, vector<8xf32>
```

**Important**: `arith.select` evaluates **both** branches unconditionally, then selects per lane. This is semantically different from `scf.if` which only executes one branch.

### 1.4 Vectorization Considerations

#### 1.4.1 If/Else Inside Rakes

When if/else appears inside a rake function (which operates on vector lanes), special care is needed:

```rake
rake compute x -> result:
  # This is problematic!
  let y = if x > 0.0 then sqrt(x) else 0.0
```

**Problem**: Different lanes may take different branches. With `arith.select`, both branches are always evaluated. This means:
- `sqrt(x)` is computed even for lanes where `x <= 0.0`
- This may cause undefined behavior (sqrt of negative) or wasted computation

**Solution Options**:

1. **Masked Operations** (preferred for Rake's tine/through model):
   Use the existing tine/through/sweep pattern instead:
   ```rake
   rake compute x -> result:
     | positive := x > 0.0
     through positive:
       sqrt(x)
       -> pos_result
     sweep:
       | positive -> pos_result
       | _ -> 0.0
     -> result
   ```

2. **Safe Select** (for simple cases):
   Replace potentially unsafe operations with safe versions:
   ```rake
   let y = if x > 0.0 then sqrt(abs(x)) else 0.0
   ```

3. **Compiler Warning**:
   The type checker should warn when if/else contains potentially unsafe operations inside rake functions.

#### 1.4.2 Recommended Usage

- **Use if/else** for scalar control flow in `run` and `crunch` functions
- **Use tine/through/sweep** for divergent control flow in `rake` functions
- **Use if/else in rakes** only when both branches are safe to evaluate unconditionally

### 1.5 Type Checking

The type checker should:

1. Verify condition is of type `mask`
2. Infer types of both branches
3. Unify branch types (error if incompatible)
4. Return the unified type as the expression type
5. Warn if inside a rake and branches contain potentially unsafe operations

---

## 2. For Loops

### 2.1 Proposed Syntax

```rake
# Range-based for loop
for i in 0..4:
  body

# With explicit step
for i in 0..10 by 2:
  body

# Reverse iteration
for i in 10..0 by -1:
  body
```

### 2.2 Semantics

For loops iterate over a range with known bounds at compile time. This is critical for SIMD efficiency.

- Loop bounds must be compile-time constants (for unrolling optimization)
- Loop variable `i` is of type `scalar int` (not a rack)
- Loop body is executed sequentially for each iteration
- The loop itself produces `unit` type (use mutable locations for accumulation)

### 2.3 MLIR Mapping

For loops map to `scf.for`:

```mlir
// for i in 0..4: body
%c0 = arith.constant 0 : index
%c4 = arith.constant 4 : index
%c1 = arith.constant 1 : index

scf.for %i = %c0 to %c4 step %c1 {
  // body
}
```

For loops with carried state (accumulators):

```mlir
// for i in 0..4: acc = acc + compute(i)
%init = arith.constant 0.0 : f32
%result = scf.for %i = %c0 to %c4 step %c1 iter_args(%acc = %init) -> (f32) {
  %val = func.call @compute(%i) : (index) -> f32
  %new_acc = arith.addf %acc, %val : f32
  scf.yield %new_acc : f32
}
```

### 2.4 Unrolling Considerations

#### 2.4.1 Full Unrolling

For small, known trip counts, the compiler should fully unroll:

```rake
for i in 0..4:
  process(data[i])
```

Becomes:

```mlir
// Fully unrolled - no loop overhead
%v0 = func.call @process(%data0) : ...
%v1 = func.call @process(%data1) : ...
%v2 = func.call @process(%data2) : ...
%v3 = func.call @process(%data3) : ...
```

**Unrolling threshold**: Loops with 8 or fewer iterations should be fully unrolled by default.

#### 2.4.2 Partial Unrolling

For larger loops, partial unrolling improves instruction-level parallelism:

```rake
for i in 0..1024:
  process(data[i])
```

With unroll factor 4:

```mlir
scf.for %i = %c0 to %c1024 step %c4 {
  %i0 = %i
  %i1 = arith.addi %i, %c1 : index
  %i2 = arith.addi %i, %c2 : index
  %i3 = arith.addi %i, %c3 : index
  // 4 operations per iteration
  func.call @process(...)
  func.call @process(...)
  func.call @process(...)
  func.call @process(...)
}
```

#### 2.4.3 Vector Width Alignment

Loop unrolling should consider vector width:

- For AVX2 (width 8), unroll by 8 or multiples
- For AVX-512 (width 16), unroll by 16 or multiples

This ensures optimal register utilization.

### 2.5 Interaction with Vectorization

For loops interact with the vector model in several ways:

#### 2.5.1 Outer Loops

For loops **outside** vector operations iterate over groups of lanes:

```rake
run process_all (data: Data pack) <n: int> -> result:
  for batch in 0..4:
    over data, n |> chunk:
      compute(chunk)
```

This processes data in 4 batches, each batch processing `n` elements with SIMD.

#### 2.5.2 Inner Loops

For loops **inside** rake functions apply to each lane:

```rake
rake compute x -> result:
  let sum = 0.0
  for i in 0..4:
    sum := sum + x * <i>  # Each lane computes 4 iterations
  sum
```

**Note**: The loop variable is broadcast to all lanes (`<i>`).

### 2.6 Type Checking

The type checker should:

1. Verify loop bounds are integer expressions
2. Prefer compile-time constant bounds (warn otherwise)
3. Add loop variable to scope with `scalar int` type
4. Check body statements in loop scope
5. Return `unit` type for the loop expression

---

## 3. Future Considerations

### 3.1 While Loops

While loops with dynamic conditions are intentionally not supported initially because:
- They complicate vectorization
- Unknown trip counts prevent loop unrolling optimization
- They can mask performance bugs

If needed in the future, they should only be allowed in `run` functions (not rakes).

### 3.2 Pattern Matching

Full pattern matching could subsume if/else:

```rake
let result = match x with
  | _ when x > 0.0 -> sqrt(x)
  | _ -> 0.0
```

This would integrate naturally with the tine/through/sweep model.

### 3.3 Parallel For

A parallel for construct for independent iterations:

```rake
parallel for i in 0..n:
  output[i] = compute(input[i])
```

This would map to `scf.parallel` and enable GPU parallelization.
