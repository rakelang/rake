# Rake source syntax

This document defines Rake's canonical source syntax. The spelling is part of
the language contract: diagnostics, examples, editor tooling, and compiler
capability reports use the same forms.

Indentation is structural. A line ending in `:` introduces an indented body,
and every statement in that body uses the same indentation depth. `~~` starts
a line comment. Identifiers begin with an ASCII letter or underscore and
continue with ASCII letters, digits, or underscores.

## The notation carries machine meaning

Rake keeps three unusual marks because each makes a performance-relevant fact
visible where code is read:

- `<value>` is uniform: one scalar value shared by every lane. The brackets
  appear both in declarations, such as `<scale: f32>`, and uses, such as
  `<scale>`. Seeing many scalar markers in a kernel should provoke the
  question: could these values vary by lane, or be stored and processed more
  efficiently?
- `#active` is a tine: one Boolean hole-or-bar decision for every lane. The
  hash resembles a perforated mask, so values pass through its open lanes.
- `| result <| expression` binds one stage of verified vector flow. Read the
  arrow from right to left: the expression flows into `result`. The leading
  bar aligns consecutive stages and marks the region whose fusion contract the
  compiler must prove.

These marks do not abbreviate arbitrary punctuation-heavy grammar. Each has
one stable role. Words carry control structure; the glyphs expose the machine
shape that ordinary scalar-looking syntax would hide.

## Definitions

Every nonempty file contains one or more definitions:

```text
stack Samples {
  f32: value;
  u8: quality;
}

crunch scale(values: f32s, <factor: f32>) -> f32s:
  return values * <factor>

rake safe_root(values: f32s) -> f32s:
  tine #valid when values >= <0.0>

  through #valid else <0.0> into rooted:
    sqrt(values)

  return sweep:
    | #valid => rooted
    | _      => <0.0>

run scale_values(
  input: pack Samples,
  <count: i64>,
  <factor: f32>
) -> f32:
  for chunk in input using f32s up to <count>:
    yield chunk.value * <factor>
```

`stack` declares structure-of-arrays storage. `crunch` describes straight-line
rack computation. `rake` adds explicit lane predication. `run` traverses pack
storage and yields output elements. `type` aliases and `single` schemas are
reserved for later contracts and are not source forms.

Stack declarations put each stored type before the columns that share it:
`f32: position, velocity, depth;`. The grouping makes storage density scannable
down the left edge and avoids repeating a type on every field. Plural rack
types remain visually related—`f32` is one stored element and `f32s` is one
target-native rack—without a verbose two-word type construction.

## Parameters and results

Parameters are comma-separated inside parentheses:

- `values: f32s` passes a rack;
- `input: pack Samples` passes a pack descriptor; and
- `<count: i64>` passes a uniform scalar.

The type comes after a parameter name because the name remains the natural
reading anchor. `pack Samples` is prefix construction: it reads as "a pack of
Samples" and composes consistently with forms such as `mut pack Samples`.

A `crunch` or `rake` result annotation names the returned scalar or rack type.
A `run` result annotation names the stored output element type. Thus a run
declared `-> f32` yields one `f32s` rack per full iteration and writes its
active lanes to an `f32` output column.

`return expression` completes a `crunch` or straight-line result. `return
sweep:` completes a predicated `rake`. `yield expression` emits one rack from a
pack traversal. Keeping `return` and `yield` distinct prevents a run's stream
of output racks from looking like the last value of an ordinary function.

## Types

The singular primitive types are `f32`, `f64`, `i8`, `i16`, `i32`, `i64`,
`u8`, `u16`, `u32`, `u64`, and `bool`. Appending `s` denotes one physical rack
of that element type: `f32s`, `u8s`, `u32s`, and so on. Singular types in a
stack declaration describe stored column elements; plural types in executable
code describe target-native registers.

The remaining source types are `mask`, `pack Name`, and `stack Name`. Compound,
tuple, function, and unit types require their own published contracts before
they become source forms.

## Bindings and statements

The statement forms are:

| Form | Meaning |
| --- | --- |
| `let name = expression` | inferred immutable binding |
| `let name: type = expression` | annotated immutable binding |
| `name := expression` | inferred mutable location binding |
| `name: type := expression` | annotated mutable location binding |
| `name <- expression` | location assignment |
| fused-flow binding | verified pure binding; form below |
| annotated fused-flow binding | verified binding with an explicit result type |
| `return expression` | ordinary function result |
| `yield expression` | one output rack from a run traversal |
| `expression` | expression statement |

A fused-flow binding is written as one of these forms:

```text
| name <| expression
| name: type <| expression
```

It is pure and may neither call unknown code nor access
memory. Every stage in one contiguous sequence of `| ... <| ...` bindings must
remain inline, spill-free, and represented by native rack operations. The
backend rejects the definition if it cannot preserve that contract. A fused
name is a readable alias, not a storage, evaluation, instruction, or rounding
boundary. Ordinary arithmetic lets the backend choose the fastest legal graph
for the target; `fma(a, b, c)` is written only when correctness requires its
one-rounding operation.

## Pack traversal

The canonical traversal header is:

```text
for chunk in input using f32s up to <count>:
  yield chunk.value
```

`input` is a pack, `f32s` is the physical traversal domain, and `<count>` is a
uniform logical-record bound. The rack type fixes how many records each full
iteration processes on the selected target. A stack column with the same
element width becomes a rack directly; a narrower column remains a storage
slice until `widen(column)` converts it explicitly.

The words make the iteration read in execution order: bind `chunk` from
`input`, use `f32s` registers, stop at the scalar bound. No pipe operator is
needed merely to introduce the loop binding.

## Tines, through regions, and sweeps

A tine declaration names a lane mask:

```text
tine #active when values >= <threshold>
```

Predicates use comparisons `< <= > >= = !=`, tine references, parentheses,
and `not`, `and`, and `or`. Arithmetic inside comparisons uses the ordinary
numeric operators.

A through region computes a candidate only for lanes admitted by its tine:

```text
through #active else <0.0> into adjusted:
  values - <threshold>
```

`else` supplies a safe operand or passthrough for inactive lanes; `into` names
the resulting candidate. A through body may contain immutable or fused-flow
bindings before its final expression.

A sweep makes the result total:

```text
return sweep:
  | #active => adjusted
  | _       => values
```

Arms are considered from top to bottom. Every sweep ends with exactly one `_`
arm, and no arm follows it. The `|` aligns alternatives visually; `=>` means
that lanes selected on the left receive the value on the right.

## Expressions

Primary expressions are literals, identifiers, scalar markers, the lane index
`@`, `lanes`, calls, field access, indexing, and parenthesized expressions.
Arithmetic uses `+`, `-`, `*`, `/`, and `%`; comparisons use `<`, `<=`, `>`,
`>=`, `=`, and `!=`; Boolean composition uses `not`, `and`, and `or`.

Explicit rack operations use names rather than cryptic operator ligatures:

- reductions: `sum`, `product`, `minimum`, `maximum`, `all`, and `any`;
- inclusive scans: `scan_sum`, `scan_product`, `scan_minimum`, and
  `scan_maximum`;
- rearrangements: `shuffle`, `zip_low`, `shift_left`, `shift_right`,
  `rotate_left`, and `rotate_right`;
- conversion: `widen`; and
- fused arithmetic: `fma`.

Named operations are searchable, pronounceable, and leave `<...>`, `#...`, and
`<|` as the language's small, coherent visual vocabulary.

Binary precedence runs from lowest to highest: `or`; `and`; comparisons;
addition and subtraction; multiplication, division, and modulo. Unary `-` and
`not` bind above binary operators. Calls, fields, and indexing bind most
tightly.

## Delimiters

The grammar uses `()` for parameter lists, calls, grouping, and tuples; `{}`
for stack bodies and records; `[]` for indices and static shuffle lists; `,`
for lists; `;` to terminate type-first stack groups; and `:` for annotations
and indented bodies. `#` introduces tines, `< >` mark uniform scalars, `@`
names lanes, `.` selects fields, and `<|`, `=>`, `<-`, and `:=` are indivisible
tokens.

Parser acceptance is not native acceptance. After parsing and type checking,
the selected target independently proves rack representation, safe masking,
fusion, register allocation, ABI, and object-code restrictions. A capability
report must distinguish an unavailable semantic or target contract from a
syntax error.
