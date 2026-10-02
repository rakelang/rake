# The slow tier and whole programs

A Rake program can hold its scalar orchestration as well as its vector
kernels. Slow code is that orchestration: records, arrays, module state,
embedded data, control flow, and calls to C. It is ordinary scalar code and is
marked `slow` so that nobody mistakes it for vector code. A `slow { ... }`
block is a lexical escape inside a run, like Rust's explicit `unsafe { ... }`
boundary. The surrounding rack work retains its vector contract. A whole
scalar function can instead be declared `slow name(...)`.

Slow blocks are available in 0.5.0-beta and in the playground.

A program with any slow, run, record, state, embed, const or extern
definition is a whole program. On `wasm-simd128` it compiles to one C
translation unit with a C entry point, which is what a C-only judge takes.
Whole programs are implemented for `wasm-simd128` and
`wasm-simd128-relaxed` in the 0.6.0-beta tag. The unreleased development
compiler also emits native C and objects combining slow orchestration and
register kernels on x86-64 and AArch64. Native runs and packs remain work in
progress.

### Native kernel calls

On the development compiler, a native register kernel called from slow code
takes uniform `f32` parameters and returns `f32`. Rake selects and allocates
the kernel's instructions. The generated C contains its opaque assembly,
and the final object is checked against the selected profile. The platform C
compiler lowers the slow caller and supplies the scalar calling convention.
Other native scalar kernel boundaries remain work in progress.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
crunch carry(<value: f32>) -> f32:
  <value>

slow main() -> i32:
  return i32(carry(<3.5>))
```

This example preserves the value across the boundary and returns `3`. A
kernel may also broadcast its uniforms and reduce a rack where the selected
profile supports those operations. The reference interpreter uses the chosen
profile's rack width when `--target` is supplied.

### Process arguments

The development compiler after 0.6.0-beta accepts either `slow main() -> i32`
or a process entry with an argument count and a pointer to byte strings:

<!-- rake-check: run 1 -->
```rake
slow main(argc: i32, argv: ptr ptr u8) -> i32:
  if is_null(argv[unchecked argc]):
    return argc
  return 255
```

`argc` includes the program at `argv[0]`. Each string ends with a zero byte,
and `argv[argc]` is a null pointer. These are byte strings, so a UTF-8
character may occupy several bytes. Pointer indexing is explicitly
`unchecked`: the program must stay within the count and each string's end.

The emitted entry has C's `int main(int argc, char **argv)` signature. A
compiler-generated adapter copies the pointer array into typed `ptr u8`
storage, sharing the original string bytes. The adapter frees that array when
`main` returns, so don't retain its address beyond the call. This avoids
reading a C `char **` object through an incompatible pointer type. Linking
this entry requires the platform C runtime, or WASI libc on WebAssembly.

For the interpreter, pass arguments after `--`, as in `rakec --interpret
program.rk -- alpha --flag`. Its `argv[0]` is the input file path. The browser
interpreter supplies `program` at `argv[0]` and no additional arguments.

## An example

<!-- rake-check: run 33 -->
```rake
stack Samples {
  f32: value;
  u8: quality;
}

run weigh(input: pack Samples, <count: i64>, <scale: f32>) -> f32:
  for chunk in input using f32s up to <count>:
    let quality = to_f32(bitcast(i32s, widen(chunk.quality)))
    yield chunk.value * <scale> + quality

run running_sum(x: []f32, out: mut []f32, <n: i32>):
  total := <0.0>
  for <i: i32> from <0> up to <n> by <4>:
    total <- total + x[<i>]
    out[<i>] <- total

state calls: i32 := 0

slow main() -> i32:
  values: [8]f32 := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
  qualities: [8]u8 := [0, 1, 0, 1, 0, 1, 0, 1]
  weighed: [8]f32 := [0.0; 8]
  weigh(Samples { value: values, quality: qualities }, <8>, <0.5>, weighed)
  sums: [8]f32 := [0.0; 8]
  running_sum(weighed, sums, <8>)
  calls <- calls + 1
  return i32(sums[7] * 4.0) + calls
