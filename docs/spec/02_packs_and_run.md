# Packs, stacks and runs

A run applies rakes and scratches to whole stacks. The source chooses the
columns and the calculations, and the compiler splits the columns into racks,
handles the final partial rack, fuses the calculations and stores the results.
Stack runs compile for SSE2, AVX2, AVX-512, NEON and `wasm-simd128`, while
[general runs](#general-runs), which index views with counted loops, compile
for `wasm-simd128`.

## Packs and stacks

A `pack` defines one record. A `stack` holds many of those records in
structure-of-arrays storage: one contiguous column for each field, and a
count of records.

```text
PACK: one record          { posx, posy, velx, vely, kill }

STACK: count records, one column per field
  posx: [p0 p1 p2 p3] [p4 p5 p6 p7] [p8 ...
  velx: [v0 v1 v2 v3] [v4 v5 v6 v7] [v8 ...
  kill: [k0 k1 k2 k3] [k4 k5 k6 k7] [k8 ...
         └── one rack: the target's lane count of records ──┘
```

Each column's stored type is scalar, such as `f32` or `u8`, and the run works
on its racks, whose plural types such as `f32s` have the target's lane count.

## Stack runs

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Particle {
  f32: posx, posy, velx, vely;
  u8: kill;
}

scratch step(position: f32s, velocity: f32s, <dt: f32>) -> f32s:
  position + velocity * <dt>

run advance(particles: stack Particle, <dt: f32>) -> stack Particle:
  let kill = widen(particles.kill)
  tine #alive means kill = <0>
  particles with {
    posx: step(particles.posx, particles.velx, <dt>),
    posy: step(particles.posy, particles.vely, <dt>)
  } where #alive
```

Inside a stack run, `particles.posx` is the whole `posx` column, and an
expression over columns applies to every record. `step` takes racks, so the
compiler calls it once per rack of records. The run's body has these forms,
in source order:

| Form | Meaning |
| --- | --- |
| `let x = e`, `\| x <\| e` | a value for every record, typed as in a scratch |
| `let <x: T> = e` | a uniform: arithmetic of uniforms, `bool` only on native targets |
| `tine #name means p` | a predicate on every record, as in a rake |
| `x := e`, `x <- e`, `repeat <i: T> from <a> up to <b>:` | rack locations and unrolled loops, as in a [general run](#general-runs) |
| `s with { field: e, ... }` | the run's result: `s` with those fields replaced |
| `s with { ... } where p` | replace them only in the records where `p` holds |
| `compact s where p` | keep only the records where `p` holds |
| `compact s with { ... } where p` | replace the fields, then keep those records |

The last statement specifies one stack parameter, `s`, whose pack is the
declared result, and omitted fields keep their values. A replacement has the
field's working rack type, so an `f32` field takes `f32s`. Replacing a byte or
16-bit field is work in progress. `p` can be any predicate accepted by a
rake's sweep, such as a local tine, `#alive(kill)` or
`(#alive and #near) gaps`.

### Masking and compaction

`where` masks: the run computes the new fields for every record, and records
outside the predicate keep their old values. The count doesn't change, so
every later operation still visits the unselected records.

`compact` removes: the selected records move to the front of each column in
their original order, and the count becomes the number selected. A compaction
rewrites every column, including unreplaced ones.

Compaction costs roughly the same per record, while masking carries
unselected records through all the work that follows. The faster choice
depends on how many records survive, and the compiler can't know that, so the
source chooses. Every target compacts with vector instructions, such as
`vcompressps` on AVX-512 and `i8x16.swizzle` by a table of selection bits on
WebAssembly, and the [kernel report](#kernel-report) shows each build's
method. Compacting a run whose widest column has 8 bits is work in progress
on WebAssembly.

### Several stacks

A run can read stacks other than its result, with the same count as the
result's stack:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Samples {
  f32: value;
}
pack Roots {
  f32: root;
}

tine #valid(values: f32s) means values >= <0.0>

rake safe_root(values: f32s) -> f32s:
  through #valid(values) into rooted:
    sqrt(values)
  sweep:
    | #valid(values) => rooted
    | #valid(values) gaps => <0.0>

run roots(input: stack Samples, output: stack Roots) -> stack Roots:
  output with { root: safe_root(input.value) }
```

The result's stack, `output`, moves into the run, and every other stack
parameter is read only. A call traps before the run starts if the counts
differ.

## Moves and copies

A stack is a value, and calling a run moves the result's stack into it. The
call returns the updated stack, so the source reads as a function from stack to
stack while the compiler updates the columns in place:

<!-- rake-check: run 17 -->
```rake
pack Samples {
  f32: value;
}

run doubled(samples: stack Samples) -> stack Samples:
  samples with { value: samples.value * <2.0> }

slow main() -> i32:
  values: [4]f32 := [1.0, 2.0, 3.0, 1.5]
  samples := stack Samples { value: values }
  samples <- doubled(samples)
  kept := copy(samples)
  twice := doubled(kept)
  return i32(twice.value[0] + samples.value[3] + twice.value[3]) + i32(count(samples))
```

After `doubled(samples)`, reading `samples` is a compile error until it is
assigned again, as `samples <- doubled(samples)` does. A stack moved in one
branch of an `if` counts as moved after it, and a stack moved inside a loop
needs to be assigned again before the next iteration.

`copy(samples)` creates a stack with its own columns and the same records,
and leaves `samples` usable. The copy's columns come from the slow function's
frame arena, so they last until that function returns, and a copy larger than
the arena's `RAKE_FRAME_BYTES` (4 MiB unless defined) traps. A copy is the
only way to keep a stack after passing it to a run, because the compiler
never copies one implicitly.

Moving gives each run exclusive use of its result's columns, so its stores
can't change memory read through its other arguments, except through exactly
the same column. A call traps before the run starts if the result's columns
overlap another argument's memory in any other way.

A stack built from arrays, as `stack Samples { value: values }`, uses those
arrays as its columns, so they hold the new values after a run updates the
stack in place. Its count is their length, and a stack literal traps if its
columns have different lengths. A compaction leaves the records past the new
count unspecified. In slow code, `s.field` is a column as a view of `count(s)`
elements, and `count(s)` is the stack's count as an `i64`.

## Columns and domains

A run computes in one domain: the widest element type among its columns. Every rack in the run has that domain's lane count, so a run over
`f32` and `u8` columns visits four records at a time on SSE2 and NEON, eight on
AVX2 and sixteen on AVX-512.

A column as wide as the domain is a rack directly: in a 32-bit domain an `f32`
column is `f32s` and a `u32` column is `u32s`. A narrower column stays compact
in memory and has no rack value until `widen` converts it, so a byte column
can't turn into a hidden scalar loop. `widen` preserves the value, extending
by the stored type's sign:

| Stored column | 32-bit domains | 64-bit domains |
| --- | --- | --- |
| `u8`, `u16` | `u32s` | WIP* |
| `i8`, `i16` | `i32s` | WIP* |
| `u32` | the column itself | `u64s` |
| `i32` | the column itself | `i64s` |

*WIP: work in progress. Native targets implement 32-bit domains. WebAssembly
implements the domains above.*

The unsigned fields of this pack fit in a signed 32-bit lane, so their
bitcasts preserve their values:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack CompactReadings {
  i8: adjustment;
  i16: offset;
  u8: quality;
  u16: weight;
  i32: total;
}

run combine_readings(input: stack CompactReadings) -> stack CompactReadings:
  let adjustment = widen(input.adjustment)
  let offset = widen(input.offset)
  let quality = bitcast(i32s, widen(input.quality))
  let weight = bitcast(i32s, widen(input.weight))
  input with { total: ((adjustment + offset) + quality) + weight }
```

In general `bitcast` changes only the interpretation of bits, so an unsigned
32-bit value above 2³¹−1 becomes a negative signed value. `to_f32` converts
`i32s` or `u32s` to floats. `to_i32` and `to_u32` round floats to integers with
ties to even and saturation: NaNs become zero, values beyond the range saturate
to its endpoints, and for `to_u32` negative values become zero.

## Count and tail

A stack of zero records runs nothing. A count that isn't a multiple of the lane
count ends with a tail rack whose mask is `lane < count mod lanes`. Its memory
transfers touch only existing records, using lane-sized loads and stores on
WebAssembly and guarded or masked transfers on the native targets. In the tail
a column's inactive lanes hold zero. Expressions run under the tail's mask,
and inactive operands are made benign before exception-capable arithmetic.

Each rack loads all its input columns before storing its results, so a
replacement sees the record's values as they were.

## Kernel report

A successful build that emits code ends with a report on standard error. It
lists each run with the compiler's decisions: the domain and lanes, the
columns read and written, whether the result is updated in place, the
selection (every record, masked or compacted) and its method, and the tail's
memory transfers. For example, an AVX2 build of the first example reports:

```text
rakec: kernel report for x86-avx2
  run advance: 32-bit domain, 8 lanes
    reads kill, posx, velx, posy, vely; replaces posx, posy in place
    selection: masked by #alive
    tail: vmaskmovps for 32-bit columns, guarded lane transfers for compact columns
```

`--no-report` omits it.

## General runs

A general run indexes views with counted loops. Its parameters are views
(`[]T`, or `mut []T` to write), uniform scalars (`<name: T>`) and, from C
callers only, racks (`x: f32s`). Its body uses these forms:

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

A stack run can also take views, for gathers such as `table[indices]` on
WebAssembly.

Every view access is checked, and a rack access traps unless all its
elements are in bounds. `view[unchecked <i>]` drops the check. A store's index
is uniform, so a run has no scatter.

Rack expressions in a run mean what they mean in a scratch. A scratch or rake
called from a run is inlined, and its tines combine with any mask around the
call. `repeat` is unrolled while its trips times its body's statements stay
within 4096, and otherwise stays a loop. A rack location or rack array stays
in registers across a loop.

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

A run may enter scalar code explicitly with a [slow block](08_slow_tier.md#slow-blocks),
which can't capture racks or scalarise the rack work around it. Outside slow
blocks, a run can't loop with `while`, `break` or `continue`, call slow code,
call C, or read module state.

## Addressing

In each counted loop, accesses whose index is affine in the loop index share
one strength-reduced pointer for each view, stride and invariant base, and the
index's constant term becomes the instruction's offset. A uniform used only in
such accesses isn't recomputed each iteration. Bounds are checked once, before
the loop, for the first and last iterations, which together cover every
iteration of an affine index.

Clang folds a constant offset into a WebAssembly load only when it can see
that the address doesn't wrap, and loop strength reduction hides that. The
default `--wasm-addressing barrier` keeps each pointer opaque with an empty
`asm` statement at the top of every iteration, so the offsets fold.
`--wasm-addressing plain` omits these barriers.

## The C boundary

A run is an external C function named as in the source and returning `void`.
Its C parameters follow the source order:

| Rake parameter | C parameters |
| --- | --- |
| the result's stack, `s: stack S` | `struct rake_stack_S_v2 *s` |
| another stack, `s: stack S` | `const struct rake_stack_S_v2 *s` |
| `x: []T` | `const T *p_x, int32_t p_x_count` |
| `x: mut []T` | `T *p_x, int32_t p_x_count` |
| `<n: T>` | the C type of `T` |
| `x: f32s`, or another rack | `v128_t x` |

A stack descriptor holds the count, then one pointer for each column in
declaration order. The runs in this page's first two examples have these
declarations:

```c
struct rake_stack_Particle_v2 {
    int64_t count;
    float *posx; float *posy; float *velx; float *vely;
    uint8_t *kill;
};
void advance(struct rake_stack_Particle_v2 *particles, float dt);

struct rake_stack_Samples_v2 { int64_t count; float *value; };
struct rake_stack_Roots_v2 { int64_t count; float *root; };
void roots(const struct rake_stack_Samples_v2 *input,
    struct rake_stack_Roots_v2 *output);
```

The caller owns all the storage, and a run never allocates, keeps or frees
it. A run reads each column pointer once and writes the result's count, which
changes only in a compaction. With a count of zero or less, the columns may be
null. Every column holds at least `count` elements, and every stack in a call
has the same count. Slow code calling a run checks these conditions and traps,
and a C caller needs to satisfy them too. On WebAssembly a positive count is at
most 2^32 - 1.

The result's columns may share storage with another argument only when an
element of one starts at exactly the same address as the corresponding element
of the other, for an in-place update. Otherwise their storage needs to be
disjoint. The C declaration has no `restrict`, because that exact aliasing is
allowed.

On x86-64 Linux a stack run follows System V, and on AArch64 Linux it follows
AAPCS64. Stack descriptors take integer argument registers in source order, and
`f32` uniforms take the vector argument registers, `xmm0` to `xmm7` or `s0` to
`s7`. `i32`, `u32` and `bool` uniforms advance the integer register counter.
The run never spills an argument or accepts stack arguments, so a run with more
integer arguments than registers (six on x86, eight on AArch64) fails
compilation, as does one with more than eight uniforms. An `i32` uniform's
unspecified upper register bits can't change its value, and a `bool` keeps only
its value bit. The run calls nothing, and touches the stack only to save x86's
callee-saved registers when it has many columns. The AVX profiles execute
`vzeroupper` before returning.

Native stack runs keep their input columns in vector registers: up to six on
SSE2, seven on AVX2 and NEON, and twenty on AVX-512. Views, reductions, scans,
extraction, insertion and shuffles in native stack runs are work in progress
and fail compilation.

## Verification

The final-object verifier compares each native run with its separately
assembled selection, including branch offsets, memory operands and embedded
literals, and rejects any difference or unresolved relocation. On
WebAssembly, every SIMD instruction in a run needs to come from instruction
selection for its source operations.
