# Memory operations

Runs read and write memory through views and packs. This page defines
accesses and the gather, implemented on `wasm-simd128`. Scatter,
compression and expansion are designs, and no backend implements them yet.

## Accesses

A view, `[]T`, is a count of elements of type `T`, and a run reads and
writes it with these forms:

| Form | Meaning |
| --- | --- |
| `view[<i>]` | the rack of consecutive elements starting at element `i` |
| `<view[i]>` | element `i`, as a uniform |
| `view[indices]` | a gather: element `indices[k]` in each lane `k` |
| `view[<i>] <- rack` | a store of consecutive elements starting at element `i` |

Indices count elements, never bytes, and there's no pointer arithmetic.
Accesses are checked, so an access traps before touching memory unless all of
its elements are in bounds. `view[unchecked <i>]` and
`view[unchecked indices]` drop the check, which makes the caller responsible
for keeping the access in bounds. An unchecked access out of bounds is outside
Rake's semantics. Slow code uses the same `[unchecked i]` spelling for its
elements.

Inside a mask, only the active lanes take part. A memory access's mask is
the conjunction of the masks that apply to it, from a `through` block and from
a stack run's tail. An inactive lane is never checked, and it computes no
address and makes no access. A full load followed by a blend breaks this
rule, because it touches the inactive lanes' memory.

## Gather

A gather indexes a view with an `i32s` or `u32s` rack of element indices. The
view's elements are 32 bits wide: `f32`, `i32` or `u32`.

<!-- rake-check: run 102 -->
```rake
run lookup(table: []f32, places: []i32, out: mut []f32):
  out[<0>] <- table[places[<0>]] * <2.0>

slow main() -> i32:
  table: [6]f32 := [10.0, 11.0, 12.0, 13.0, 14.0, 15.0]
  places: [4]i32 := [5, 0, 3, 3]
  out: [4]f32 := [0.0; 4]
  lookup(table, places, out)
  return i32(out[0] + out[1] + out[2] + out[3])
```

The checked gather traps unless every active index `i` satisfies
`0 <= i < count`, and it checks all the lanes before the first load:

<!-- rake-check: trap "gather index 6 outside 6 elements" -->
```rake
run lookup(table: []f32, places: []i32, out: mut []f32):
  out[<0>] <- table[places[<0>]]

slow main() -> i32:
  table: [6]f32 := [10.0, 11.0, 12.0, 13.0, 14.0, 15.0]
  places: [4]i32 := [5, 0, 3, 6]
  out: [4]f32 := [0.0; 4]
  lookup(table, places, out)
  return 0
```

WebAssembly has no gather instruction. On `wasm-simd128` the check is one
`i32x4.all_true` of two lane comparisons joined by `v128.and`, and the gather
is four `i32x4.extract_lane`, each forming an address, and four
`v128.load32_lane` into a zeroed rack. The sequence is the same for every
gather, with no loop and no branch.

In a stack run's tail, a switch on the uniform remainder checks and loads
only the active lanes, issuing one, two or three lane loads, and the inactive
lanes are zero. A gather in a stack run needs a 32-bit domain, so that its
lanes are the run's. A gather can't appear in a conditional's branches, as
[control flow](05_control_flow.md#conditional-expressions) explains, and it
isn't allowed in a fused binding, because it reads memory.

## Scatter

A store's index is uniform, so a run has no scatter, and `wasm-simd128`
rejects a store indexed by a rack:

<!-- rake-check: reject "wasm-simd128 has no scatter: a store takes a uniform index" -->
```rake
run spread(x: []f32, places: []i32, out: mut []f32):
  out[places[<0>]] <- x[<0>]
```

Rake rules out hidden scalar loops, so it won't store the lanes one at a
time. The rest of this section is a design for profiles with a scatter
instruction.

A scatter would write one element for each active lane through a writable
view and produce no value. The checked scatter would check, before its first
store, that every active index is in bounds and that no two active lanes have
the same index, and trap otherwise, leaving memory unchanged. The unchecked
scatter would require both. Two active lanes with one destination have no
first-wins or last-wins meaning, because unique destinations let a native
scatter instruction store its lanes in any order. A scatter would be excluded
from fused regions, and allowed under a mask only where the backend can
suppress every inactive store.

## Compression and expansion

This section is a design. Rake has no syntax for these operations yet.

Compression would move a rack's selected lanes to its low lanes, in order.
For a rack `values` and a mask `selected` with `K` true lanes, where
`source(j)` is the lane of the `j`th true lane counting from lane 0:

```text
result[j] = values[source(j)]    for 0 <= j < K
result[j] = +0.0                 for K <= j < lanes
```

Expansion would do the reverse with a passthrough rack. With `rank(i)` the
number of true lanes below lane `i`:

```text
result[i] = values[rank(i)]    where selected[i]
result[i] = passthrough[i]     elsewhere
```

Both would copy bits exactly, NaN payloads and negative zero included, and
neither would touch memory. An all-false mask would compress to all positive
zeros, and an all-true mask would return the input.

## Planned AVX2 gather

This section is a design. The x86 backend has no runs, so it has no gather.

An AVX2 gather of 32-bit elements would use `vgatherdps` with scale four and
the access's mask as its mask operand. The instruction clears its mask
register, so the backend would copy a still-live mask first. A checked
gather would add the bounds check before it. AVX2 has no scatter instruction,
so `x86-avx2` would reject scatter. Compression and expansion could use a
mask's bits, a table of permutations and `vpermps`.
