# Pack-field memory operations and lane rearrangement

This document defines the target-independent contract for Rake pack-field
references, gather, scatter, compression, and expansion. It fixes the behavior
that the frontend, executable interpreter, native intermediate representation,
and target backends must eventually share.

Publication does not make these forms frontend-checked or
native-production-available. The capability catalog and target report remain
the authorities for implementation status. Source spellings marked **Proposal**
below still require a language decision before they can become part of Rake's
source syntax.

## Pack-field references

A pack-field reference identifies one contiguous structure-of-arrays column.
It has four semantic properties:

- an element type;
- a base address;
- a non-negative extent measured in elements; and
- `read` or `read-write` permission.

The extent is never measured in bytes. For the first pack boundary, a
`f32` field has binary32 elements with a four-byte stride. Index `i`
therefore denotes the address `base + i * 4`. Source programs cannot cast a
field reference to an integer, perform byte arithmetic on it, or use it as an
ordinary rack value.

A field reference is a compiler-tracked view rather than a source-declarable
type. Its lifetime is bounded by the call that borrows the pack. The pack
descriptor need not store the extent: pack traversal up to `<count>` can bind
the view's extent to `count`. The caller must still satisfy the pack ABI rule
that every positive-count field range contains at least `count` elements.

The current pack boundary supplies read-only input fields. A future
read-write pack form must grant `read-write` permission explicitly. A write
through a read-only reference is always a compile-time error. Read-only field
references may alias. Two live read-write pack borrows must not overlap, and a
read-write borrow must not overlap another live read borrow, unless a later
source construct publishes a narrower aliasing rule.

**Proposal:** `pack.field` should produce a pack-field reference outside a
traversal body. The same spelling on a traversal chunk, such as `chunk.field`,
continues to produce the rack loaded for that iteration. The source spelling
for a read-write pack parameter is `mut pack Samples`.

## Element indices and bounds

Every gather or scatter index is a signed element index. An active index `i`
is in bounds exactly when:

```text
0 <= i < extent
```

The initial f32 AVX2 contract uses an eight-lane `i32s` represented as
eight signed 32-bit indices. A target must reject an index representation it
cannot lower without truncation. In particular, accepting an i64 index rack
and silently narrowing it to i32 is forbidden.

A safe memory operation checks every active index before performing any data
access. If any active index is out of bounds, the operation traps and produces
no read, write, or partial write effect. The check does not apply to inactive
indices. An inactive index may contain any bit pattern, including a negative
or otherwise invalid value.

An unchecked memory operation omits the bounds check. Its caller promises that
every active index satisfies the bound above. Violating that precondition puts
the program outside Rake's defined semantics. The compiler may remove a safe
check when range and mask provenance prove the same fact.

**Proposal:** safe access should be the default, while an explicit `unsafe` or
`unchecked` source form requests the precondition-based operation. The exact
keyword and its syntactic scope remain undecided. Existing parser recognition
of `base[index]` does not settle how a program selects a safe or unchecked
form.

## Effective masks

Every lane-dependent memory operation has one effective mask. For lane `i`,
the effective mask is the conjunction of all applicable masks:

```text
effective[i] = operation[i] && through[i] && tail[i]
```

A missing operation, through, or tail mask contributes `true`. The tail mask
is false for lanes beyond the logical traversal count. A composed through
predicate contributes its already-composed mask.

Only lanes with a true effective mask participate in bounds checks, duplicate
checks, address formation, loads, or stores. A target may calculate an inert
integer expression for an inactive lane, but it must not issue a memory access,
raise a memory fault, or otherwise make the lane observable. Loading a full
rack and blending afterward does not satisfy this rule.

## Gather

A gather reads one element per active lane from a read or read-write field
reference. Its operands are the field reference, an integer index rack, an
effective mask, and a passthrough rack with the field's element type. Its
result has the same rack element type as the field.

For each lane `i`:

```text
result[i] = effective[i] ? field[index[i]] : passthrough[i]
```

The safe gather performs the complete active-lane bounds preflight before its
first load. An unchecked gather relies on the active-lane bounds precondition.
Both forms leave inactive addresses untouched. Gather has a read effect, so it
is excluded from a fused region. A gather may appear in a through region only
when the target provides a genuinely masked lowering for the effective mask.

The typed native operation must carry the passthrough explicitly. A source
form that omits it may use positive zero with the field's element type as
defined sugar. The omitted value cannot become observable through a surrounding
through expression, whose own passthrough still supplies inactive result
lanes.

**Proposal:** `field[index]` denotes gather with positive-zero passthrough.
An explicit spelling such as `gather(field, index, mask, else_value)` remains a
grammar decision. Neither spelling is claimed as checked by this document.

## Scatter

A scatter writes one rack element per active lane through a read-write field
reference. Scatter is an effectful statement and produces no value. Its value
rack must have the same element type as the referenced field.

For a safe scatter, the implementation first performs one atomic preflight:

1. every active index is in bounds; and
2. no two active lanes have the same index.

If either condition fails, the safe scatter traps before its first store. The
referenced memory therefore remains byte-for-byte unchanged. Once the
preflight succeeds, each active lane stores its value and every inactive lane
does nothing.

An unchecked scatter has two caller preconditions: every active index is in
bounds, and active indices are pairwise distinct. A duplicate active
destination has no last-lane-wins or first-lane-wins interpretation. It is a
precondition violation. Excluding duplicates permits a target with native
scatter to use the instruction without inventing an ordering that the machine
does not guarantee.

