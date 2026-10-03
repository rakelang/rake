# Syntax

This page is the reference for Rake's source syntax: its layout, identifiers,
literals, definitions, types, statements and expressions. The other pages
define what each form means. A form that parses can still be unavailable on a
target, and the compiler reports that separately from a syntax error.

## Layout

Indentation is part of the grammar. A line that ends in `:` opens a body, and
the lines of that body are indented further than the line that opened it,
all by the same amount. A body ends when a line returns to an outer
indentation. Indentation uses spaces, and a tab in indentation is an error.

Lines inside parentheses, brackets or data braces continue the line they
started on, so a long parameter list can be spread over several lines. A
multiline pack or record body is indented. A `slow { ... }` body restores
statement layout, even inside a call: its statements are indented, and its
closing brace returns to the opening line's indentation. Empty braces need
no body. On one line, a slow block separates statements with semicolons.
Blank lines and comment-only lines don't affect indentation.

`~~` starts a comment that runs to the end of the line. `(*` and `*)` enclose
a block comment, and block comments nest.

## Identifiers

An identifier starts with a lowercase letter or an underscore and continues
with letters, digits and underscores. A name that starts with an uppercase
letter is a type name, used for packs and records, such as `Samples`.
Records and header-backed unions may also retain lowercase C typedef
identifiers. Primitive type spellings such as `i32` may appear as member
identifiers after a field type, in a literal or after `.`. A lone
`_` is the default arm of a sweep, not an identifier. These words are reserved and can't be used as identifiers:

```text
and bool bools break by const continue scratch else embed extern f32 f32s f64
f64s false fma for from gaps i16 i16s i32 i32s i64 i64s i8 i8s if in into lanes
let mask mut not or pack ptr rake record repeat return rotate_left
rotate_right run shift_left shift_right shuffle slow stack state sweep then
through tine to true u16 u16s u32 u32s u64 u64s u8 u8s unchecked union up using
means while yield
```

`wrap` and `bitcast` are conversions when a parenthesis follows them, as in
`wrap(u8, x)`, and ordinary identifiers otherwise.

## Literals

Integers are written in decimal or in hexadecimal with `0x`. A decimal
literal up to 2^64 - 1 is accepted, and one above 2^63 - 1 is read as the bit
pattern of a `u64`. Floats need a decimal point or an exponent: `1.0`, `2.`
and `1e-3`. `true` and `false` are the Boolean literals. A string literal in
double quotes specifies a file after `from`, or passes text to a C function. Its
escapes are kept as written, for C to read.

A minus sign before a literal makes it negative, and a minus sign between two
operands subtracts, so `n-1` and `n - 1` mean the same. A literal's type comes
from the value beside it or the type expected where it stands: in `x * 2`
with `x` an `f32s`, the `2` is a float rack constant.

Three marks carry machine meaning, and each has one role:

- `<value>` is uniform, one scalar shared by every lane. The brackets appear
  where a uniform is declared, as in `<scale: f32>`, and where it is used, as
  in `<scale>`. They also mark literals and elements used as uniforms:
  `<0.5>`, `<-1>`, `<config.limit>` and `<weights[i]>`. A broadcast from a
  scalar into a rack is therefore always visible in the source.
- `#active` is a tine, a named lane mask. The `#` sits directly against the
  name.
- `| result <| expression` binds one stage of a fused computation. Read it
  from right to left: the expression flows into `result`. The leading bar
  lines up consecutive stages.

## Definitions

A file holds one or more definitions:

<!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
```rake
scratch scale(values: f32s, <factor: f32>) -> f32s:
  values * <factor>

tine #valid(values: f32s) means values >= <0.0>

rake safe_root(values: f32s) -> f32s:
  through #valid(values) into rooted:
    sqrt(values)

  sweep:
    | #valid(values) => rooted
    | #valid(values) gaps => <0.0>
```

