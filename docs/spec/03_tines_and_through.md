# Tines, through and sweeps

Tines select lanes, through blocks compute under those masks, and the sweep chooses each lane's result. A tine
describes which lanes to select. A through block computes under that mask,
and the sweep chooses the value that leaves each lane.

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
example uses `f32s`. The development compiler also accepts `i32s` and `u32s`
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

Global tines can refer to other global tines, including ones defined later
in the file. Recursive definitions are rejected. Their arguments use pure
arithmetic and fields, with no ordinary function calls.

A rake can also define a local tine such as
`tine #valid means values >= <0.0>`. It refers directly to that rake's
inputs or setup bindings and is applied as `#valid`, without arguments.
Local tines can refer only to earlier local tines. A predicate combines
comparisons and tines with `not`, `and` and `or`.

`#valid(values) gaps` selects the complement: every lane that the tine
doesn't select. Parentheses invert a composed mask, as in
`(#positive or #negative) gaps`. This is Boolean inversion, not a different
numeric comparison. A NaN fails `x >= <0.0>` and therefore belongs to its
`gaps`, even though it also fails `x < <0.0>`.

## Through blocks

`through #valid(values) into rooted:` computes roots in the selected lanes
and binds them to `rooted`. Without `else`, the other lanes have no defined
value. The compiler permits a later read only under a mask that implies
the original mask. Reading `rooted` under `#valid(values) gaps`, or moving
its undefined lanes into a selected lane with a shuffle, is a compile error.

The header accepts a local tine, a global application, or a composed
predicate in parentheses, such as `through (#valid and #large gaps)`.
Add `else <0.0>` when a later calculation needs a complete rack. That
fallback supplies a value for every inactive lane and makes the binding
available under any later mask.

The body is any `let` and fused bindings, then the expression whose value is
the result. It can't assign, loop, call a function other than a built-in
operation, reduce across lanes, scan, or use `%`.

Bindings introduced inside the body are local to it. The identifier after `into`
belongs to the enclosing rake: later through blocks and the sweep can use
that value under its defined mask, or the complete rack if it has a fallback.

An inactive lane's computation doesn't happen. It can't fail on an invalid
operand, raise a floating-point exception, touch memory or have any other
effect from its through body. An explicit `else` supplies its result there.
Without `else`, the lane is undefined and can't be read. `rakec --interpret`
skips inactive lanes.

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

A score of 95 is in both tines, and the first arm gives it 3.
A sweep lists arms in priority order. For each lane, the first arm whose tine
holds gives the result. Tines may overlap, and the order of the arms decides
between them. A final `_` arm is optional when the preceding masks provably
cover every lane. Otherwise supply `_` or an explicit complementary mask
using `gaps`. Unreachable arms are rejected. `sweep:` is always the last
statement of a rake, and it gives the rake's result.

The coverage proof follows the Boolean relationships between tines. It can
prove `#a or #a gaps`, but it doesn't infer relationships between separate
numeric comparisons. For example, `x >= <0.0>` and `x < <0.0>` leave NaNs
uncovered. A later read is checked under its arm's effective mask, after
earlier arms have taken priority.

Backends implement the sweep with vector selections. Their inactive-lane
temporary values remain an implementation detail: checked source can't
read them or use them as a fallback.

## Intermediate and final fallbacks

A through block's optional `else` fills the inactive lanes of its
intermediate rack. A sweep's optional `_` supplies a final result for lanes
no earlier arm selected. They have different scopes, even when both are
zero. The first example needs no intermediate fallback because it reads
`rooted` only under its original tine.

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
zero in lane 1 is unused. Changing the through fallback to `<999.0>` leaves
the final result unchanged. The optimiser collapses the nested selections
on that same mask into one selection. If instead the sweep's `_` arm reads
`rooted`, its fallback lanes become part of the final result.

Tines, through blocks and sweeps are pure computations. They don't build lazy
operations that wait for the sweep to execute. The compiler optimises their
data flow together. A sweep selects a value for each lane in place, with no
scattering, compaction or rearrangement of lanes.
