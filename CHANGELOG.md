# Changelog

A Rake version identifies one compiler, Tree-sitter grammar, documentation set and
website. Releases before 1.0 may still change the source language and the binary
boundaries between versions. A design in the documentation gets a version
only when the compiler implements it and the tests cover it.

## Unreleased

- Runs apply calculations to whole stacks. `run name(...) -> stack P` ends with
  `s with { field: e }`, optionally masked by `where p`, or `compact s where p`.
  The `for chunk in s using D up to <count>` traversal, `yield`, `mut stack`
  and nested traversals are removed. General runs over views remain.
- A stack moves into the run that returns it, which updates its columns in
  place. Reading a moved stack is a compile error, and `copy(s)` makes an
  explicit copy. Slow code reads `count(s)` and `s.field`.
- A call traps when its stacks' counts differ, or when the result's columns
  overlap other memory except element for element.
- Compaction compiles on every target, for 8-, 16- and 32-bit columns:
  `vcompressps` on AVX-512, `vpermps` on AVX2, `pshufd` on SSE2, `tbl` on NEON
  and `i8x16.swizzle` on WebAssembly.
- One native kernel computes every output of a rack, so shared values are
  computed once.
- Building stack runs prints a kernel report on standard error, with each
  run's domain, columns, selection method and tail transfers. `--no-report`
  omits it.
- Stack descriptors are `struct rake_stack_P_v2`: an `int64_t count` followed
  by the column pointers. The result's descriptor is writable, and a
  compaction writes its count there.
- `rakec --print-capabilities` reports each feature on every profile as
  compiled, compiled in part or unavailable, with the reason
  (`rake-capabilities-v3`). A profile rejects source using an unsupported
  feature, such as explicit `fma` on SSE2 and WebAssembly, in kernels, slow
  code and runs alike.
- Run expressions under `wasm-simd128-relaxed` lower with that profile, and
  whole programs with compaction or slow blocks pass its object verification.
- Native slow-frame arenas are allocated once per thread instead of on every
  outermost call.
- The interpreter evaluates integer literals beside a `u32` uniform, such as a
  `bitmask` result.

## 0.7.0

### Language

- `crunch` is renamed `scratch` (breaking). `pack` defines one record, and
  `stack PackType { field: column }` builds its columnar collection.
- Global tines take typed rack and uniform parameters. `gaps` complements a
  tine or composed mask. A through block's `else` is optional, and reading an
  undefined lane is a compile error. A sweep may omit `_` when its masks
  provably cover every lane.
- `<true>` and `<false>` are Boolean uniforms.
- Integer mask literals use their element's range, so `u32s` masks go up to
  4294967295. Typed calls check integer literals against the parameter's
  range.
- Integer bitwise built-ins and extrema accept a marked uniform in either
  operand.

### Integer racks

- On SSE2, AVX2, AVX-512F and NEON, `i32s` and `u32s` support wrapping
  arithmetic, bitwise operations and `bit_andnot`, signed and unsigned
  comparisons, `min` and `max`, and on `i32s`, `abs` and negation.
- Shifts take a literal count from 0 to 31 or a runtime `u32` count taken
  modulo 32.
- Static shuffles and literal-index `extract` and `insert` compile on the four
  physical profiles, but not yet in native streams.
- `sum`, `product`, `minimum`, `maximum` and their `scan_` forms accept `i32s`
  and `u32s` on every CPU profile.
- `bitcast` between `f32s`, `i32s` and `u32s` keeps every lane's bits.

### Float racks

- `abs`, `floor`, `ceil`, `trunc`, `nearest`, `min` and `max` compile on SSE2,
  AVX2, AVX-512F and NEON. `min` and `max` preserve NaNs and signed zero.
- Static shuffles and literal-index `extract` and `insert` compile on the four
  physical profiles.
- Comparison masks support `all`, `any` and `bitmask` on the four physical
  profiles.
- NEON compiles the float reductions and inclusive scans.
- Native code leaves floating-point control settings to the caller.

### Uniforms and conditions

- Native register kernels take `f32`, `i32`, `u32` and C `bool` uniforms and
  compute with them. Float arithmetic rounds to binary32 at each step, and
  integer arithmetic wraps to 32 bits. Arithmetic under a partial lane mask
  remains work in progress.
- On the four physical profiles, a conditional expression can choose a whole
  rack by comparing uniforms or by a Boolean uniform, including the result of
  `all` or `any`. Conditions compose with `and`, `or` and `not`.

### Conversions

- `to_u32`, and `to_f32` from `u32s`, compile on all five CPU profiles.
- Signed `to_f32` and `to_i32` compile on SSE2, AVX2, AVX-512F and NEON.
- Float-to-integer conversions round to nearest even, saturate and turn NaN
  into zero.

### Native streams

- Native streams traverse stacks on SSE2, AVX2, AVX-512F and NEON, reading one
  to four same-width `f32`, `i32` or `u32` columns, with guarded partial racks.
- `widen` reads `i8`, `i16`, `u8` and `u16` columns into 32-bit racks.
- A stream can update one column in place or write one column to a separate
  destination stack.
- Counts can be `i32` or `i64`, and up to eight `f32` uniforms and any `i32`,
  `u32` or `bool` uniforms follow the count.
- Stream bodies support local rack assignments, arrays of rack locations and
  unrolled `repeat`.
