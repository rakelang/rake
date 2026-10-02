# Syntax

This page is the reference for Rake's source syntax: its layout, names,
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
multiline stack or record body is indented. A `slow { ... }` body restores
statement layout, even inside a call: its statements are indented, and its
closing brace returns to the opening line's indentation. Empty braces need
no body. On one line, a slow block separates statements with semicolons.
Blank lines and comment-only lines don't affect indentation.

`~~` starts a comment that runs to the end of the line. `(*` and `*)` enclose
a block comment, and block comments nest.

## Names

An identifier starts with a lowercase letter or an underscore and continues
with letters, digits and underscores. A name that starts with an uppercase
letter is a type name, used for stacks and records, such as `Samples`. A lone
`_` is the default arm of a sweep, not a name. These words are reserved and can't be used as names:

```text
and bool bools break by const continue crunch else embed extern f32 f32s f64
f64s false fma for from i16 i16s i32 i32s i64 i64s i8 i8s if in into lanes
let mask mut not or pack ptr rake record repeat return rotate_left
rotate_right run shift_left shift_right shuffle slow stack state sweep then
through tine to true u16 u16s u32 u32s u64 u64s u8 u8s unchecked up using
when while yield
```

`wrap` and `bitcast` are conversions when a parenthesis follows them, as in
`wrap(u8, x)`, and ordinary names otherwise.

## Literals

Integers are written in decimal or in hexadecimal with `0x`. A decimal
literal up to 2^64 - 1 is accepted, and one above 2^63 - 1 is read as the bit
pattern of a `u64`. Floats need a decimal point or an exponent: `1.0`, `2.`
and `1e-3`. `true` and `false` are the Boolean literals. A string literal in
double quotes names a file after `from`, or passes text to a C function. Its
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
crunch scale(values: f32s, <factor: f32>) -> f32s:
  return values * <factor>

rake safe_root(values: f32s) -> f32s:
  tine #valid when values >= <0.0>

  through #valid else <0.0> into rooted:
    sqrt(values)

  sweep:
    | #valid => rooted
    | _      => <0.0>
