# Packs, stack chunks, and `run`

This document defines Rake's columnar traversal semantics and the first native
binary boundary for them.

## Source meaning

Rake separates the type stored in each structure-of-arrays column from the
physical rack type used to compute on it:

<!-- rake-example:pack-over:start -->
```rake
stack Samples {
  f32: value;
  u8: quality;
}

run scale_values(
  input: pack Samples,
  <count: i64>,
  <scale: f32>
) -> f32:
  for chunk in input using f32s up to <count>:
    let quality: u32s = widen(chunk.quality)
    yield chunk.value * <scale>
```
<!-- rake-example:pack-over:end -->

A `stack` groups column names by their stored element type. It does not contain
400 particles or any other fixed dataset size. A `pack` supplies the complete
column storage, and `<count>` supplies the number of logical records. The `for`
statement visits that dataset in profile-sized chunks.

Putting the type first makes the storage schema read by density class: all
`f32` columns are visibly grouped, then all byte-sized `u8` columns. This is
particularly useful in a language where layout is part of the algorithm rather
than an incidental record representation.

The notation keeps the expensive distinctions visible. `pack Samples` reads as
"a pack of Samples"; `using f32s` states the physical compute domain; and angle
brackets mark `count` and `scale` as uniform scalars at both declaration and
use. Seeing many scalar markers in a kernel should provoke the question: could
these values vary by lane, or be stored and processed more efficiently?

One `f32s` is one physical register. It contains four logical elements on a
128-bit target, eight on a 256-bit target, or sixteen on a 512-bit target. A
400-element pack therefore requires 100, 50, or 25 full `f32s` iterations,
respectively. Source code does not name those target-specific widths.

Each `yield` produces one rack for the current iteration. Its active lanes are
written to the run's output stream. The result annotation names the stored
element type, so `-> f32` means that full iterations yield `f32s` and active
lanes are written to an `f32` output column. A `run` cannot be called as an
expression, and its machine function returns `void`.

The first native boundary accepts one traversed pack, supported fixed-width
storage columns, explicit value-preserving widening, scalar `f32` parameters,
one scalar `i64` count, immutable local bindings, and one terminal traversal.
Mutable locations, assignments, nested traversal, rack parameters, and
multiple outputs require separate published contracts.

## Storage columns and compute racks

A stack is a schema for structure-of-arrays storage. Singular types in its
declaration describe memory density. Plural types describe physical compute
registers elsewhere in the language. Keeping these roles separate lets a `u8`
column occupy one byte per record even when a kernel computes in `f32s` racks.

For this stack:

```text
stack Point {
  f32: x, y;
  u8: age;
}
```

the C-compatible descriptor is:

```c
struct rake_pack_Point_v1 {
    const float *x;
    const float *y;
    const uint8_t *age;
};
```

The descriptor has one field pointer for each stack field in declaration
order. It has no array-of-structures representation, hidden aggregate
allocation, or runtime stride. Pointer fields are eight bytes wide on x86-64.
Each pointer addresses a contiguous array whose stride and minimum alignment
come from its stored type: four bytes for `f32` and one byte for `u8`.

At iteration offset `i`, a referenced field selects `lanes` consecutive stored
elements beginning at `field[i]`. A field whose stored width equals the domain
width becomes its corresponding rack directly. In an `f32s` traversal, `f32`
becomes `f32s` and `u32` becomes `u32s` because both have one element per
32-bit lane.

A narrower field produces a storage slice, not an executable value. The only
way to consume it is `widen`. In the example, `chunk.quality` selects eight
bytes on AVX2 and `widen(chunk.quality)` produces one eight-lane `u32s` rack.
The compiler rejects arithmetic, calls, or yields that use the unwidened slice.
This prevents an accidental scalar loop, gather, split rack, or implicit loss
of storage density.

The widening rules preserve signedness and value:

| Stored column | 32-bit domain | 64-bit domain |
| --- | --- | --- |
| `i8`, `i16` | `i32s` | `i64s` |
| `u8`, `u16` | `u32s` | `u64s` |
| `i32` | already one rack | `i64s` |
| `u32` | already one rack | `u64s` |
| `f32` | already one rack | `f64s` |

`widen` is a numerical conversion, never a bitcast. A stored element wider
than the traversal domain cannot be narrowed or split by `widen`. An all-byte
kernel may instead use `u8s` and process 16, 32, or 64 records per rack on
128-, 256-, or 512-bit targets. Mixed particle kernels normally choose the
domain of their arithmetic fields and widen dense metadata such as ages or
flags.

