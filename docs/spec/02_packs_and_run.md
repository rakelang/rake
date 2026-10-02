# Packs and runs

A run is vector code over memory. It traverses columnar data a rack at a
time, loops over views, and writes its results to memory. Runs are
implemented for `wasm-simd128`. The x86 and AArch64 backends reject them, and
the [x86-64 boundary](#planned-x86-64-boundary) at the end of this page is a
design.

A run may enter scalar code explicitly with a [slow block](08_slow_tier.md#slow-blocks).
It returns to vector mode at the closing brace. The block can't capture racks
or a traversal chunk, and it never scalarises the surrounding rack work.

## Stacks and packs

A `stack` declares the columns of structure-of-arrays storage, grouped by
stored type. A `pack` of that stack is the columns themselves, supplied by
the caller with a record count:

<!-- rake-check: verify wasm-simd128 -->
```rake
stack Samples {
  f32: value;
  u8: quality;
}

run scale_values(input: pack Samples, <count: i64>, <scale: f32>) -> f32:
  for chunk in input using f32s up to <count>:
    let quality = to_f32(bitcast(i32s, widen(chunk.quality)))
    yield chunk.value * <scale> + quality
```

The stack holds no data and no size. Grouping by type puts the dense columns
together: here one `f32` column, then one byte column. The stored type is a
scalar, as in `u8`. The plural rack types, as in `f32s`, appear where code
computes on registers.

## Traversals

`for chunk in input using f32s up to <count>:` visits the first `count`
records of `input`, one rack of records at a time: four at once for `f32s` on
`wasm-simd128`. `using` names the compute domain. `chunk.value` is the rack of
the current records' `value` column, loaded once for the chunk.

A traversal of a run declared `-> f32` ends each chunk with `yield`, and the
yielded rack's lanes go to the run's output column of `f32`. A traversal in a
run without a result type stores into columns of a `mut pack` instead, as
`out.sum <- row.a + row.b`, or accumulates into rack locations.

A column whose stored element is as wide as the domain's lanes is a rack
directly: in an `f32s` traversal, an `f32` column is `f32s` and a `u32` column
is `u32s`. A narrower column has no rack value until `widen` converts it, and
the compiler rejects any other use of it, so a byte column can't turn into a
hidden scalar loop. `widen` preserves the value, extending by the stored
type's sign:

| Stored column | 32-bit domains (`f32s`, `i32s`, `u32s`) | 64-bit domains (`i64s`, `u64s`) |
| --- | --- | --- |
| `u8`, `u16` | `u32s` | not implemented |
| `i8`, `i16` | `i32s` | not implemented |
| `u32` | the column itself | `u64s` |
| `i32` | the column itself | `i64s` |

A column wider than the domain's lanes is rejected. A traversal using `u8s`
reads sixteen byte records at once, and a `u8` column is its rack directly.

## Count and tail

The count is a uniform `i64`. A count of zero or less reads nothing. A count
that isn't a multiple of the lane count ends with a tail chunk whose mask is
`lane < count mod lanes`. Its loads and stores are lane-sized, so they never
touch an element past the count. In the tail, a column's inactive lanes hold
zero, so a shuffle that moves one into an active lane reads zero. Rack
expressions run under the tail's mask, and a mutable location updates only
its active lanes.

## General runs

A run's parameters are packs (`pack S`, or `mut pack S` to write its columns),
views (`[]T`, or `mut []T` to write), uniform scalars (`<name: T>`) and racks
(`x: f32s`), which only a C caller can pass. Its body uses these forms:

| Form | Meaning |
| --- | --- |
| `let x = e`, `\| x <\| e` | a rack or mask, typed as in a crunch |
| `let <x: T> = e` | a uniform: arithmetic of uniforms, a reduction, `extract` or `bitmask` |
| `x := e`, `x <- e` | a mutable rack location, carried across iterations |
| `acc: [4]i32s := <0>`, `acc[<k>] <- e` | an array of rack locations, indexed by constants |
| `view[<i>]` | the rack of consecutive elements starting at element `i` |
| `<view[i]>` | one element, as a uniform |
| `view[indices]` | a gather by an `i32s` rack of indices, as [memory operations](07_memory_operations.md#gather) define |
| `view[<i>] <- e` | a rack store at a uniform index |
| `for <i: T> from <a> up to <b> by <s>:` | a counted loop with a uniform index |
| `repeat <i: T> from <a> up to <b>:` | a loop with constant bounds |
| `if <c>:` … `else:` | a branch on a uniform condition |
| `for chunk in p using D up to <n>:` | a traversal |

Every view access is checked, and a rack access traps unless all its
elements are in bounds. `view[unchecked <i>]` drops the check. A store's index
is uniform, so a run has no scatter.

Rack expressions in a run mean what they mean in a crunch. A crunch or rake
called from a run is inlined, and its tines combine with any mask around the
call. `repeat` is unrolled while its trips times its body's statements stay
within 4096 and otherwise stays a loop, which bounds code size and compile
time. A rack location or rack array stays in registers across a loop.

<!-- rake-check: run 14 -->
```rake
run running_sum(x: []f32, out: mut []f32, <n: i32>):
  total := <0.0>
  for <i: i32> from <0> up to <n> by <4>:
    total <- total + x[<i>]
    out[<i>] <- total

slow main() -> i32:
  values: [8]f32 := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
  sums: [8]f32 := [0.0; 8]
  running_sum(values, sums, <8>)
  return i32(sums[4] + sums[5])
```

A traversal may contain another traversal of the same lane count, such as a
pass over a second pack for each chunk of the first. The inner traversal reads
only its own chunk's columns, so values from the outer chunk are bound with
`let` before it. It can't yield or store. It accumulates into locations, and
the outer traversal stores them. In the outer tail both masks apply, and
because both cover a prefix of the lanes, the inner tail's mask is the
shorter one.

A run can't loop with `while`, `break` or `continue`, call slow code, call C,
or read module state.

## Addressing

In each counted loop, Rake forms addresses itself. Accesses whose index is
affine in the loop index share one strength-reduced pointer for each view,
stride and invariant base, and the constant term of the index becomes the
instruction's offset. A uniform whose only uses are such accesses isn't
computed again each iteration. Bounds are checked once, before the loop,
for its first and last iterations: an affine index lies between its values
there, so those two checks cover every iteration.

Clang folds a constant offset into a WebAssembly load only when it can see
that the address doesn't wrap, and loop strength reduction hides that. The
default `--wasm-addressing barrier` gives each pointer an empty `asm`
statement with one `i32` operand at the top of every iteration. That keeps
the pointer opaque, so the offsets fold. `--wasm-addressing plain` emits the
intrinsics alone. The barriers name only scalar pointers, because a `v128`
operand to `asm` crashes some wasm32 builds of clang.

## wasm32 boundary

On `wasm-simd128` a run is an external C function that is never inlined,
named as in the source and returning `void`. Its C parameters follow the
source order:

| Rake parameter | C parameters |
| --- | --- |
| `p: pack S` | `const struct rake_pack_S_v1 *p` |
| `p: mut pack S` | `const struct rake_mut_pack_S_v1 *p` |
| `x: []T` | `const T *p_x, int32_t p_x_count` |
| `x: mut []T` | `T *p_x, int32_t p_x_count` |
| `<n: T>` | the C type of `T` |
| `x: f32s`, or another rack | `v128_t x` |
| the output of a run declared `-> T` | `T *p_result`, last |

A pack descriptor has one pointer for each column in declaration order,
`const T *` in `rake_pack_S_v1` and `T *` in `rake_mut_pack_S_v1`. The runs in
`test/abi/runs.rk` have these declarations:

```c
struct rake_pack_Samples_v1 { const float *value; const uint8_t *quality; };
void scale_values(const struct rake_pack_Samples_v1 *input, int64_t count, float scale, float *result);
void offset(const float *x, int32_t x_count, float *out, int32_t out_count, v128_t shift, int32_t n);
```

The caller owns all the storage, and a run never allocates, keeps or frees
it. When a traversal's count is zero or less, the descriptor, its columns
and the output may be null. A positive count is at most 2^32 - 1, because a
wasm32 traversal counts in 32 bits. Every column the traversal reads, the
output, and every column of a pack it stores into must hold at least `count`
elements. Slow code calling a run checks these and traps, and a C caller must
meet them. A run reads each column pointer from its descriptor once.

Read-only inputs may alias each other. An output either overlaps no input or
starts at exactly the same address as one input column, for an in-place
update. Each chunk loads all the columns it reads before storing its result,
so an in-place update sees the chunk's inputs as they were. The C declaration
has no `restrict`, because that exact aliasing is allowed.

From slow code, a run is a statement. A run declared `-> T` takes its output
view as one more argument after its parameters, as `weigh(..., weighed)` does
in [the slow tier](08_slow_tier.md).

`test/abi_test.sh` calls the runs from C for every count from 0 to 20, with
misaligned arrays, sentinels after the output, null pointers for empty
counts, in-place output, storage ending at the last page of linear memory,
mutable packs and rack parameters, in both addressing modes.

## Planned x86-64 boundary

This section is a design. No backend implements it, and the x86 and AArch64
backends reject runs.

On Linux x86-64 with AVX2, a run would follow System V. Pack descriptor
pointers, `i32` and `i64` arguments would take `rdi`, `rsi`, `rdx`, `rcx`,
`r8` and `r9` in source order, uniform `f32` arguments `xmm0` to `xmm7`, and
the output pointer the next integer register. A run needing more registers
than these would be rejected, since nothing passes on the stack. It would
return `void` under its source name, keep no stack frame, call nothing, and
execute `vzeroupper` before returning:

```c
void scale_values(
    const struct rake_pack_Samples_v1 *input, /* rdi */
    int64_t count,                            /* rsi */
    float scale,                              /* xmm0 */
    float *result                             /* rdx */
);
```

Full chunks would use unaligned vector loads and stores, so callers need only
natural alignment. The tail would use masked loads and stores, and the
operands of inactive lanes would be replaced by benign values before any
operation that can raise a floating-point exception, as in a `through` block.
Before the backend accepts runs, its tests would compare it with the
interpreter over empty, full and tail counts, check descriptor layouts,
widening, misaligned arrays, output sentinels, in-place output, arrays ending
at a guard page and inactive lanes raising no exceptions, and verify that the
object has no calls, spills, stack frame or scalar cleanup loop.