```

| Definition | Meaning | Defined in |
| --- | --- | --- |
| `crunch name(parameters) -> T:` | straight-line rack computation | [Fused bindings](04_fused_bindings.md) |
| `rake name(parameters) -> T:` | rack computation with named lane masks | [Tines, through and sweeps](03_tines_and_through.md) |
| `run name(parameters) -> T:` | vector code over memory | [Packs and runs](02_packs_and_run.md) |
| `stack Name { T: field, field; }` | the columns of structure-of-arrays storage | [Packs and runs](02_packs_and_run.md) |
| `slow name(parameters) -> T:` | scalar code | [The slow tier](08_slow_tier.md) |
| `extern slow name(parameters) -> T from "file.h"` | a C function | [The slow tier](08_slow_tier.md) |
| `record Name { T: field; }` | a record of fields | [The slow tier](08_slow_tier.md) |
| `state name: T := value`, `state name: T` | module state | [The slow tier](08_slow_tier.md) |
| `embed name from "file"` | a file's bytes | [The slow tier](08_slow_tier.md) |
| `const name: T = value` | a compile-time constant | [The slow tier](08_slow_tier.md) |

A stack or record groups its fields by type, with the type first:
`f32: position, velocity;` gives two `f32` columns. A stack column is a
scalar type, and a record field can be any type. A C struct is declared as
`record Name from "file.h" { ... }`.

## Parameters and results

Parameters are written `name: type` and separated by commas. A uniform scalar
parameter is written `<name: type>`. A result type follows `->`. A crunch or
rake returns the value of its `return` statement or sweep. A run declared
`-> f32` yields racks from a traversal and writes their lanes to an `f32`
output stream, and a run without a result type writes through its `mut`
parameters instead. A slow function without a result type returns nothing.
A crunch's body ends with its `return`.

A crunch, rake or run may call crunches and rakes. The call is inlined, so
calls nest at most 32 deep and recursion is rejected.

## Types

| Type | Meaning |
| --- | --- |
| `f32` `f64` `i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64` `bool` | a scalar |
| `f32s` `u8s` `i16s` `i32s` `u32s` `i64s` `u64s` | a rack: one vector value of lanes of that element |
| `mask` | a lane mask |
| `pack Name`, `mut pack Name` | the columns of a stack, read or written |
| `[]T`, `mut []T` | a view: elements with a runtime count |
| `[N]T` | an array of `N` elements, or of `N` racks when `T` is a rack |
| `ptr T` | a C pointer |
| `Name` | a record |
| `mut T` | a parameter the callee writes |

`f32s` racks work on every production profile. The integer racks `u8s`,
`i16s`, `i32s`, `u32s`, `i64s` and `u64s` are implemented for `wasm-simd128`
only. The types `i8s`, `u16s`, `f64s` and `bools` parse but have no
implementation yet, and neither does `stack Name` as a type: a stack is a
column layout, used through `pack Name`.

## Statements

| Form | Meaning |
| --- | --- |
| `let name = e`, `let name: T = e` | an immutable binding |
| `let <name: T> = e` | a uniform scalar in vector code |
| `name := e`, `name: T := e`, `(name: T) := e` | a mutable location |
| `place <- e` | assignment to a location, field, element or memory |
| `\| name <\| e`, `\| name: T <\| e` | a fused binding |
| `return e`, `return` | the result of a crunch, or leaving a slow function |
| `sweep:` with arms | the final, lane-by-lane result of a rake |
| `yield e` | the rack a traversal produces for its chunk |
| `if c:` … `else if c:` … `else:` | a conditional statement |
| `while c:` | a loop in slow code |
| `for i from a up to b:`, `for i from a up to b by s:` | a counted loop, written `for <i: T> from <a> up to <b>:` in vector code |
| `repeat <i: T> from <0> up to <4>:` | a vector loop with constant bounds, unrolled when it is small |
| `for chunk in p using f32s up to <n>:` | a traversal of a pack |
| `break`, `continue` | inside a slow loop |
| `slow { statements; value }` | a scoped scalar escape in a run or slow function, optionally producing a scalar |
| `e` | a call evaluated for its effect |

A name is bound once in its scope and can't shadow an enclosing name. A mutable location
changes with `<-`. [Control flow](05_control_flow.md) defines the
conditionals and loops, [Packs and runs](02_packs_and_run.md) the traversal,
and [the slow tier](08_slow_tier.md) the scalar statements.

## Tines, through and sweeps

A rake names its lane masks with tines, computes values under them with
`through`, and combines the results with a sweep. A rake's body is, in order,
any `let` bindings, its tines, its through blocks and the sweep:

```rake
rake clamp_band(values: f32s, <low: f32>, <high: f32>) -> f32s:
  tine #above when values > <low>
  tine #over when values > <high>

  through (#above and not #over) else <0.0> into shifted:
    values - <low>

  sweep:
    | #over => <high> - <low>
    | _     => shifted
```

A tine's predicate uses comparisons, other tines, parentheses, `not`, `and`
and `or`, and arithmetic and fields on its operands. It contains no calls.
A through block names one tine, as in `through #active`, or a predicate in
parentheses, as in `through (#active and not #edge)`. `else` gives the value
of the lanes outside the tine, a uniform or a literal, and `into` names the
result. A sweep
takes the first arm whose tine holds for each lane and ends with one `_` arm
for the remaining lanes. [Tines, through and sweeps](03_tines_and_through.md)
defines them.

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
| literals, names, marks, calls, `(e)` | |

A comparison of floats is false when either operand is NaN, and that includes
`!=`: Rake's `!=` means "ordered and different". Integer arithmetic in slow
code traps on overflow, and the wrapping forms `wrap_add`, `wrap_sub` and
`wrap_mul` are explicit. A rack's integer arithmetic wraps, as its hardware
does.

Other primary forms are calls `f(a, b)`, conversions `i32(x)` (checked),
`wrap(u8, x)` (the low bits) and `bitcast(u32, x)` (the same bits), record
literals `Name { field: e }`, and array literals `[a, b, c]` and `[e; n]`.

Rack operations have names rather than operators:

| Operations | Page |
| --- | --- |
| `sqrt` `abs` `floor` `ceil` `trunc` `nearest` `min` `max` `exp` `log` `log2` `tanh` `fma` `select` | [Racks and targets](01_racks_targets_and_abi.md) |
| `relaxed_madd` `relaxed_nmadd` `relaxed_min` `relaxed_max` | [Racks and targets](01_racks_targets_and_abi.md) |
| `dot` `narrow` `widen_low` `widen_high` `to_f32` `to_i32` `bitmask` | [Racks and targets](01_racks_targets_and_abi.md) |
| `bit_and` `bit_or` `bit_xor` `bit_andnot` `shift_bits_left` `shift_bits_right` `shift_bits_right_signed` | [Racks and targets](01_racks_targets_and_abi.md) |
| `shuffle(a, [3, 2, 1, 0])`, `shuffle(a, b, [0, 4, 1, 5])` | [Racks and targets](01_racks_targets_and_abi.md) |
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
arguments, braces hold stack and record bodies and record literals, and
brackets hold indices, array types and literals, and shuffle lane lists.
`;` ends a field group, and `:` introduces a type or a body.
