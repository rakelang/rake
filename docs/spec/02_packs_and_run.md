# Packs, stacks and runs

A run is vector code over memory. It traverses columnar data a rack at a
time, loops over views, and writes its results to memory. Runs are
implemented for `wasm-simd128`. The unreleased compiler also implements the
[SSE2, AVX2, AVX-512 and NEON stream subset](#native-cpu-streams).
General native runs remain work in progress.

A run may enter scalar code explicitly with a [slow block](08_slow_tier.md#slow-blocks).
It returns to vector mode at the closing brace. The block can't capture racks
or a traversal chunk, and it never scalarises the surrounding rack work.

## Packs and stacks

A `pack` defines one record, with its fields stored together. A `stack` is
a collection of those records transposed into structure-of-arrays storage:
one contiguous column for each field. Remember the hierarchy as "define our
pack, then rack 'em and stack 'em". A `run` traverses the stack, splitting its
unsized columns into racks for the rakes and scratches in its body:

<!-- rake-check: verify wasm-simd128 -->
```rake
pack Samples {
  f32: value;
  u8: quality;
}

run scale_values(input: stack Samples, <count: i64>, <scale: f32>) -> f32:
  for chunk in input using f32s up to <count>:
    let quality = to_f32(bitcast(i32s, widen(chunk.quality)))
    yield chunk.value * <scale> + quality
```

The declaration above describes one `Samples` record: an `f32` value and a
`u8` quality. `Samples { value: 1.0, quality: 2 }` constructs one pack.
`stack Samples { value: values, quality: qualities }` borrows whole columns
from the caller's arrays or views. Each column's stored type is scalar. Its
working rack has a plural type such as `f32s`, whose lane count follows the
target's register width. A column can have a million entries without making
its working rack a million lanes wide.

## Traversals

`for chunk in input using f32s up to <count>:` visits the first `count`
records of `input`, one rack of records at a time: four at once for `f32s` on
`wasm-simd128`. `using` specifies the compute domain. `chunk.value` is the rack of
the current records' `value` column, loaded once for the chunk.

A traversal of a run declared `-> f32` ends each chunk with `yield`, and the
yielded rack's lanes go to the run's output column of `f32`. A traversal in a
run without a result type stores into columns of a `mut stack` instead, as
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

The count is a uniform integer. A count of zero or less reads nothing. A count
that isn't a multiple of the lane count ends with a tail chunk whose mask is
`lane < count mod lanes`. Its transfers touch only active elements: lane-sized
loads and stores on WebAssembly, count-guarded lane transfers on SSE2 and
NEON, and masked vector transfers on AVX2 and AVX-512. These transfers avoid
elements past the count. In the tail, a column's inactive lanes hold
zero, so a shuffle that moves one into an active lane reads zero. Rack
expressions run under the tail's mask, and a mutable location updates only
its active lanes.

## General runs

A run's parameters are stacks (`stack S`, or `mut stack S` to write its columns),
views (`[]T`, or `mut []T` to write), uniform scalars (`<name: T>`) and racks
(`x: f32s`), which only a C caller can pass. Its body uses these forms:

| Form | Meaning |
| --- | --- |
| `let x = e`, `\| x <\| e` | a rack or mask, typed as in a scratch |
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

Rack expressions in a run mean what they mean in a scratch. A scratch or rake
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
pass over a second stack for each chunk of the first. The inner traversal reads
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
the pointer opaque, so the offsets fold. `--wasm-addressing plain` omits
these pointer barriers. Both modes keep a partial store's remainder opaque
with an empty scalar `asm`, so clang retains the rack arithmetic before
selecting its active lane stores. These barriers take scalar operands,
because a `v128` operand to `asm` crashes some wasm32 builds of clang.

## wasm32 boundary

On `wasm-simd128` a run is an external C function that is never inlined,
named as in the source and returning `void`. Its C parameters follow the
source order:

| Rake parameter | C parameters |
| --- | --- |
| `p: stack S` | `const struct rake_stack_S_v1 *p` |
| `p: mut stack S` | `const struct rake_mut_stack_S_v1 *p` |
| `x: []T` | `const T *p_x, int32_t p_x_count` |
| `x: mut []T` | `T *p_x, int32_t p_x_count` |
| `<n: T>` | the C type of `T` |
| `x: f32s`, or another rack | `v128_t x` |
| the output of a run declared `-> T` | `T *p_result`, last |

A stack descriptor has one pointer for each column in declaration order,
`const T *` in `rake_stack_S_v1` and `T *` in `rake_mut_stack_S_v1`. The runs in
`test/abi/runs.rk` have these declarations:

```c
struct rake_stack_Samples_v1 { const float *value; const uint8_t *quality; };
void scale_values(const struct rake_stack_Samples_v1 *input, int64_t count, float scale, float *result);
void offset(const float *x, int32_t x_count, float *out, int32_t out_count, v128_t shift, int32_t n);
```

The caller owns all the storage, and a run never allocates, keeps or frees
it. When a traversal's count is zero or less, the descriptor, its columns
and the output may be null. A positive count is at most 2^32 - 1, because a
wasm32 traversal counts in 32 bits. Every column the traversal reads, the
output, and every column of a stack it stores into must hold at least `count`
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
mutable stacks and rack parameters, in both addressing modes.

## Native CPU streams

The unreleased development compiler supports an input stack and an `i32` or
`i64` count, optionally followed by a mutable destination stack, then up to eight
uniform `f32`, `i32`, `u32` or `bool` arguments within the C register limits.
One traversal using `f32s`, `i32s` or `u32s` yields a stream of the matching
scalar type from a read-only stack, or updates one `f32`, `i32` or `u32`
column in its mutable input or destination. Its body loads one to four
columns of these types and combines immutable lane expressions, including
calls to rakes and scratches. A float mask can select integer values, and an
integer mask can select floats: each column keeps its own element type while
sharing the traversal's lane count. General loops, multiple column stores,
widening, other scalar parameter types, reductions, scans, extraction, insertion and shuffles
remain work in progress and fail compilation. Unused stored columns may have
other scalar types.

On Linux x86-64 the stream follows System V: the descriptor is in `rdi`, the
count in `rsi`, and, when there are no integer uniforms, the output in `rdx`.
It returns `void` under its source
identifier, uses no stack frame and calls nothing. The AVX profiles execute
`vzeroupper` before returning. On AArch64 it follows AAPCS64, with the
descriptor in `x0`, count in `x1` and, without integer uniforms, output in `x2`:

```c
void roots(
    const struct rake_stack_Samples_v1 *input, /* rdi / x0 */
    int64_t count,                            /* rsi / x1 */
    float *result                             /* rdx / x2 */
);
```

A scale or threshold can vary between calls without changing the kernel:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Values {
  f32: value;
}

run scaled_values(input: stack Values, <count: i64>, <scale: f32>, <bias: f32>) -> f32:
  for row in input using f32s up to <count>:
    yield row.value * <scale> + <bias>
```

The C arguments retain source order, with the output last:

```c
void scaled_values(const struct rake_stack_Values_v1 *input,
    int64_t count, float scale, float bias, float *result);
```

An integer column follows the same traversal. This run adds an offset to
each signed magnitude using the [wrapping integer arithmetic](01_primitives_operations_and_targets.md#integer-racks):

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack IntegerValues {
  i32: value;
}

run signed_magnitudes(input: stack IntegerValues, <count: i32>, <offset: i32>) -> i32:
  for row in input using i32s up to <count>:
    yield abs(row.value) + <offset>
```

`using i32s` visits four records on SSE2 or NEON, eight on AVX2 and sixteen
on AVX-512. Its C descriptor and output use `int32_t`, preserving every lane's
bits through the boundary:

```c
struct rake_stack_IntegerValues_v1 { const int32_t *value; };
void signed_magnitudes(const struct rake_stack_IntegerValues_v1 *input,
    int32_t count, int32_t offset, int32_t *result);
```

The floating-point arguments arrive in `xmm0` through `xmm7` on x86, or
`s0` through `s7` on AArch64. Rake preserves them in caller-clobbered registers
before loading the first rack, and the allocator keeps them live through
every iteration. Register pressure still causes a compilation error. The
stream never spills an argument to memory or accepts stack arguments.

Integer and Boolean uniforms advance the integer argument counter separately
from floats. The descriptor and count consume two slots. A separate mutable
destination consumes another, while a stream's output pointer comes after
the uniforms. Consequently an x86 stream can take three integer or Boolean
uniforms, an in-place update four, and an AArch64 stream five or an in-place
update six. The eight-uniform limit also applies to mixed types. Compilation
fails when either register counter or the vector allocator runs out of space.
Booleans retain only their value bit, so unspecified upper C argument bits
cannot affect a choice. Uniform comparisons and Boolean conditions use the
same vector masks in full racks and tails.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Values {
  f32: value;
}

run choose_scale(input: stack Values, <count: i32>, <mode: i32>, <scale: f32>, <enabled: bool>) -> f32:
  for row in input using f32s up to <count>:
    let value = row.value
    yield if <enabled> then (if <mode> < <0> then value * <scale> else value) else <0.0>
```

Its C declaration preserves that order. On x86, `mode` is in `edx`, `scale`
in `xmm0`, `enabled` in `ecx` and the output pointer in `r8`. On AArch64 the
corresponding slots are `w2`, `s0`, `w3` and `x4`:

```c
void choose_scale(const struct rake_stack_Values_v1 *input, int32_t count,
    int32_t mode, float scale, bool enabled, float *result);
```

To update a column in place, make the input stack mutable and finish the
traversal with a column assignment. This run has no stream result or separate
output argument:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Values {
  f32: value;
}

run shift_values(input: mut stack Values, <count: i64>, <bias: f32>):
  for row in input using f32s up to <count>:
    input.value <- row.value + <bias>
```

```c
struct rake_mut_stack_Values_v1 { float *value; };
void shift_values(const struct rake_mut_stack_Values_v1 *input,
    int64_t count, float bias);
```

The descriptor stays unchanged. Rake loads the read columns before storing
each chunk's result, and writes only the selected column's active elements.
A column update may also write an input column that the expression never
reads. A C caller may leave the stack's unused pointers null.

A separate destination stack can have a different record layout. Its
descriptor follows the count, before the uniforms:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Values {
  f32: value;
}
pack Roots {
  u8: tag;
  f32: root;
}

run copy_shift(input: stack Values, <count: i32>, output: mut stack Roots, <bias: f32>):
  for row in input using f32s up to <count>:
    output.root <- row.value + <bias>
```

```c
struct rake_stack_Values_v1 { const float *value; };
struct rake_mut_stack_Roots_v1 { uint8_t *tag; float *root; };
void copy_shift(const struct rake_stack_Values_v1 *input, int32_t count,
    const struct rake_mut_stack_Roots_v1 *output, float bias);
```

Both descriptors stay unchanged. The selected destination pointer is loaded
using its own record layout. The C boundary passes this descriptor in `rdx`
or `x2`, where a stream passes its output pointer. Rake callers check that
both stacks' columns hold the count. Independent C callers supply valid
storage for the read and written columns, and may leave unused pointers null.

The compiler owns the loop and advances by four elements on SSE2 and NEON,
eight on AVX2 or sixteen on AVX-512F. Full racks use unaligned vector loads
and stores. AVX2 touches only active elements in the last rack through
`vmaskmovps`. AVX-512F uses `vmovups` with the `k2` memory mask, independently
of the expression selector's `k1`.

SSE2 has no fault-suppressing float load or store. For its last one to three
elements, uniform count guards select the individual memory transfers. The
compiler assembles those elements into one XMM rack, evaluates the expression
once with vector arithmetic, and stores only its active elements. There is
no scalar arithmetic cleanup loop. NEON's tail also uses uniform count
guards, loading only existing elements into an initially zeroed vector
through `ld1` lane transfers. It evaluates one masked rack and writes the
active results through `st1` lane transfers. Both keep the arithmetic
vectorised. Inactive operands are made benign before exception-capable
arithmetic on all four profiles.

The count uses `int32_t` or `int64_t` in C, matching its Rake type. An `i32`
count is sign-extended at entry before the loop or any pointer access, so
unspecified upper register bits cannot change its value. The
[System V AMD64 ABI](https://gitlab.com/x86-psABIs/x86-64-ABI/-/blob/master/x86-64-ABI/low-level-sys-info.tex)
and [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst#parameter-passing)
define those unused argument bits as unspecified. Counts of zero or less
touch no pointer, so null pointers are allowed then.
For a positive count, each read column and the output must hold that many
elements of its declared type. The same overlap rules as the wasm32 boundary apply.

The final-object verifier compares the complete traversal function with the
separately assembled selection, including branch offsets, memory operands
and embedded literals. Any difference or unresolved relocation is rejected.
`test/native_stream_test.sh` checks independent C results, exact in-place
output and guarded tails of every remainder for one to four columns. It also
checks signed and unsigned integer columns against independently computed
wrapping bits, including multiplication, absolute values, literal shifts,
unsigned clamps and mixed float/integer selection. Integer streams and
column updates exercise exact aliasing and a separately shaped destination.
C and Rake callers also check scale, bias and threshold arguments, including
a quiet-NaN threshold, and eight uniform arguments preserved across racks.
Mutable-descriptor checks cover the first and fourth columns, an unread
destination column, unchanged independent columns and null unused pointers.
Separate-destination checks use a different record layout through C and Rake
callers. C checks guard every tail and cover exact aliasing with a read column.
The C count oracle also supplies arbitrary upper bits in an `i32` argument,
including zero and negative counts, while Rake callers exercise both widths.
Each profile checks a million-element safe-root pass plus a three-element tail.
AVX-512 runs on capable hardware or through Intel SDE, and NEON
through AArch64 QEMU. The AVX2 demonstration in `demo/safe-root/run.sh`
times both optimised and explicitly scalar C builds.