- Runtime-counted inner loops, cross-lane operations and general native runs
  remain work in progress.

### Slow code and C

- Native slow-only programs compile through platform C to x86-64 or AArch64
  objects, and their public functions use the platform C ABI.
- Native mixed programs embed Rake-selected kernel assembly in their C unit.
- Header-backed C unions, opaque C typedefs behind pointers, and read-only
  `ptr const T` pointers are supported.
- Slow code supports typed C function pointers and callbacks. `addr(function)`
  forms a callback, and a null indirect call traps.
- A process entry may take `argc: i32, argv: ptr ptr u8`, and the interpreter
  passes it the arguments after `--`.
- Native slow frames are thread-local, and large locals live in an arena, so
  host threads can call exported functions on small stacks.
- Pointer fields in C struct declarations are checked against
  `sizeof(void *)`.

### WebAssembly

- Object verification accepts narrower comparisons and extending multiplies
  when column types and literals bound the operands.
- Uniform choices, partial stores and unsigned comparisons stay packed, so the
  strict object verifier accepts them.
- Generated C no longer clashes with C keywords or its own temporaries.

### Tools

- `--emit-c` writes C for WebAssembly, native whole programs or native
  kernels, and `--emit-asm` writes physical-target kernel assembly.
- The interpreter takes a target profile for `f32` rack widths. It now clamps
  out-of-range float-to-integer conversions, keeps negative zero in `nearest`,
  and lets pointers observe later writes.
- The package's tests no longer need target assemblers or disassemblers.

## 0.6.0-beta

- SSE2 and AVX-512F compile float scratches and rakes alongside AVX2 and NEON.
- Native target detection selects AVX-512F, AVX2 with FMA, or SSE2 on x86.
  SSE2 rejects explicit `fma`.
- Scratches end with their result expression, without `return`, and tines use
  `means` instead of `when` (both breaking).
- The browser tutorial offers all five vector profiles for kernel inspection.
- Tree-sitter keeps a function body together across comment-only lines.
- The introduction explains the notation in sequence, and the reference page
  is titled Primitives, operations, and targets.

## 0.5.0-beta

- Rakes end with `sweep:`, without `return`.
- `slow { ... }` is a scoped scalar escape in runs and slow functions, with
  loops, calls, state, memory views and a scalar result. Rack values can't
  cross it.
- Tree-sitter and the browser tutorial support slow blocks.

## 0.4.0-beta

### Language and compiler

- Named target profiles fix rack widths. `x86-avx2` and `aarch64-neon`
  compile `f32s` scratches and rakes to assembly, and `wasm-simd128` compiles
  scratches, rakes, runs and whole programs to C intrinsics.
- `rakec --print-capabilities` reports each feature's status, and a profile
  rejects unsupported features with their source location.
- Rakes have defined inactive lanes on every profile. A sweep needs a final
  `_` arm, and its arms' order is its priority.
- Fused bindings are pure data flow, and AVX2 and NEON form fused
  multiply-adds from them. `fma` keeps its single rounding.
- A scratch's `repeat` compiles on AVX2 and NEON.
- `wasm-simd128` adds integer racks, `dot`, `narrow`, `widen_low`,
  `widen_high`, `to_f32`, `to_i32`, float `min`, `max`, `abs` and rounding,
  shuffles, `bitmask`, `extract`, `insert`, `all`, `any`, and strict
  reductions and scans, which AVX2 also compiles.
- `exp`, `log`, `log2` and `tanh` give the same binary32 results in the
  interpreter, slow code and racks.
- Conditional expressions choose by a mask on every profile, and by a uniform
  on `wasm-simd128`.
- A uniform needs angle brackets when used with a rack: `values * <factor>`.
- `wrap` and `bitcast` remain usable as identifiers. A scratch, rake or run
  can't be named after a C keyword.
- `!=` on floats is false when either operand is NaN.
- `n-1` subtracts, because number literals are unsigned and a minus makes one
  negative.
- Runs on `wasm-simd128` traverse packs with counted loops, `repeat`, uniform
  `if`, rack locations, loads, stores and gathers. Their tails never touch an
  element past the count, and they have a published wasm32 C boundary.
- A run's uniform arithmetic may use reductions, extractions, bitmasks and
  scratch calls.
- Slow code on `wasm-simd128` has records, arrays, views, pointers, module
  state, embedded files, control flow and calls to C, and compiles with the
  runs into one C file with `int main(void)`. Aggregates over 256 bytes live
  in a frame stack in linear memory.
- `rakec --interpret` runs a program's `main` in Rake's executable semantics.
- The compiler runs in the browser through `js_of_ocaml`.
- `wasm-simd128-relaxed` is an opt-in profile with relaxed multiply-add,
  `min` and `max`.

### Verification

- `--verify-native` disassembles every object and rejects calls, stack use,
  split or scalarised racks and instructions outside the profile.
- The Tree-sitter grammar parses indentation as the compiler does.
- Every Rake example in the README, the documentation and the website is
  compiled, and most are run.

### Website and documentation

- rake-lang.org publishes the compiler documentation as reference pages with
  Tree-sitter highlighting.
- The playground is a twelve-lesson interactive tutorial with a Lanes tab and
  the generated C or assembly beside diagnostics.

### Removed

- The experimental MLIR and LLVM lowering and its command-line modes.
- The toolchain-generated memref C wrapper for runs.