```

`rakec --interpret program.rk` runs `main` in Rake's executable semantics and
prints its result. `rakec --emit-asm --target wasm-simd128 -o program.c
program.rk` writes the C unit, and `--verify-native` compiles it and checks
every crunch, rake and run in the object (see [Verification](#verification)).

## Slow blocks

Enter scalar code at `slow {`, and return to the enclosing mode at `}`. A
block can contain scalar loops, calls, records, arrays and access to module
state. Its last expression produces a scalar value. A final semicolon
discards that value, and a block without a final expression produces nothing.

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

The scalar loop produces 0 + 1 + 2 = 3. One vector add then shifts the four
lanes to 4, 5, 6 and 7, whose sum is 22. Inside the block, `steps` is a bare
scalar name. Outside it, `<offset>` explicitly broadcasts the result.

Blocks have lexical scope and may nest. Their locals end at `}` and can't
shadow an enclosing binding, though sibling blocks may reuse a name. A block
inside a slow function shares that function's mutable locations. A block in a
run can read its uniforms and scalar-element views, and write a mutable view.
It can't name a rack, mask, rack array or traversal chunk. Reduce or extract a
rack to a uniform before entering the block. Block results are scalar or
void, so a local array, record or borrowed view can't escape through the result.

On one line, separate statements with semicolons: `slow { let x = 2; x + 1 }`
produces 3. Multiline bodies use the same indentation as other Rake bodies.
`slow {}` is empty. A `return` inside a slow function's block returns from
that function, as in Rust. Runs have no early `return`: use the block's final
expression to produce its result. In a run, `break` and `continue` inside a
block refer only to scalar loops inside that block.

Crunches, rakes and fused regions remain pure vector kernels and reject slow
blocks. Put scalar orchestration in the run that calls them. Blocks and whole
programs with memory runs currently compile for WebAssembly only. The
development compiler also supports native slow functions and register kernels.

## Definitions

| Definition | Meaning |
| --- | --- |
| `slow name(parameters) -> T:` | a scalar function, with or without `-> T` |
| `extern slow name(parameters) -> T from "header.h"` | a C function |
| `record Name { T: field, field; }` | a record with Rake's layout |
| `record Name from "header.h" { T: field; }` | a C struct |
| `state name: T := constant`, `state name: T` | module state |
| `embed name from "file"` | a file's bytes |
| `const name: T = constant` | a compile-time constant |

`slow main() -> i32` is the program's entry point. A slow function that
returns a value must return on every path. Slow functions may call each other
in any order and recurse.

A record declared with a header is a C struct whose layout C owns: the unit
includes the header, and each declared scalar, pointer or scalar-array field
gets a `_Static_assert` that its C size matches. Function-pointer fields are
also checked in the development compiler. Other records have Rake's
layout. A record can't contain itself, directly or through other records.

`state` is module state: a C static that holds its value for the life of the
process, across turns of a judge's loop. Its initial value is a constant, or
zero. `embed` makes a file's bytes a read-only `[]u8`, a 16-byte-aligned
static. `const` binds a compile-time value computed from literals. Vector code
may use an integer or float constant as a literal.

`extern slow` declares a C function from a header. Its parameters are
scalars, pointers and records passed by value. The development compiler also
accepts typed function pointers.

## Types

| Type | Meaning |
| --- | --- |
| `i8` … `u64`, `f32`, `f64`, `bool` | scalars |
| `[N]T` | an array of `N >= 1` elements held by value |
| `[]T` | a view: a borrowed run of elements with an `i32` count |
| `ptr T` | a C pointer, for extern interoperation |
| `ptr ()` | an opaque C `void *`, available in the development compiler |
| `slow(T, ...) -> U` | a typed C function pointer, available in the development compiler |
| `Name` | a record |
| `mut T` | in a parameter list: a view, pack, array or record the callee writes |

Arrays and records are values: binding or assigning one copies it. Views and
pointers alias the storage they name. A slow parameter of array or record type
is passed by reference and is read-only. `mut` makes it writable, and the
argument must then be a location the caller may write. A view parameter is
passed by value and is writable through when declared `mut []T`.

Slow code has no rack, mask or pack values. A pack exists only as the argument
of a run call, written as a record literal of the stack whose fields are
views: `Samples { value: values, quality: qualities }`.

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

A name is bound once in its scope. It can't shadow an enclosing binding or a
module definition. A counted loop's index is `i32` unless declared, its step
must be positive, and it stops at the bound rather than stepping past it, so
the index never overflows.

## Expressions and their meaning

Operands of an arithmetic or comparison operator have one type: there are no
implicit conversions. A literal takes the type of the operand beside it or the
type expected where it stands. An integer literal elsewhere is `i32` and must
fit.

Integer `+`, `-`, `*`, `/`, `%` and negation are checked: overflow, division
by zero and the most negative value divided by `-1` trap. `%` is integer
remainder, truncating as C does. The wrapping operations are explicit:
`wrap_add`, `wrap_sub` and `wrap_mul`. Float arithmetic is IEEE 754 in the
operand's precision.

| Form | Meaning |
| --- | --- |
| `T(x)` | a checked conversion, which traps unless the value fits `T`. A float converts to an integer toward zero, and an integer to a float to nearest |
| `wrap(T, x)` | the low bits of an integer, as integer type `T` |
| `bitcast(T, x)` | the same bits as a numeric type of the same width |
| `if c then a else b` | evaluates `c`, then only the chosen branch |
| `a[i]` | checked element: traps unless `0 <= i < count` |
| `a[unchecked i]` | element under the caller's promise that `i` is in bounds |
| `r.field`, `p.field` | a record's field, directly or through a pointer |
| `Name { field: e, ... }` | a record literal naming every field |
| `[a, b, c]`, `[e; n]` | array literals |
| `"text"` | a string literal, only as an extern's `ptr u8` or `ptr i8` argument |

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

A pointer is always indexed `p[unchecked i]`, because it carries no bounds.

`exp`, `log`, `log2` and `tanh` are fixed sequences of binary32 operations
(Cephes' single-precision polynomials), the same in slow code, in racks and in
the interpreter, so every target agrees bit for bit. Float `min` and `max` of
a NaN give a NaN. Of two zeros, `min` gives negative zero if either is, and
`max` positive zero if either is.

## Function pointers and callbacks

The development compiler after 0.6.0-beta supports C function pointers in
slow code. Write `slow(i32) -> i32` for a pointer to a function taking an
`i32` and returning an `i32`. Write `-> ()` for a callback returning C
`void`. Function-pointer arguments and results use the platform C ABI.
They may be scalars, data pointers, other function pointers or C structs
passed by value.

`addr(function)` takes the address of a slow function or an imported C
function. A callback carries no captured variables, so pass its context
explicitly. For an opaque C context, `ptr ()` corresponds to `void *`.
`bitcast(ptr (), pointer)` erases a data pointer's type, and
`bitcast(ptr Context, opaque)` restores it. The context must still be alive
and have the restored type and alignment when it is accessed.

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
from functions and passed between C and Rake. Call a binding as
`callback(arguments)`. For a record field, bind it first with
`let callback = hooks.callback`. A zero-initialised function pointer is
null. `is_null(callback)` checks it, and calling it traps.

A slow callback with a record or array parameter must use an explicit
`ptr T` parameter. Ordinary slow aggregate parameters borrow through Rake's
own convention. `addr(main)` is rejected because the process entry has a
compiler-owned startup adapter. Function pointers cannot be converted to
data pointers, and this stage adds no closures or lambdas.

The C emitter uses typed function-pointer declarations and calls directly
through them. It delegates the slow ABI to the platform compiler, including
WebAssembly's indirect-call table. The interpreter invokes local callbacks
by their function identity. Imported C callbacks need the same external
implementation as a direct C call.

## Calling vector code

Slow code calls a run as a statement and a crunch or rake as an expression:

<!-- rake-check: run 7 -->
```rake
crunch score(<x: f32>, <y: f32>) -> f32:
  extract(<x> * <y> + <1.0>, 0)

