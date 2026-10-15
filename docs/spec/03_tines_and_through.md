# Tines, through and sweeps

A tine selects lanes, a through block computes under that mask, and the
sweep chooses the value that leaves each lane.

<!-- rake-check: run 15 -->
```rake
tine #valid(values: f32s) means values >= <0.0>

rake safe_root(values: f32s) -> f32s:
  through #valid(values) into rooted:
    sqrt(values)

  sweep:
    | #valid(values) => rooted
    | #valid(values) gaps => <0.0>

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

A rake's body has any setup bindings, any local tines, at least one through
block, and its final sweep, in that order. Global tines are defined outside
the rake. Rakes compile on SSE2, AVX2, AVX-512, NEON and WebAssembly. The
example uses `f32s`, and the development compiler also accepts `i32s` and `u32s`
results with [the native integer operation subset](01_primitives_operations_and_targets.md#integer-racks).
A scratch, rake or run can call one.

## Tines

`tine #valid(values: f32s) means values >= <0.0>` defines a reusable
predicate with an explicit input. Applying `#valid(values)` computes one
Boolean per lane. A global tine captures no surrounding values and stores
no runtime mask. Every parameter has a type, with angle brackets around a
uniform parameter and its argument:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
tine #at_least(x: f32s, <limit: f32>) means x >= <limit>
tine #valid(x: f32s) means #at_least(x, <0.0>)

rake clipped_root(values: f32s) -> f32s:
  through #valid(values) into rooted:
    sqrt(values)
  sweep:
    | #valid(values) => rooted
    | #valid(values) gaps => <0.0>
```

Global tines can refer to other global tines, including later ones in the
file, but not recursively. Their arguments use pure
arithmetic and fields, with no ordinary function calls.

A rake can also define a local tine such as
`tine #valid means values >= <0.0>`. It refers directly to that rake's
inputs or setup bindings and is applied as `#valid`, without arguments.
Local tines can refer only to earlier local tines. A predicate combines
comparisons and tines with `not`, `and` and `or`.

`#valid(values) gaps` selects the complement: every lane outside the tine.
Parentheses invert a composed mask, as in `(#positive or #negative) gaps`.
You might read the gaps of `x >= <0.0>` as `x < <0.0>`, but `gaps` inverts
the Boolean mask instead of the comparison, so a NaN, which fails both
comparisons, belongs to the gaps.

## Through blocks

`through #valid(values) into rooted:` computes roots in the selected lanes
and binds them to `rooted`. Without `else`, the other lanes have no defined
value. The compiler permits a later read only under a mask that implies
the original mask. Reading `rooted` under `#valid(values) gaps`, or moving
its undefined lanes into a selected lane with a shuffle, is a compile error.

The header accepts a local tine, a global application, or a composed
predicate in parentheses, such as `through (#valid and #large gaps)`.
A fallback such as `else <0.0>` supplies a value for every inactive lane, so
a later calculation can read the binding as a complete rack under any mask.

The body is any `let` and fused bindings, then a final expression giving
the result. It can't assign, loop, call a function other than a built-in
operation, reduce across lanes, scan, or use `%`.

Bindings inside the body are local to it, while the identifier after `into`
belongs to the enclosing rake.

An inactive lane's computation doesn't happen. It can't fail on an invalid
operand, raise a floating-point exception, touch memory or have any other
effect from its through body, and `rakec --interpret` skips it.

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
WebAssembly has no floating-point exception state, so on `wasm-simd128` the
compiler replaces no operands and the final selection discards each inactive
lane's value. Memory accesses stay masked on every target.

## Sweeps

<!-- rake-check: run 3212 -->
```rake
tine #high(scores: f32s) means scores >= <90.0>
tine #pass(scores: f32s) means scores >= <50.0>

rake grade(scores: f32s) -> f32s:
  through #high(scores) into top:
    <3.0>
  through #pass(scores) into middle:
    <2.0>

  sweep:
    | #high(scores) => top
    | #pass(scores) => middle
    | (#high(scores) or #pass(scores)) gaps => <1.0>

run grades(x: []f32, out: mut []f32):
  out[<0>] <- grade(x[<0>])

slow main() -> i32:
  scores: [4]f32 := [95.0, 60.0, 10.0, 50.0]
  result: [4]f32 := [0.0; 4]
  grades(scores, result)
  return i32(result[0] * 1000.0 + result[1] * 100.0 + result[2] * 10.0 + result[3])
```

A sweep lists arms in priority order, and for each lane the first arm whose
tine holds gives the result, so a score of 95, which is in both tines, gets 3.
A final `_` arm is optional when the preceding masks provably cover every
lane. Otherwise the sweep needs `_` or an explicit complementary mask using
`gaps`. Unreachable arms are rejected.

The coverage proof follows the Boolean relationships between tines, so it
can prove `#a or #a gaps`, but it doesn't relate separate numeric
comparisons: `x >= <0.0>` and `x < <0.0>` leave NaNs uncovered. A later read
is checked under its arm's effective mask, after earlier arms have taken
priority.

Backends implement the sweep with vector selections. Checked source can't
read their temporary values in inactive lanes or use them as a fallback.

## Intermediate and final fallbacks

A through block's optional `else` fills the inactive lanes of its
intermediate rack. A sweep's optional `_` supplies a final result for every
lane left unselected by earlier arms, so they have different scopes even when both are
zero.

<!-- rake-check: run 7 -->
```rake
rake safe_root(values: f32s) -> f32s:
  tine #valid means values >= <0.0>
  through #valid else <0.0> into rooted:
    sqrt(values)
  sweep:
    | #valid => rooted
    | _      => <-1.0>

run roots(x: []f32, out: mut []f32):
  out[<0>] <- safe_root(x[<0>])

slow main() -> i32:
  values: [4]f32 := [16.0, -4.0, 9.0, 1.0]
  result: [4]f32 := [0.0; 4]
  roots(values, result)
  return i32(result[0] + result[1] + result[2] + result[3])
```

| Stage | Lane 0 | Lane 1 | Lane 2 | Lane 3 |
| --- | ---: | ---: | ---: | ---: |
| Input | 16 | −4 | 9 | 1 |
| `#valid` | true | false | true | true |
| `rooted` | 4 | 0 | 3 | 1 |
| Result | 4 | −1 | 3 | 1 |

Here the sweep reads `rooted` only where `#valid` holds, so the intermediate
zero in lane 1 is unused and a fallback of `<999.0>` would give the same
result. The optimiser collapses the nested selections on that same mask into
one selection. If the sweep's `_` arm read `rooted` instead, its fallback
lanes would become part of the final result.

Tines, through blocks and sweeps are pure computations, evaluated where they
appear, and the compiler optimises their data flow together. A sweep selects
a value for each lane in place, with no scattering, compaction or
rearrangement of lanes.
