## Phase 1: Complete Core Emission

### 1.1 Fix record emission

Location: `lib/mlir.ml:323-337`

Current just emits a comment. Options:

**Option A**: Emit as separate SSA values (current implicit approach, make
explicit)

```ocaml
(* Records decompose to individual field values in SSA *)
(* Store field->value mappings for later field access *)
```

**Option B**: Use MLIR tuple type

```mlir
%rec = tuple.from_elements %field1, %field2 : tuple<f32, f32>
```

### 1.2 Fix hardcoded return types

Location: `lib/mlir.ml:641` (`emit_crunch`)

Current:

```ocaml
emit ctx "func.func @%s(%s) -> %s ..." name ... vec_f32;  (* always f32 *)
```

Fix: use the result type from the function signature:

```ocaml
let result_type = match result.result_type with
  | Some ty -> mlir_type (typ_to_t ctx.type_env ty)
  | None -> vec_f32  (* default *)
in
emit ctx "func.func @%s(%s) -> %s ..." name ... result_type;
```

### 1.3 Handle Unknown types in type checker

Locations in `lib/typecheck.ml`:

- `EOuter` (line 270): Outer product type is matrix — implement properly or
  error
- `EGather` (line 254): Should infer from base pointer type
- `ELambda` (line 278): Should produce `Fun(param_types, body_type)`

For now, convert `Unknown` returns to explicit errors:

```ocaml
| EOuter (_, _) ->
    type_errorf expr.loc "Outer product not yet implemented"
```

---

## Phase 2: Semantic Completeness

### 2.1 Sweep exhaustiveness check

Add warning/error if sweep tines don't cover all cases and no catch-all `_`
present.

In `check_sweep`:

```ocaml
let has_catchall = List.exists (fun arm -> arm.arm_tine = None) sw.sweep_arms in
if not has_catchall then
  (* Could warn, or require explicit catch-all *)
  ()
```

### 2.2 Document tine priority semantics

Current: first matching tine wins (due to select chain order). Document this in
spec or add mutual-exclusivity check.

### 2.3 Update spec for `arith.select` vs `vector.mask`

The current implementation uses `arith.select` for through blocks. This is
correct for side-effect-free code. Update `docs/spec/03_tines_and_through.md` to
reflect the actual implementation

---

## Phase 3: Testing Infrastructure

### 3.1 Build test harness

Create `test/harness.c`:

```c
#include <stdio.h>
#include <math.h>

// Declare Rake functions (will be linked from compiled .o)
extern void compute_distances(float* ox, float* oy, float* oz,
                              float cx, float cy, float cz,
                              long count, float* out);

int main() {
    float ox[] = {1, 2, 3, 4, 5, 6, 7, 8};
    float oy[] = {0, 0, 0, 0, 0, 0, 0, 0};
    float oz[] = {0, 0, 0, 0, 0, 0, 0, 0};
    float out[8];

    compute_distances(ox, oy, oz, 0, 0, 0, 8, out);

    for (int i = 0; i < 8; i++) {
        float expected = sqrtf(ox[i]*ox[i]);
        if (fabsf(out[i] - expected) > 0.001f) {
            printf("FAIL: out[%d] = %f, expected %f\n", i, out[i], expected);
            return 1;
        }
    }
    printf("PASS\n");
    return 0;
}
```

### 3.2 End-to-end test script

```bash
#!/bin/bash
# test/run_tests.sh

set -e

for rk in examples/*.rk; do
    echo "Testing $rk..."

    # Compile Rake -> MLIR
    ./rake --emit-mlir "$rk" > "${rk%.rk}.mlir"

    # Lower to LLVM
    mlir-opt "${rk%.rk}.mlir" \
        --convert-scf-to-cf \
        --convert-vector-to-llvm \
        --convert-func-to-llvm \
        --convert-arith-to-llvm \
        --reconcile-unrealized-casts \
        -o "${rk%.rk}.llvm.mlir"

    # Translate to LLVM IR
    mlir-translate --mlir-to-llvmir "${rk%.rk}.llvm.mlir" -o "${rk%.rk}.ll"

    # Compile to object
    llc -filetype=obj "${rk%.rk}.ll" -o "${rk%.rk}.o"

    echo "  Generated ${rk%.rk}.o"
done
```

### 3.3 Test cases to implement

1. **Simple crunch** — arithmetic, verify vectorization
2. **Rake with tines** — predicated execution
3. **Over loop** — pack iteration, tail masking
4. **Reductions** — `\+/`, `\*/`
5. **Broadcasting** — scalar to rack promotion
6. **Field access** — stack/single member access
7. **Nested tines** — composed predicates

IDEALLY: Use an actual code coverage tool (or create one for rake) to show
coverage of unit tests over language grammar / features.

---

## Phase 4: Quality of Life

NOTE: For all controls, we must carefully consider where they should be
permitted. For example, branching conditions inside a sweep could break
vectorization. Validate through the test suite that vectorized code is always
generated for rakes. If this can't be done with conditionals, the grammar should
have a separate mode inside of rakes that does not allow the breaking
constructs.

### 4.1 Better error messages

Include source location in all errors:

```ocaml
type_errorf expr.loc "Type mismatch at %s:%d:%d: ..."
  loc.file loc.line loc.col
```

### 4.2 Add `if/else` expressions

New AST node:

```ocaml
| EIf of expr * expr * expr  (* condition, then, else *)
```

Emit as `scf.if` (for scalar mode) or `arith.select` (for vector mode).

### 4.3 Add basic `for` loop

For fixed iteration counts (useful for unrolling):

```rake
for i in 0..4:
    accumulate(i)
```

Emit as `scf.for` with known bounds.

### 4.4 Complete math builtins

Type checker lists: `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `abs`, `floor`,
`ceil`, `min`, `max`, `pow`, `atan2`

Ensure emitter handles all of these (currently partial).

---

## Deferred (Post-MVP)

- Module/import system
- Closures with variable capture
- Strings and I/O
- Memory management (GC or ownership)
- Custom MLIR dialect for Rake-specific optimizations
- GPU texture/image support
- Warp-level primitives for GPU

---

## Decision Log

| Date    | Decision                                         | Rationale                                  |
| ------- | ------------------------------------------------ | ------------------------------------------ |
| 2024-12 | Use `arith.select` for through blocks            | Simpler emission, equivalent for pure code |
| 2024-12 | Prioritize `scf.parallel` over fixing type holes | Enables GPU path, higher impact            |
| TBD     | Scalar mode as default, vector as optimization   | Lets MLIR handle parallelization strategy  |