| Definition | Meaning | Defined in |
| --- | --- | --- |
| `scratch name(parameters) -> T:` | straight-line rack computation | [Fused bindings](04_fused_bindings.md) |
| `rake name(parameters) -> T:` | rack computation with named lane masks | [Tines, through and sweeps](03_tines_and_through.md) |
| `tine #label(parameters) means predicate` | reusable typed lane predicate | [Tines, through and sweeps](03_tines_and_through.md) |
| `run name(parameters) -> T:` | vector code over memory | [Packs and runs](02_packs_and_run.md) |
| `pack Name { T: field, field; }` | one record, also defining the fields of its columnar stack | [Packs, stacks and runs](02_packs_and_run.md) |
| `slow name(parameters) -> T:` | scalar code | [The slow tier](08_slow_tier.md) |
| `extern slow name(parameters) -> T from "file.h"` | a C function | [The slow tier](08_slow_tier.md) |
| `record Name { T: field; }` | a general scalar record | [The slow tier](08_slow_tier.md) |
| `union Name from "file.h" { T: field; }` | a header-backed C union | [The slow tier](08_slow_tier.md#c-unions) |
| `state name: T := value`, `state name: T` | module state | [The slow tier](08_slow_tier.md) |
| `embed name from "file"` | a file's bytes | [The slow tier](08_slow_tier.md) |
| `const name: T = value` | a compile-time constant | [The slow tier](08_slow_tier.md) |

A pack or record groups its fields by type, with the type first:
`f32: position, velocity;` gives two `f32` fields. A stack column is a
scalar type, and a record field can be any type. A C struct is declared as
`record Name from "file.h" { ... }`. A header-backed union uses the same field
groups, and its literal initialises exactly one field.

## Parameters and results

Parameters are written `name: type` and separated by commas. A uniform scalar
parameter is written `<name: type>`. A result type follows `->`. A scratch's
last expression supplies its result. A rake ends with its sweep. A run declared
`-> f32` yields racks from a traversal and writes their lanes to an `f32`
output stream, and a run without a result type writes through its `mut`
parameters instead. A slow function without a result type returns nothing.
`return` is reserved for leaving a slow function, not for a scratch.

A scratch, rake or run may call scratches and rakes. The call is inlined, so
calls nest at most 32 deep and recursion is rejected.

## Types

| Type | Meaning |
| --- | --- |
| `f32` `f64` `i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64` `bool` | a scalar |
| `f32s` `u8s` `i16s` `i32s` `u32s` `i64s` `u64s` | a rack: one vector value of lanes of that element |
| `mask` | a lane mask |
| `stack Name`, `mut stack Name` | the columns of a stack, read or written |
| `Name`, `pack Name` | one pack record |
| `[]T`, `mut []T` | a view: elements with a runtime count |
| `[N]T` | an array of `N` elements, or of `N` racks when `T` is a rack |
| `ptr T`, `ptr const T` | a C pointer with writable or read-only pointed-to storage |
| `Name` | a record |
| `mut T` | a parameter the callee writes |

`f32s` racks work on every production profile. WebAssembly implements the
integer racks `u8s`, `i16s`, `i32s`, `u32s`, `i64s` and `u64s`. The development
compiler also supports [a native 32-bit integer subset](01_primitives_operations_and_targets.md#integer-racks).
The types `i8s`, `u16s`, `f64s` and `bools` parse but have no implementation yet.

## Statements

| Form | Meaning |
| --- | --- |
| `let name = e`, `let name: T = e` | an immutable binding |
| `let <name: T> = e` | a uniform scalar in vector code |
| `name := e`, `name: T := e`, `(name: T) := e` | a mutable location |
| `place <- e` | assignment to a location, field, element or memory |
| `\| name <\| e`, `\| name: T <\| e` | a fused binding |
| `return e`, `return` | leaving a slow function |
| `sweep:` with arms | the final, lane-by-lane result of a rake |
| `yield e` | the rack a traversal produces for its chunk |
| `if c:` … `else if c:` … `else:` | a conditional statement |
| `while c:` | a loop in slow code |
| `for i from a up to b:`, `for i from a up to b by s:` | a counted loop, written `for <i: T> from <a> up to <b>:` in vector code |
| `repeat <i: T> from <0> up to <4>:` | a vector loop with constant bounds, unrolled when it is small |
| `for chunk in p using f32s up to <n>:` | a traversal of a stack |
| `break`, `continue` | inside a slow loop |
| `slow { statements; value }` | a scoped scalar escape in a run or slow function, optionally producing a scalar |
| `e` | a scratch's final result, or a call evaluated for its effect |

A name is bound once in its scope and can't shadow an enclosing name. A mutable location
changes with `<-`. [Control flow](05_control_flow.md) defines the
conditionals and loops, [Packs and runs](02_packs_and_run.md) the traversal,
and [the slow tier](08_slow_tier.md) the scalar statements.

## Tines, through and sweeps

A global tine defines a reusable predicate with typed inputs. Local tines
can refer directly to a rake's inputs. A rake's body is, in order, any
setup bindings, any local tines, its through blocks and the sweep:

```rake
rake clamp_band(values: f32s, <low: f32>, <high: f32>) -> f32s:
  tine #above means values > <low>
  tine #over means values > <high>

  through (#above and not #over) else <0.0> into shifted:
    values - <low>

  sweep:
    | #over => <high> - <low>
    | _     => shifted
```

A tine's predicate uses comparisons, other tines, parentheses, `not`, `and`
and `or`, and arithmetic and fields on its operands. Calls apply global
tines, as in `#valid(values)`, but ordinary function calls aren't permitted.
Postfix `gaps` inverts a tine or parenthesised predicate. A through block
selects a local tine, a global application or a composed predicate.
`else` is optional: without it, only the selected lanes have a defined
value. `into` binds that result. A sweep takes the first matching arm for
each lane and requires provable total coverage. A final `_` supplies any
remaining lanes, or a `gaps` arm can cover them explicitly.
[Tines, through and sweeps](03_tines_and_through.md) defines the coverage
and partial-value rules.

## Expressions

From the lowest precedence to the highest:

| Form | Notes |
| --- | --- |
| `if c then a else b` | a value chosen by a condition or by a mask |
| `a or b` | Boolean or mask |
| `a and b` | Boolean or mask |
| `a = b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b` | comparisons |
| `a + b`, `a - b` | |
| `a * b`, `a / b`, `a % b` | `%` is integer remainder |
| `-a`, `not a` | |
| `a.field`, `a[i]`, `a[unchecked i]` | fields and indexing |
| literals, identifiers, marks, calls, `(e)` | |

A comparison of floats is false when either operand is NaN, and that includes
`!=`: Rake's `!=` means "ordered and different". Integer arithmetic in slow
code traps on overflow, and the wrapping forms `wrap_add`, `wrap_sub` and
`wrap_mul` are explicit. A rack's integer arithmetic wraps, as its hardware
does.

Other primary forms are calls `f(a, b)`, conversions `i32(x)` (checked),
`wrap(u8, x)` (the low bits) and `bitcast(u32, x)` (the same bits), record
literals `Name { field: e }`, stack constructors `stack Name { field: column }`,
and array literals `[a, b, c]` and `[e; n]`.

Rack operations use function-call syntax rather than operators:

| Operations | Page |
| --- | --- |
| `sqrt` `abs` `floor` `ceil` `trunc` `nearest` `min` `max` `exp` `log` `log2` `tanh` `fma` `select` | [Primitives, operations, and targets](01_primitives_operations_and_targets.md) |
| `relaxed_madd` `relaxed_nmadd` `relaxed_min` `relaxed_max` | [Primitives, operations, and targets](01_primitives_operations_and_targets.md) |
| `dot` `narrow` `widen_low` `widen_high` `to_f32` `to_i32` `bitmask` | [Primitives, operations, and targets](01_primitives_operations_and_targets.md) |
| `bit_and` `bit_or` `bit_xor` `bit_andnot` `shift_bits_left` `shift_bits_right` `shift_bits_right_signed` | [Primitives, operations, and targets](01_primitives_operations_and_targets.md) |
| `shuffle(a, [3, 2, 1, 0])`, `shuffle(a, b, [0, 4, 1, 5])` | [Primitives, operations, and targets](01_primitives_operations_and_targets.md) |
| `extract(rack, 2)`, `insert(rack, 2, <x>)` | [Reductions and scans](06_reductions_and_scans.md) |
| `sum` `product` `minimum` `maximum` `all` `any` | [Reductions and scans](06_reductions_and_scans.md) |
| `scan_sum` `scan_product` `scan_minimum` `scan_maximum` | [Reductions and scans](06_reductions_and_scans.md) |
| `widen(chunk.column)` | [Packs and runs](02_packs_and_run.md) |

A shuffle's lane indices and the lane of `extract` and `insert` are integer
literals, because the instruction encodes them. Slow code has its own scalar
functions, listed in [the slow tier](08_slow_tier.md).

These forms parse but have no implementation on any profile: `@` (the lane
index), `lanes` (the lane count), `zip_low`, `shift_left`, `shift_right`,
`rotate_left` and `rotate_right` (lane moves), and the math functions `sin`,
`cos`, `tan`, `pow` and `atan2`. The compiler rejects a program that uses
them and says which feature is missing.

## Tokens

`<|`, `=>`, `->`, `<-`, `:=`, `<=`, `>=` and `!=` are single tokens. `<-1.0>`
is a uniform literal, not `<-` followed by `1.0>`, because a mark around a
literal is read as one token. Parentheses group and hold parameter lists and
arguments, braces hold pack and record bodies, aggregate literals, and
brackets hold indices, array types and literals, and shuffle lane lists.
`;` ends a field group, and `:` introduces a type or a body.
