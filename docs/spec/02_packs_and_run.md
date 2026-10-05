# Packs, stacks and runs

A run applies rakes and scratches to whole stacks. The programmer names the
columns and the calculations. The compiler splits the columns into racks,
handles the final partial rack, fuses the calculations and stores the results.
Stack runs compile for SSE2, AVX2, AVX-512, NEON and `wasm-simd128`.

A run may also be a [general run](#general-runs) over views, with counted
loops that index memory a rack at a time. General runs compile for
`wasm-simd128`.

## Packs and stacks

A `pack` defines one record. A `stack` holds many of those records in
structure-of-arrays storage: one contiguous column for each field, and a
count of records. Remember the hierarchy as "define our pack, then rack 'em
and stack 'em".

```text
PACK: one record          { posx, posy, velx, vely, kill }

STACK: count records, one column per field
  posx: [p0 p1 p2 p3] [p4 p5 p6 p7] [p8 ...
  velx: [v0 v1 v2 v3] [v4 v5 v6 v7] [v8 ...
  kill: [k0 k1 k2 k3] [k4 k5 k6 k7] [k8 ...
         └── one rack: the target's lane count of records ──┘
```

Each column's stored type is scalar, such as `f32` or `u8`. The run works on
its racks, whose plural types such as `f32s` have the target's lane count. A
column can have a million entries without making its rack a million lanes
wide.

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

The result is the run's last statement. It names one stack parameter, `s`,
whose pack is the run's declared result. Fields it doesn't name keep their
values. A replacement's value has the field's working rack type, so an `f32`
field takes `f32s`. Replacing a byte or 16-bit field is work in progress.

`p` is any predicate a rake's sweep accepts: a local tine, a global tine
application such as `#alive(kill)`, or a composition such as
`(#alive and #near) gaps`.

### Masking and compaction

`where` masks. The run computes the new fields for every record, and the
records outside the predicate keep their old values. The stack's count doesn't
change, and every later operation still visits the unselected records.

`compact` removes. The selected records move to the front of each column in
their original order, and the stack's count becomes the number selected. A
compaction rewrites every column, including the ones the run doesn't replace.

Both forms mean the same thing on every target. Which one is faster depends on
the data: compaction costs roughly the same per record, while masking carries
unselected records through all the work that follows. The compiler can't know
how many records survive, so the source chooses. Each target implements
compaction with vector instructions:

| Target | Compaction |
| --- | --- |
| AVX-512 | `vcompressps` under the selection mask, then `vpmovdb` or `vpmovdw` for compact columns |
| AVX2 | `vpermps` by a permutation table indexed by the selection bits |
| NEON | `tbl` by a byte table indexed by the selection bits, then `xtn` for compact columns |
| `wasm-simd128` | `i8x16.swizzle` by a byte table indexed by the selection bits |
| SSE2 | a jump to one of 16 fixed `pshufd` permutations |

The [kernel report](#kernel-report) names the method each build used.
Compacting a run whose widest column has 8 bits is work in progress on
WebAssembly.

### Several stacks

A run can read stacks other than its result. They must have the same count as
the result's stack:

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

The result's stack, `output`, moves into the run. Every other stack parameter
is read only. A call traps before the run starts if the counts differ.

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

After `doubled(samples)`, the old value of `samples` is gone. Reading it is a
compile error until it is assigned again, as `samples <- doubled(samples)`
does. A stack moved in one branch of an `if` counts as moved after it, and a
stack moved inside a loop must be assigned again before the next iteration.

`copy(samples)` creates a stack with its own columns and the same records,
and leaves `samples` usable. The copy's columns come from the slow function's
frame arena, so they last until that function returns, and a copy larger than
the arena's `RAKE_FRAME_BYTES` (4 MiB unless defined) traps. A copy is the
only way to keep a stack after passing it to a run, and the compiler never
copies one implicitly. An implicit copy would be a slower way to write the same program.

Moving gives each run exclusive use of its result's columns, so its stores
can't change memory that its other arguments read, except through exactly the
same column. A call traps before the run starts if the result's columns
overlap another argument's memory in any other way.

A stack built from arrays, as `stack Samples { value: values }`, uses those
arrays as its columns. Its count is their length, and a stack literal traps if
its columns have different lengths. After a run updates the stack in place,
the arrays hold the new values. A compaction leaves the records past the new
count unspecified.

In slow code, `s.field` is a column as a view of `count(s)` elements, and
`count(s)` is the stack's count as an `i64`.

## Columns and domains

A run computes in one domain: the widest element type of the columns it reads
or writes. Every rack in the run has that domain's lane count, so a run over
`f32` and `u8` columns visits four records at a time on SSE2 and NEON, eight on
AVX2 and sixteen on AVX-512.

A column as wide as the domain is a rack directly: in a 32-bit domain an `f32`
column is `f32s` and a `u32` column is `u32s`. A narrower column has no rack
value until `widen` converts it, so a byte column can't turn into a hidden
scalar loop. `widen` preserves the value, extending by the stored type's sign:

| Stored column | 32-bit domains | 64-bit domains |
| --- | --- | --- |
| `u8`, `u16` | `u32s` | WIP* |
| `i8`, `i16` | `i32s` | WIP* |
| `u32` | the column itself | `u64s` |
| `i32` | the column itself | `i64s` |

*WIP: work in progress. Native targets implement 32-bit domains. WebAssembly
implements the domains above.*

The column stays compact in memory, and its pointer advances by one or two
bytes per record instead of four. The unsigned fields of this pack fit in a
signed 32-bit lane, so their bitcasts preserve their values:

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

In general `bitcast` changes only the interpretation of bits: an unsigned
32-bit value above 2³¹−1 becomes a negative signed value. `to_f32` converts
`i32s` or `u32s` to floats. `to_i32` and `to_u32` round floats to integers with
ties to even and saturation: NaNs become zero, values beyond the range saturate
to its endpoints, and for `to_u32` negative values become zero.

## Count and tail

A stack of zero records runs nothing. A count that isn't a multiple of the lane
count ends with a tail rack whose mask is `lane < count mod lanes`. Its memory
transfers touch only existing records: lane-sized loads and stores on
WebAssembly, count-guarded lane transfers on SSE2 and NEON, masked vector
transfers for 32-bit columns on AVX2 and for all columns on AVX-512, and
count-guarded transfers for compact AVX2 columns. In the tail a column's
inactive lanes hold zero. Expressions run under the tail's mask, and inactive
operands are made benign before exception-capable arithmetic.

Each rack loads every column the run reads before storing its results, so a
replacement sees the record's values as they were.

## Kernel report

A successful build that emits code ends with a report on standard error. It
lists each run with the facts the compiler used: the domain and lanes, the
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
(`[]T`, or `mut []T` to write), uniform scalars (`<name: T>`) and racks
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

A stack run can also take views, for gathers such as `table[indices]` on
WebAssembly.

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

A run may enter scalar code explicitly with a [slow block](08_slow_tier.md#slow-blocks).
It returns to vector mode at the closing brace. The block can't capture racks,
and it never scalarises the surrounding rack work. A run can't loop with
`while`, `break` or `continue`, call slow code, call C, or read module state.

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
only a compaction changes. With a count of zero or less, the columns may be
null. Every column holds at least `count` elements, and every stack in a call
has the same count. Slow code calling a run checks these and traps. A C caller
must meet them. On WebAssembly a positive count is at most 2^32 - 1.

The result's columns may share storage with another argument only when an
element of one starts at exactly the same address as the corresponding element
of the other, for an in-place update. Otherwise their storage must be disjoint.
The C declaration has no `restrict`, because that exact aliasing is allowed.

On x86-64 Linux a stack run follows System V, and on AArch64 Linux it follows
AAPCS64. Stack descriptors take integer argument registers in source order, and
`f32` uniforms take the vector argument registers, `xmm0` to `xmm7` or `s0` to
`s7`. `i32`, `u32` and `bool` uniforms advance the integer register counter.
The run never spills an argument or accepts stack arguments, so a run with more
integer arguments than registers (six on x86, eight on AArch64) fails
compilation, as does one with more than eight uniforms. An `i32` uniform's
unspecified upper register bits can't change its value, and a `bool` keeps only
its value bit. The run calls nothing, and touches the stack only to save the
callee-saved registers that x86 needs when a run has many columns. The AVX
profiles execute `vzeroupper` before returning.

Native stack runs keep the columns they read in vector registers: up to six on
SSE2, seven on AVX2 and NEON, and twenty on AVX-512.
Views, reductions, scans, extraction, insertion and shuffles in native stack
runs are work in progress and fail compilation.

## Verification

The final-object verifier compares each native run with its separately
assembled selection, including branch offsets, memory operands and embedded
literals. Any difference or unresolved relocation is rejected. On WebAssembly
every SIMD instruction in a run must be one its source operations select.

`test/native_stream_test.sh` checks native stack runs against independent C
results, with exact in-place output and every tail remainder, columns ending at
guard pages, masked and compacted selections, compact columns and uniform
arguments. AVX-512 runs on capable hardware or through Intel SDE, and NEON
through AArch64 QEMU. `test/abi_test.sh` calls WebAssembly runs from C for
every count from 0 to 20 with misaligned columns, sentinels after each column
and null columns for empty counts.