A chunk is an immutable snapshot. The compiler may omit an unreferenced field
load. The chunk itself requires no hidden allocation or memory object. Native
acceptance additionally requires disassembly proof that every accepted
widening uses target vector instructions and introduces no scalar lane work.

## Ownership, mutation, and aliasing

The caller owns every descriptor, field array, and output array. A `run`
borrows them for the call and never allocates, retains, resizes, or frees their
storage.

Pack descriptors and input fields are read-only. The output is write-only.
Input fields may alias because the function only reads them. The output range
must either be disjoint from every input range or begin at exactly the same
address as one input field for in-place operation. Partial overlaps are outside
the ABI contract.

Every referenced field for one chunk is loaded before that chunk's result is
stored. Exact in-place operation therefore observes the chunk's input snapshot.
The C declaration must not use `restrict`, because exact input/output aliasing
is permitted.

## Count and iteration

The traversal count is a signed `i64`. A count less than or equal to zero is an
empty traversal. The function returns without dereferencing the pack
descriptor, any field pointer, or the output pointer; those pointers may be
null for an empty traversal.

For a positive count, every referenced input column and output range contains
at least `count` elements. An AVX2 `f32s` traversal processes offsets `0`, `8`,
`16`, and so on. Each full iteration uses native YMM loads and stores. A final
tail iteration handles `count mod 8` lanes. Every logical output element is
written exactly once, storage beyond `count` remains unchanged, and a scalar
cleanup loop is forbidden.

Natural alignment is sufficient. Full-rack AVX2 `f32` memory operations use
unaligned vector forms such as `vmovups`; callers need not over-align arrays to
32 bytes.

## Tail semantics

A tail chunk has the active mask:

```text
active[lane] = lane < (count mod lanes)
```

Inactive lanes have no source-level value. A backend may materialize a benign
value for them, but it cannot become observable. On AVX2, `f32` tails use
masked loads and stores. Narrow storage loads and widening sequences require
their own bounds-safe lowering. Masked-off addresses are never accessed.

Memory masking alone is insufficient. The tail mask also combines with every
explicit tine. Inactive operands are sanitized before partial operations:
inactive division uses numerator `0.0` and denominator `1.0`, and inactive
square root uses `0.0`. An operation without a proven total, sanitizable, or
mask-native lowering is rejected. Inactive lanes must not raise floating-point
exceptions, call code, access memory, or cause another observable effect.

## `x86_64-avx2-fma-sysv` boundary

ABI v1 passes one pointer to a pack descriptor rather than one argument per
field. Arguments are classified in source order:

- pack descriptor pointers, `i32`, and `i64` consume `rdi`, `rsi`, `rdx`,
  `rcx`, `r8`, then `r9`;
- scalar `f32` parameters consume `xmm0` through `xmm7` independently; and
- the implicit `f32` output pointer follows source parameters and consumes the
  next integer-class register.

The boundary rejects more than six integer-class or eight SSE-class arguments;
it does not pass overflow arguments on the stack. A `run` returns `void`, uses
the validated source function name as its unmangled default-visible symbol,
creates no local stack frame, calls no helper, and executes `vzeroupper` before
returning.

The example has this C declaration:

```c
void scale_values(
    const struct rake_pack_Samples_v1 *input, /* rdi */
    int64_t count,                            /* rsi */
    float scale,                              /* xmm0 */
    float *result                             /* rdx */
);
```

Other operating systems and target profiles require their own published
classifier, assembly, runtime fixtures, and object verification.

## Acceptance requirements

Production status requires all of these checks in one compiler revision:

- interpreter/native comparison across empty, full, and tail counts;
- null descriptor and output pointers for nonpositive counts;
- one-field and multi-field descriptor layout checks;
- mixed `f32`/`u8` descriptors and value-preserving widening;
- naturally aligned but vector-misaligned arrays;
- sentinels after the logical output range;
- exact in-place output and aliased read-only inputs;
- scalar broadcasts and bit-exact binary32 results;
- partial operations whose inactive tail lanes raise no exceptions;
- guard-page arrays ending at the logical bound; and
- disassembly showing vector memory operations, masked tails, whole-rack loop
  control, `vzeroupper`, and no calls, spills, stack frame, scalar lane work,
  or scalar cleanup loop.

Negative tests cover invalid schemas and counts, unwidened narrow columns,
unsupported conversions, incompatible traversal domains, wrong traversed
values, missing or nested terminal traversal, mutation, multiple outputs,
non-rack yields, ABI overflow, register pressure requiring a spill, and every
tail operation without safe masked lowering.

Frontend acceptance alone is insufficient. A target advertises `run` only
when parsing, checking, native lowering, executable comparison, and object-code
verification all implement this contract.
