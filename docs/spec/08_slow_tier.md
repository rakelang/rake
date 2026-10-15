# The slow tier and whole programs

Slow code is a Rake program's scalar orchestration: records, arrays, module
state, embedded data, control flow and calls to C. It's marked `slow` so that
nobody mistakes it for vector code. A whole scalar function is declared
`slow name(...)`, and a `slow { ... }` block is a lexical escape inside a run,
like Rust's `unsafe { ... }`, while the rack work around it stays vector code.

A program with any slow, run, record, union, state, embed, const or extern
definition is a whole program. On `wasm-simd128` and `wasm-simd128-relaxed` it
compiles to one C translation unit with a C entry point, the form required
by a C-only judge. On x86-64 and AArch64, Rake emits native C and objects
that combine slow orchestration with register kernels, and SSE2, AVX2,
AVX-512 and NEON also compile [stack runs](02_packs_and_run.md#stack-runs).
General runs over views remain work in progress on those profiles.

## Native kernel calls

A native register kernel called from slow code takes uniform `f32`, `bool`,
`i32` or `u32` parameters and returns one of those types. Rake selects the
kernel's instructions and checks them in the final object, while the platform
C compiler lowers the slow caller. Other native scalar kernel boundaries
remain work in progress.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch carry(<value: f32>) -> f32:
  <value>

slow main() -> i32:
  return i32(carry(<3.5>))
```

Where the selected profile supports it, a kernel may also broadcast its
uniforms and reduce a rack, including to a Boolean, which reaches slow code as
C `bool`:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch all_positive(<value: f32>) -> bool:
  all(<value> > <0.0>)

slow main() -> i32:
  if all_positive(<3.5>):
    return 1
  return 0
```

## Process arguments

`slow main` takes either no parameters or an argument count and a pointer to
byte strings:

<!-- rake-check: run 1 -->
```rake
slow main(argc: i32, argv: ptr ptr u8) -> i32:
  if is_null(argv[unchecked argc]):
    return argc
  return 255
```

`argc` includes the program at `argv[0]`, each string ends with a zero byte,
and `argv[argc]` is a null pointer. A UTF-8 character may occupy several
bytes. Pointer indexing is `unchecked`, so the program needs to stay within
the argument count and each string's bounds.

The emitted entry is C's `int main(int argc, char **argv)`, which needs the
platform C runtime, or WASI libc on WebAssembly. It passes `main` a copy of
the pointer array, freed when `main` returns, so don't retain the array's
address beyond the call. In `rakec --interpret`, `argv[0]` is the input file
path, and the browser interpreter supplies `program` and no other arguments.

## An example

<!-- rake-check: run 33 -->
```rake
pack Samples {
  f32: value;
  u8: quality;
}

run weigh(samples: stack Samples, <scale: f32>) -> stack Samples:
  let quality = to_f32(widen(samples.quality))
  samples with { value: samples.value * <scale> + quality }

run running_sum(x: []f32, out: mut []f32, <n: i32>):
  total := <0.0>
  for <i: i32> from <0> up to <n> by <4>:
    total <- total + x[<i>]
    out[<i>] <- total

state calls: i32 := 0

slow main() -> i32:
  values: [8]f32 := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
  qualities: [8]u8 := [0, 1, 0, 1, 0, 1, 0, 1]
  let weighed = weigh(stack Samples { value: values, quality: qualities }, <0.5>)
  sums: [8]f32 := [0.0; 8]
  running_sum(weighed.value, sums, <8>)
  calls <- calls + 1
  return i32(sums[7] * 4.0) + calls
```

## Slow blocks

`slow {` enters scalar code and `}` returns to the enclosing mode. A block
can contain scalar loops, calls, records, arrays and access to module state.
Its last expression produces its scalar value, while a final semicolon or no
final expression produces nothing.

<!-- rake-check: run 22 -->
```rake
run shift(values: []i32, out: mut []i32, <steps: i32>):
  let rack = values[<0>]
  let <offset: i32> = slow {
    total: i32 := 0
    for index from 0 up to steps:
      total <- total + index
    total
  }
  out[<0>] <- rack + <offset>

slow main() -> i32:
  values: [4]i32 := [1, 2, 3, 4]
  shifted: [4]i32 := [0; 4]
  shift(values, shifted, <3>)
  return shifted[0] + shifted[1] + shifted[2] + shifted[3]
```

Inside the block, `steps` is a bare scalar name, and outside it `<offset>`
explicitly broadcasts the result.

Blocks have lexical scope and may nest. Their locals end at `}` and can't
shadow an enclosing binding, although sibling blocks may reuse a name. A block
inside a slow function shares that function's mutable locations. A block in a
run can read the run's uniforms and scalar-element views and write a mutable
view, but it can't refer to a rack, mask, rack array or stack column. Block
results are scalar or void, so no local array, record or borrowed view
escapes.

Semicolons separate statements on one line, as in
`slow { let x = 2; x + 1 }`, which produces 3, and multiline bodies are
indented like other Rake bodies. `slow {}` is empty. A `return` inside a slow
function's block returns from that function. Runs have no early `return`, and
in a run, `break` and `continue` inside a block refer only to scalar loops
inside that block.

Scratches, rakes and fused regions reject slow blocks. Blocks and whole
programs with memory runs compile for WebAssembly only.

## Definitions

| Definition | Meaning |
| --- | --- |
| `slow name(parameters) -> T:` | a scalar function, with or without `-> T` |
| `extern slow name(parameters) -> T from "header.h"` | a C function |
| `record Name { T: field, field; }` | a record with Rake's layout |
| `record Name from "header.h" { T: field; }` | a C struct |
| `union Name from "header.h" { T: field; }` | a C union |
| `state name: T := constant`, `state name: T` | module state |
| `embed name from "file"` | a file's bytes |
| `const name: T = constant` | a compile-time constant |

`slow main() -> i32` is the program's entry point. A value-returning slow
function needs a return on every path. Slow functions may call each other in
any order and recurse.

A record declared with a header is a C struct with C's layout. The unit
includes the header, and each declared scalar, pointer or scalar-array field
gets a `_Static_assert` that its C size matches. Function-pointer fields are
also checked. Other records have Rake's layout. A record can't contain
itself, directly or through other records.

`state` is a C static that keeps its value for the life of the process,
starting from a constant or zero. `embed` makes a file's bytes a read-only
`[]u8`, a 16-byte-aligned static. `const`
binds a compile-time value computed from literals, and vector code may use an
integer or float constant as a literal.

`extern slow` declares a C function from a header. Its parameters are
scalars, pointers, records passed by value and typed function pointers.

### Opaque C pointer types

An empty header-backed declaration preserves a C API's opaque typedef:

<!-- rake-check: frontend -->
```rake
record wasm_trap_t from "wasmtime.h" {}
record wasmtime_caller_t from "wasmtime.h" {}

extern slow inspect(caller: ptr wasmtime_caller_t) -> ptr wasm_trap_t from "wasmtime.h"
```

The header alone defines the type's layout. These types are used through
pointers, including exact pointee types in callback signatures, and by-value
use, record construction and empty Rake-owned records are rejected.

### C unions

A header-backed union's members all overlap the same storage, and C
determines its size, alignment and ABI. An ordinary slow parameter borrows a
union as it borrows a record, while an imported C parameter passes it by
value.

<!-- rake-check: frontend -->
```rake
union foreign_value_t from "values.h" {
  i32: i32;
  i64: i64;
  f64: f64;
  [16]u8: v128;
}

slow integer_value(value: i64) -> foreign_value_t:
  return foreign_value_t { i64: value }
```

A union literal selects exactly one member, and a field assignment changes the
active member. Rake adds no hidden tag and doesn't define reading an inactive
member, so read the member selected by the C API's protocol, such as a
neighbouring tag, and use a numeric `bitcast` for an equal-width bit
conversion. Reading
the wrong member, or keeping a pointer after its storage ends, is the
caller's responsibility.

Aggregate identifiers may keep a C typedef's lowercase spelling, and members
may use primitive spellings such as `i32`, as in `value.i32`. The generated C
checks that the header declares a union whose declared members overlap at
offset zero with matching sizes. The interpreter rejects C union storage,
which has no platform C layout, and Rake-owned union layouts remain work in
progress.

## Types

| Type | Meaning |
| --- | --- |
| `i8` … `u64`, `f32`, `f64`, `bool` | scalars |
| `[N]T` | an array of `N >= 1` elements held by value |
| `[]T` | a view: a borrowed run of elements with an `i32` count |
| `ptr T` | a C pointer, for extern interoperation |
| `ptr const T` | a C pointer through which the pointed-to object is read-only |
| `ptr ()` | an opaque C `void *` |
| `slow(T, ...) -> U` | a typed C function pointer |
| `Name` | a record |
| `stack Name` | a stack: its count and a view of each column |
| `mut T` | in a parameter list: a view, array or record writable by the callee |

Arrays and records are values, so binding or assigning one copies it, while
views and pointers refer to existing storage. A slow parameter of array or
record type is passed by reference and is read-only unless declared `mut`, in
which case its argument needs to be a writable location in the caller. A view
parameter is passed by value and is writable through when declared `mut []T`.

Slow code holds individual packs as ordinary records and has no rack or mask
values. It builds a stack from writable views or arrays, one for each of the
pack's fields, as in `stack Samples { value: values, quality: qualities }`,
and [moves and copies](02_packs_and_run.md#moves-and-copies) defines its
count, columns, moves and copies. Slow functions can't take or return stacks.

## Statements

| Form | Meaning |
| --- | --- |
| `let name = e`, `let name: T = e` | immutable binding |
| `name := e`, `name: T := e` | mutable binding |
| `place <- e` | assign a variable, state, field or element |
| `if c:` … `else if c:` … `else:` | conditional |
| `while c:` | loop |
| `for i from a up to b:`, `... by s:` | counted loop over `a <= i < b` |
| `break`, `continue` | inside a loop |
| `return`, `return e` | leave the function |
| `e` | a call evaluated for its effect |

A name is bound once in its scope and can't shadow an enclosing binding or a
module definition. A counted loop's index is `i32` unless declared otherwise.
Its step needs to be positive, and the loop stops at the bound without
stepping past it, so the index can't overflow.

## Expressions

Operands of an arithmetic or comparison operator have one type, because there
are no implicit conversions. A literal takes the type of the operand beside it
or the type expected in its position, and otherwise has type `i32` and needs
to fit its range.

Integer `+`, `-`, `*`, `/`, `%` and negation are checked: overflow, division
by zero and the most negative value divided by `-1` trap. `%` is integer
remainder, truncating as C does. `wrap_add`, `wrap_sub` and `wrap_mul` wrap
explicitly. Float arithmetic is IEEE 754 in the operand's precision.

| Form | Meaning |
| --- | --- |
| `T(x)` | a checked conversion, which traps unless the value fits `T`. A float converts to an integer toward zero, and an integer to a float to nearest |
| `wrap(T, x)` | the low bits of an integer, as integer type `T` |
| `bitcast(T, x)` | the same bits as a numeric type of the same width |
| `if c then a else b` | evaluates `c`, then only the chosen branch |
| `a[i]` | checked element: traps unless `0 <= i < count` |
| `a[unchecked i]` | element at `i`, with bounds checked by the caller |
| `r.field`, `p.field` | a record's field, directly or through a pointer |
| `Name { field: e, ... }` | a record literal specifying every field |
| `[a, b, c]`, `[e; n]` | array literals |
| `"text"` | a string literal, only as an extern's `ptr const u8` or `ptr const i8` argument |

Slow code's built-in functions:

| Functions | Meaning |
| --- | --- |
| `sqrt` `exp` `log` `log2` `tanh` `floor` `ceil` | of floats |
| `abs` `min` `max` | of any number |
| `bit_not` `bit_and` `bit_or` `bit_xor` `bit_andnot` | of integers |
| `shift_bits_left` `shift_bits_right` `shift_bits_right_signed` `rotate_bits_left` `rotate_bits_right` | the count taken modulo the operand's bits |
| `count_leading_zeros` `count_trailing_zeros` `popcount` | of integers |
| `wrap_add` `wrap_sub` `wrap_mul` | integer arithmetic that wraps |
| `count(v)` | the elements of a view or array |
| `slice(a, start, count)` | a checked subview |
| `unchecked_view(p, count)` | a view of a pointer's elements |
| `addr(place)`, `is_null(p)` | a pointer to a location, and a test for null |

A pointer carries no bounds, so it's always indexed `p[unchecked i]`.

`exp`, `log`, `log2` and `tanh` are fixed sequences of binary32 operations
(Cephes' single-precision polynomials), the same in slow code, in racks and in
the interpreter, so every target agrees bit for bit. Float `min` and `max` of
a NaN give a NaN. Of two zeros, `min` gives negative zero if either is, and
`max` positive zero if either is.

### Read-only pointers

`ptr const T` corresponds to `const T *`. It prevents writes through that
pointer, although another writable alias may still change the same object,
and an immutable `let` binding separately prevents replacing the pointer
itself.

`addr(place)` produces a writable pointer when the location is writable and a
read-only pointer otherwise. Taking the address of a checked element checks
its bounds immediately. A writable pointer may be borrowed as `ptr const T`,
but nested pointer types need to match exactly at every deeper level, so a
pointer to writable pointers can't implicitly become a pointer to read-only
pointers.

`unchecked_view` and erasure through `ptr ()` or `ptr const ()` preserve a
pointer's access, so a view formed from `ptr const T` is `[]T`. A writable
view may be borrowed as `[]T`. The caller is responsible for a pointer's
lifetime, bounds and alignment.

<!-- rake-check: run 11 -->
```rake
slow read(value: ptr const i32) -> i32:
  return value[unchecked 0]

slow main() -> i32:
  value: i32 := 7
  let borrowed: ptr const i32 = addr(value)
  value <- 11
  return read(borrowed)
```

## Function pointers and callbacks

`slow(i32) -> i32` is a C function pointer to a function taking an `i32` and
returning an `i32`, and `-> ()` declares a callback returning C `void`.
Function-pointer arguments and results use the platform C ABI and may be
scalars, data pointers, other function pointers or C aggregates passed by
value.

`addr(function)` takes the address of a slow function or an imported C
function. A callback carries no captured variables, so its context is passed
explicitly. For an opaque C context, `ptr ()` corresponds to `void *` and
`ptr const ()` to `const void *`, and callback signatures keep these
qualifiers in imported and exported C declarations.
`bitcast(ptr (), pointer)` erases a data pointer's type, and
`bitcast(ptr Context, opaque)` restores it. When accessed, the context needs
to remain alive and have the restored type and alignment.

<!-- rake-check: run 12 -->
```rake
record Context {
  i32: total;
}

slow add(opaque: ptr (), value: i32) -> i32:
  let context = bitcast(ptr Context, opaque)
  context.total <- context.total + value
  return context.total

slow apply(callback: slow(ptr (), i32) -> i32, context: ptr ()) -> i32:
  return callback(context, 8)

slow main() -> i32:
  context: Context := Context { total: 4 }
  return apply(addr(add), bitcast(ptr (), addr(context)))
```

Function pointers can be stored in records, arrays and module state, returned
from functions and passed between C and Rake. A binding is called as
`callback(arguments)`, and a record field is bound first, as in
`let callback = hooks.callback`. A zero-initialised function pointer is null,
so `is_null(callback)` detects it, and calling it traps.

Ordinary slow aggregate parameters borrow through Rake's own convention, so a
slow callback that accepts a record or array needs an explicit `ptr T`
parameter. `addr(main)` is rejected because the process entry has a
compiler-generated startup adapter. Function pointers can't be converted to
data pointers, and slow code has no closures or lambdas.

## Calling vector code

Slow code calls a stack run as an expression returning its result's stack, a
general run as a statement, and a scratch or rake as an expression:

<!-- rake-check: run 7 -->
```rake
scratch score(<x: f32>, <y: f32>) -> f32:
  extract(<x> * <y> + <1.0>, 0)

slow main() -> i32:
  let a = 2.0
  let b = 3.0
  let best = score(<a>, <b>)
  return i32(best)
```

Views and stacks are passed bare, and an array passed where a view is
expected lends all its elements. Every scalar argument is marked `<...>`, as
in `<name>`, `<3>`, `<record.field>` or `<view[index]>`, because it becomes a
rack in the callee. Slow code can call a scratch or rake only when all its
parameters are uniform and its result is a scalar.

## The explicitness rules

- Slow code can't name, hold, pass or return a rack, mask or rack array.
- Slow code reaches vector work only by calling a run, or a scratch or rake
  with uniform parameters, and every scalar that becomes a rack is marked
  `<...>` at the call. A `<...>` mark anywhere else in slow code is an error.
- Outside a slow block, vector code can't call slow code or an extern, and
  can't read module state.
- Inside vector code, uniform scalars are marked at their declaration and
  use, broadcasts are explicit, and a computation that can't stay in the
  target's racks is rejected.
- A run may keep a rack alive across a slow block, but the block can't
  capture it or turn it into scalar lanes.
- Slow code can't appear in a fused binding.
- Slow code's `if` is scalar control flow around vector calls and never
  selects lanes, which remains the job of tines, `through`, sweeps and mask
  `if`s.

Scratches, rakes and runs in a whole program get the same selection, C
emission, checks and object verification as in any other program, and slow
code is plain C beside them.

## Executable semantics

`rakec --interpret` defines what a whole program means, independently of its
C. It runs slow code over values, copying records and arrays and aliasing
views and pointers. It traps where the C traps: checked arithmetic,
conversions, indexing, slices and the counts at run calls, and only the frame
stack's limit is missing. The interpreter evaluates a run's rack
expressions in the same reference semantics as scratches. An extern has no
implementation there, so programs that call C are tested through C.

## The C unit

Ordinary slow functions have external C linkage, including on WebAssembly, so
independently compiled C can call them. A parameterless entry is
`int main(void)`. Records, arrays and views are structs, state and embedded
data are statics, and each run is an external, never-inlined `void` function.
Checked operations call `__builtin_trap`.

On the native path, slow functions use the platform C ABI. Scalar and pointer
arguments pass by value, array and record arguments are borrowed pointers, and
record results return by value. Header-backed records and unions keep their C
layout, including native pointer widths and padding. Module state is
process-wide and needs the caller's usual synchronization when several
threads use it.

A slow block in a run becomes a never-inlined scalar helper that takes
captured uniforms as scalars and captured views as pointer/count pairs, so
the run needs no C stack frame.

A slow function's aggregate locals form one frame. Frames of at most 256
bytes stay on the host stack, and larger ones use Rake's bounded arena, which
lives in linear memory on WebAssembly and is thread-local on native targets.
On WebAssembly this keeps large locals off the C stack, because wasm-ld places
its default 64 KiB stack after static data, where an overflow would overwrite
that data without a trap.
`RAKE_FRAME_BYTES` sets its capacity, 4 MiB unless defined otherwise when
compiling the C, and alignment padding counts against it. Each call releases
its frame on normal return, after copying any returned value. Running out of
capacity or failing to allocate a thread's arena traps. Nonlocal exits such as
C `longjmp` bypass frame cleanup and are unsupported across active Rake
frames.

## Verification

For a native mixed program, `--emit-obj` and `--verify-native` both check each
embedded register kernel and native stack run in the final object. The
ordinary slow functions keep the platform compiler's C semantics and aren't
held to these instruction checks. A slow-only unit uses `--emit-obj`.

On WebAssembly, `rakec --verify-native` compiles and disassembles the unit.
Every scratch and rake needs to use only locals, constants and register SIMD.
A run may call only the scalar helpers for its explicit slow blocks, matched
by each call's relocation, and the verifier rejects every other call,
indirect or tail calls, and `global.get` or `global.set`. A run therefore has
no C stack frame, and no rack passes through unnamed memory. Each SIMD
instruction needs to come from instruction selection for its source
operations or be one of Clang's documented substitutions:

- constants folded into `v128.const`
- splats of loads turned into splatting loads
- zero- and sign-extending loads
- a signed or unsigned twin
- a reversed or complemented comparison
- an add for a subtraction of a constant or a doubling
- scalar float arithmetic computed in a vector lane

A run also may have no more lane extractions and replacements, and no more
loops, than its source states. Slow code is scalar and exempt from these
rules, so Clang may use SIMD moves to copy its aggregates.
