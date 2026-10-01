# Tines, through and sweeps

A rake computes a different value in different lanes without branching. Tines
name lane masks, through blocks compute values under them, and a sweep picks
each lane's result.

<!-- rake-check: run 15 -->
```rake
rake safe_root(values: f32s) -> f32s:
  tine #valid when values >= <0.0>

  through #valid else <0.0> into rooted:
    sqrt(values)

  return sweep:
    | #valid => rooted
    | _      => <0.0>

run roots(x: []f32, out: mut []f32, <n: i32>):
  for <i: i32> from <0> up to <n> by <4>:
    out[<i>] <- safe_root(x[<i>])

slow main() -> i32:
  values: [8]f32 := [4.0, -1.0, 9.0, 16.0, -4.0, 25.0, 0.0, 1.0]
  rooted: [8]f32 := [0.0; 8]
  roots(values, rooted, <8>)
  total := 0.0
  for i from 0 up to 8:
    total <- total + rooted[i]
  return i32(total)
```

A rake's body has four parts in this order: `let` bindings, at least one
tine, at least one through block, and the sweep. Its racks are `f32s`. Rakes
compile on `x86-avx2`, `aarch64-neon` and `wasm-simd128`, and a crunch, rake
or run can call one.

## Tines

`tine #valid when values >= <0.0>` declares a mask with one Boolean for each
lane. The predicate compares float racks and uniforms, and combines
comparisons and earlier tines with `not`, `and` and `or`. Its operands may
use arithmetic and fields, but no calls. A tine can refer only to tines
declared before it, and each name is declared once. A tine is only a mask: it
computes nothing else and stores nothing.

## Through blocks

`through #valid else <0.0> into rooted:` computes its body in the lanes of
`#valid` and calls the result `rooted`. The lanes outside the tine take the
`else` value, a uniform or a literal. The header gives one tine or a
predicate in parentheses, such as `through (#valid and not #large)`.

The body is any `let` and fused bindings, then the expression whose value is
the result. It can't assign, loop, call a function other than a built-in
operation, reduce across lanes, scan, or use `%`.

An inactive lane's computation doesn't happen. It can't fail on an invalid
operand, raise a floating-point exception, touch memory or have any other
effect, and the result has the `else` value there. `rakec --interpret` skips
inactive lanes.

A vector backend computes every lane, so it replaces the operands of
inactive lanes with benign values before each operation that could raise an
exception, then selects the results:

| Operation | Benign operands in inactive lanes |
| --- | --- |
| `sqrt` | `1.0` |
| `+`, `-`, `min`, `max`, comparisons | `0.0` |
| `*` | `1.0` |
| `/` | `0.0` divided by `1.0` |
| `fma` | `0.0` |

The native IR records each replacement, and the IR verifier rejects an
exception-capable operation under a mask whose operands weren't replaced.
WebAssembly has no floating-point exception state, so its instructions never
trap or set a flag. On `wasm-simd128` an inactive lane's value is discarded by
the final selection, and the compiler replaces no operands. Memory accesses
stay masked on every target.

## Sweeps

<!-- rake-check: run 3212 -->
```rake
rake grade(scores: f32s) -> f32s:
  tine #high when scores >= <90.0>
  tine #pass when scores >= <50.0>

  through #high else <0.0> into top:
    <3.0>
  through #pass else <0.0> into middle:
    <2.0>

  return sweep:
    | #high => top
    | #pass => middle
    | _     => <1.0>

run grades(x: []f32, out: mut []f32):
  out[<0>] <- grade(x[<0>])

slow main() -> i32:
  scores: [4]f32 := [95.0, 60.0, 10.0, 50.0]
  result: [4]f32 := [0.0; 4]
  grades(scores, result)
  return i32(result[0] * 1000.0 + result[1] * 100.0 + result[2] * 10.0 + result[3])
```

A score of 95 is in both `#high` and `#pass`, and the first arm gives it 3.
A sweep lists arms in priority order. For each lane, the first arm whose tine
holds gives the result, and the final `_` arm gives the result for every lane
no earlier arm took. Tines may overlap, and the order of the arms decides
between them. Every sweep ends with exactly one `_` arm. The compiler rejects
a sweep without one, an arm after it, or a tine named twice. `return sweep:`
is always the last statement of a rake, and it gives the rake's result.

The backends build the sweep from vector selections, starting from the `_`
value and applying the named arms from last to first, so every lane gets a
value from the source.