slow main() -> i32:
  let a = 2.0
  let b = 3.0
  let best = score(<a>, <b>)
  return i32(best)
```

The run call in [the example](#an-example) above,
`weigh(Samples { value: values, quality: qualities }, <8>, <0.5>, weighed)`,
passes a pack, two uniforms and its output view.

Memory arguments, views and packs, are passed bare. An array passed where a
view is expected lends all its elements. Every scalar argument is marked
`<...>`, as in `<name>`, `<3>`, `<record.field>` or `<view[index]>`, because it
becomes a rack in the callee. A run declared `-> T` takes its output view as a last argument. A
crunch or rake is callable from slow code only when all its parameters are
uniform and its result is a scalar. Slow code can't pass or receive a rack.

At a run call, every column of a traversed pack, of a pack the traversal
stores into, and the output view must hold the traversal's count, or the call
traps before the run starts.

## The explicitness rules

- Slow code can't name, hold, pass or return a rack, mask or rack array.
- Slow code reaches vector work only by calling a run, or a crunch or rake
  with uniform parameters, and every scalar that becomes a rack is marked
  `<...>` at the call. A `<...>` mark anywhere else in slow code is an error.
- Outside a slow block, vector code can't call slow code or an extern, and
  can't read module state. Enter `slow { ... }` explicitly to do that work.
- Inside vector code the existing rules are unchanged: uniform scalars are
  marked at their declaration and use, broadcasts are explicit, and a
  computation the target can't keep in racks is rejected.

## How the tier keeps vector code's promises

- One rack is one `v128`. A run may keep that virtual value alive across a
  slow block, but the block can't capture it or turn it into scalar lanes.
  The WebAssembly runtime owns physical register allocation across the call.
- Fused regions stay pure. A fused binding is vector code. Slow code can't
  appear in it, and the tier adds no operation to the fused contract.
- Rakes stay predicated. Slow code's `if` is scalar control flow around
  vector calls. It never selects lanes. Lane selection remains a tine, a
  `through`, a sweep or a mask `if`.
- Scalars and broadcasts stay explicit. A scalar returned by a slow block
  meets a rack only at an explicit `<...>` broadcast.
- Properties are proved or rejected. Every crunch, rake and run in a whole
  program goes through the same checks and object verification as before, and
  slow code has its own checked semantics.
- Existing lowering is unchanged. Crunches and rakes are emitted by the same
  selection and C emission. A run's pure rack expressions become always-inline
  functions lowered through that same pipeline. Slow code is plain C beside
  them.

## Executable semantics

`rakec --interpret` defines what a whole program means, independently of its
C. It runs slow code over values, copying records and arrays and aliasing
views and pointers. It traps where the C traps: checked arithmetic,
conversions, indexing, slices and the counts at run calls. Only the frame
stack's limit is the C's alone. It evaluates a run's rack expressions in the
same reference semantics as crunches. An extern has no implementation there,
so programs that call C are tested through C (`test/abi/interop.rk`).

`test/program_test.sh` runs every `test/program/*.rk` in the interpreter and,
compiled from the emitted C in both addressings, under wasmtime, and requires
equal results. Programs under `test/program/trap/` must trap in both.
`test/abi_test.sh` calls runs from C across the [wasm32
boundary](02_packs_and_run.md#wasm32-boundary) and runs `interop.rk` against
its C functions.
`test/reject/slow_*.rk` and `test/reject/run_*.rk` show each explicitness rule
rejecting a program that breaks it.

## The C unit

Ordinary slow functions have external C linkage in the development compiler,
including on WebAssembly, so independently compiled C can call them. Extracted
block helpers remain internal. A parameterless entry is `int main(void)`,
and a process entry uses the adapter described above.
Records, arrays and views are structs. State and embedded data are statics.
Checked arithmetic, conversions, indexing and slices are small inline helpers
that call `__builtin_trap`. Each run is an external, never-inlined `void`
function.

On the development compiler's native path, slow functions use the platform
C ABI. Scalar and pointer
arguments pass by value, array and record arguments are borrowed pointers,
and record results return by value. Header-backed records retain their C
layout, including native pointer widths and padding. Rake emits checked
scalar C; the platform compiler owns its register allocation and calling
convention. This does not delegate vector kernel compilation to C.

Unions remain work in progress. Native slow frames are
thread-local, while module state remains process-wide and needs the caller's
normal synchronization when several threads use it.

A slow block in scalar code becomes a GNU C statement expression, preserving
its lexical scope and enclosing function's `return`. A block in a run becomes
a never-inlined scalar helper. Its captured uniforms are scalar parameters,
and its captured views are passed as pointer/count pairs, so the run needs no
C stack frame. Rack values never cross that helper boundary.

Slow functions keep aggregates larger than 256 bytes in Rake's frame stack: a
static region of `RAKE_FRAME_BYTES` bytes (4 MiB unless defined otherwise when
compiling the C) from which each call takes a frame and releases it on
return. Running out of it traps. The C stack holds only small values. The
reason is the judge's linker: wasm-ld places its default 64 KiB stack after
static data, so kilobyte-sized local arrays that overflow it grow down into
that data and overwrite it without a trap.

## Verification

For a native mixed program, both `--emit-obj` and `--verify-native` check each
embedded register kernel in the final object. The ordinary slow functions
retain the platform compiler's C semantics and are outside that vector
instruction contract. A slow-only unit uses `--emit-obj`.

On WebAssembly, `rakec --verify-native` compiles the unit and disassembles it. Every crunch
and rake must be locals, constants and register SIMD only. A run may call only
the scalar helpers emitted for its explicit slow blocks. The verifier checks
each direct call's relocation against those helper symbols. It rejects every
other call, indirect or tail calls, and `global.get` or `global.set` (so no C
stack frame, and no rack passing through memory Rake didn't name). Each SIMD
instruction in it must be one its source operations select, or one of the
documented equivalents Clang substitutes: constants folded into `v128.const`,
splats of loads into splatting loads, zero- and sign-extending loads, a
signed or unsigned twin, a reversed or complemented comparison, an add for a
subtraction of a constant or a doubling, and scalar float arithmetic computed
in a vector lane. It may have no more lane extractions
and replacements, and no more loops, than its source states. Slow code isn't
held to these rules: it is scalar, and Clang may use SIMD moves to copy its
aggregates.
