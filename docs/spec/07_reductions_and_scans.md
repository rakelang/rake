# Reductions and prefix scans

A reduction combines every lane of one rack into one scalar. A prefix scan
produces a rack whose lane `i` contains the reduction of lanes zero through
`i`.

Rake spells these operations as names. They are unusual and consequential
enough to deserve searchable, pronounceable words; operator ligatures would
add visual novelty without exposing a new machine distinction.

## Operations and types

| Source form | Operand | Result | Lane operation |
| --- | --- | --- | --- |
| `sum(value)` | `f32s` | `f32` | binary32 addition |
| `product(value)` | `f32s` | `f32` | binary32 multiplication |
| `minimum(value)` | `f32s` | `f32` | strict minimum |
| `maximum(value)` | `f32s` | `f32` | strict maximum |
| `all(value)` | `mask` | `bool` | logical AND |
| `any(value)` | `mask` | `bool` | logical OR |
| `scan_sum(value)` | `f32s` | `f32s` | binary32 addition |
| `scan_product(value)` | `f32s` | `f32s` | binary32 multiplication |
| `scan_minimum(value)` | `f32s` | `f32s` | strict minimum |
| `scan_maximum(value)` | `f32s` | `f32s` | strict maximum |

No implicit conversion changes an operand to satisfy this table. Arithmetic
operations reject masks, logical reductions reject floating-point racks, and
the four scans reject masks. A scalar result is explicit at the boundary:

```text
crunch sum_values(values: f32s) -> f32:
  return sum(values)
```

## Lane order

Let `x` have `N >= 1` lanes, numbered from zero. Each operation defines:

```text
p[0] = x[0]
p[i] = op(p[i - 1], x[i])    for i = 1 through N - 1
```

A reduction returns `p[N - 1]`. A scan returns `[p[0], p[1], ..., p[N - 1]]`,
so every scan is inclusive. Neither form uses a balanced tree, target-selected
reassociation, or exclusive-prefix identity.

Floating-point addition and multiplication round every step to IEEE 754
binary32 using round-to-nearest, ties-to-even. Implementations may not retain a
wider intermediate, contract operations, or reassociate the chain. Logical
AND and OR use the same ascending-lane left fold without rounding.

## Nonempty racks and identities

A zero-lane rack is not a Rake value. Reductions and scans therefore have no
empty-input result and inject no identity. A future masked or variable-length
fold must specify its own empty-active-set behavior before becoming available.

## Strict minimum and maximum

`minimum`, `maximum`, `scan_minimum`, and `scan_maximum` use strict binary32
steps:

1. If either operand is NaN, the result is canonical quiet NaN `0x7fc00000`.
2. For two zeros, minimum is negative zero when either sign bit is set;
   maximum is negative zero only when both sign bits are set.
3. Otherwise the numerically smaller or larger operand is returned.
4. Equal nonzero operands return the left operand.

The NaN rule applies at every fold step. Once a chain encounters NaN, every
later prefix and the final reduction remain canonical NaN. A native lowering
cannot substitute x86 minimum or maximum instructions directly where their
NaN or signed-zero behavior differs.

## Cross-lane restrictions

Reductions and scans are cross-lane operations: one lane's result depends on
other lanes. They cannot appear inside a `through` region or another
lane-masked region. A pack tail mask cannot be applied implicitly because
filling inactive lanes with an identity would define a different operation.

They also remain outside fused-flow bindings. A reduction changes a rack into
a scalar, while a scan introduces ordered cross-lane dependencies; neither
fits the rack-preserving contiguous-flow contract.

## Target obligations

A target advertises one of these operations only after type checking, typed
native IR, executable semantics, native lowering, and object verification all
implement this contract. A backend without a compliant sequence rejects it.

For an eight-lane AVX2 rack, a compliant operation has seven ordered semantic
combine steps. The backend may use shuffles, permutations, blends, and packed
arithmetic, but not a horizontal reduction tree, reassociation, helper call,
spill, reload, or scalar loop. A reduction alone may cross into the scalar
return class.

Acceptance evidence covers every named form and call precedence; type
mismatches; ascending-fold counterexamples; every scan prefix; per-step
rounding; infinities, NaNs, and signed zeros; mask reductions; masked and fused
rejections; exact interpreter/native results; and disassembly establishing the
ordered, call-free, spill-free sequence. All layers must pass in the same
revision before the capability becomes production-available.