Scatter has a write effect. It is excluded from fused regions. A scatter in a
through region is valid only when the backend can suppress every inactive
store with the effective mask. A backend cannot replace the operation with an
unpublished scalar lane loop.

**Proposal:** a form such as `field[index] <- values` denotes safe scatter and
an explicitly unchecked variant requests the precondition-based operation.
The parser does not currently define either scatter statement, so these
spellings are proposals.

## Stable compression

Compression is a pure rack rearrangement. It does not read or write a
pack-field reference. Given a rack `values` and mask `selected`, let
`source(j)` be the lane number of the `j`th true mask lane when lanes are
visited from zero upward. Let `K` be the number of true mask lanes. The result
is:

```text
result[j] = values[source(j)]    for 0 <= j < K
result[j] = +0.0                 for K <= j < lanes
```

The positive-zero fill has the all-zero binary32 bit pattern. Selected values
move bit-for-bit, including NaN payloads and negative zero. Compression is
stable because it preserves the source order of selected lanes. An all-false
mask produces an all-positive-zero rack; an all-true mask reproduces the input
rack exactly.

## Stable expansion

Expansion is the inverse-shaped pure rearrangement. It accepts a packed source
rack `values`, a destination mask `selected`, and a passthrough rack. Define
`rank(i)` as the number of true mask lanes below lane `i`. The result is:

```text
result[i] = values[rank(i)]    when selected[i] is true
result[i] = passthrough[i]     when selected[i] is false
```

Only the first `popcount(selected)` source lanes are consumed. Remaining
source lanes are ignored. Copied source and passthrough values preserve their
bits. Compression and expansion have no bounds, aliasing, or memory effects,
and they do not inherit a surrounding memory reference's extent.

**Proposal:** `compress(values, selected)` and
`expand(values, selected, passthrough)` are candidate source spellings. The
reserved `compress`, `expand`, `<-|`, and `|->` lexer tokens have no current
parser productions. This document does not assign memory semantics to `<-|`
or `|->`; a future compress-store or expand-load operation needs a separate
cursor, count, bounds, and result contract.

## Executable interpreter evidence

The executable interpreter must model each field reference as an element
array, extent, and permission. It records an ordered memory trace containing
one event for every successful active-lane load or store. A trace event records
the operation, field identity, element index, and lane.

Safe gather and scatter preflights add no memory events. A failed preflight
leaves the trace empty for that operation. A successful gather records active
loads in ascending lane order. A successful scatter records active stores in
ascending lane order; pairwise-distinct destinations make that order
unobservable through memory. Unchecked operations use the same trace when
their preconditions hold. The test interpreter must report a deterministic
contract error when a fixture violates an unchecked precondition, even though
such a native program has no defined Rake result.

Compression and expansion add no trace events. Their interpreter results must
preserve the exact binary32 bits specified above.

## AVX2 target contract

The proposed AVX2 f32/i32 gather lowering uses `vgatherdps` with scale four.
Its mask operand is the effective mask. Because AVX2 gather modifies its mask
operand, the backend must copy a still-live mask before the instruction or
prove that the gather is its final use. Safe gather additionally needs a
complete bounds preflight unless prior range analysis proves every active
index valid. Masked-off AVX2 gather lanes must not access memory.

AVX2 has no packed scatter instruction. The `x86-avx2` profile must reject
scatter with a deterministic target-availability error. It must not conceal a
scalar sequence of lane stores behind source scatter. A future AVX-512 profile
may advertise scatter only after its lowering and object verification enforce
the effective-mask and distinct-index contract.

AVX2 can implement pure compression and expansion with mask extraction,
constant permutation tables, `vpermps`, and explicit zeroing or passthrough
selection. Such a sequence is allowed because compression and expansion are
explicit cross-lane operations. This document does not claim that the current
backend implements that sequence.

## Acceptance requirements

A compiler revision may advertise one of these operations only when the same
revision supplies all applicable evidence:

- parser fixtures cover the selected source spelling and its precedence;
- type fixtures distinguish pack-field references from loaded chunk racks,
  enforce reference permission, and reject element or index mismatches;
- effect fixtures reject gather and scatter in fused regions and reject a
  masked memory operation without compliant target support;
- interpreter fixtures cover empty, full, alternating, and sparse effective
  masks, active negative and upper-bound indices, arbitrary inactive indices,
  and duplicate active scatter indices;
- safe-scatter failure leaves both the memory image and operation trace
  unchanged;
- guard-page runtime fixtures place valid storage at a page boundary and show
  that inactive gather lanes and traversal tails neither fault nor touch the
  protected page;
- compression and expansion tests exhaust every mask for the target lane
  count, which is all 256 masks for an eight-lane AVX2 rack, and compare exact
  bits for ordinary values, NaN payloads, positive zero, and negative zero;
- interpreter-to-native differential tests compare the result bits and memory
  trace consequences of every accepted native operation;
- AVX2 object inspection requires `vgatherdps` with scale four for accepted
  unchecked gather and rejects scalar per-lane loads, helper calls, spills,
  and stack use; and
- AVX2 scatter tests require the documented compile-time rejection rather
  than an emitted scalar fallback.

Guard-page, exhaustive-mask, semantic, native differential, and object-level
evidence must agree before a capability becomes production-available. A
parsed form or representable native-IR operation alone does not establish
availability.
