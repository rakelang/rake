# Changelog

A Rake version identifies one compiler, Tree-sitter grammar, documentation set and
website. Beta releases may still change the source language and the binary
boundaries between versions. A design in the documentation gets a version
only when the compiler implements it and the tests cover it.

## Unreleased

- Extend native `f32` streams to AVX-512F: sixteen-lane racks, masked
  loads and stores, and inactive-input sanitisation. Independent C and
  guard-page checks exercise one, two and four columns on both x86 stream
  profiles, including every tail remainder and exact in-place output.
- Place slow-local aggregate frames using their actual C size and alignment,
  including header-backed records nested in arrays and Rake records. Small
  frames retain aligned host-stack storage. Arena padding is reclaimed on
  return, and independent small-stack checks cover 64-byte-aligned C objects.
- Native large-local arenas allocate on entry and free on the outermost
  framed return. Only a pointer and cursor occupy TLS, allowing host runtimes
  to use small worker stacks. Independent pthread checks cover recursive
  locals, C callback re-entry, returned records and repeated calls.
- Define typed global tines with explicit rack and uniform parameters, and
  apply them in local tines, through blocks and sweeps. `gaps` complements a
  tine or composed mask, including unordered floating-point lanes.
  Through fallbacks are optional: without `else`, reading an undefined lane
  is a compile error. Sweeps may omit `_` when Boolean mask coverage is
  provably total. Physical and WebAssembly lowering retain their existing
  predication and inactive-input safety obligations.
- Support opaque header-backed C typedefs through typed pointers, including
  callback signatures. Reject by-value opaque objects and their construction.
- Compile the AVX2 `f32` stream traversal subset as complete Rake-selected
  assembly, with masked tails and exact final-function verification.

- Rename `crunch` to `scratch`, without retaining the old keyword. `pack`
  now defines one scalar record. `stack PackType` describes its columnar
  collection, constructed as `stack PackType { field: column }`. Runs consume
  those columns a rack at a time. The compiler, grammar, examples and tutorial
  use the same hierarchy.

- Header-backed C unions have overlapping storage, one-member literals,
  field access, borrowed arguments and by-value C calls/results. Lowercase
  C typedefs and primitive-spelled members retain their header identifiers.
  The platform compiler supplies layout and ABI. Independent C checks cover
  nested structs, arrays and callbacks on CPU profiles and WebAssembly.
  Interpreted union storage and Rake-owned union layouts remain WIP.
- Slow pointers distinguish writable `ptr T` from read-only `ptr const T`.
  C declarations retain their pointee qualifiers, including callback
  signatures. Address-taking, view borrowing and opaque pointer casts
  preserve read-only access. The interpreter now retains location identity
  through scalar and aggregate assignment, so pointers observe later writes.
  Taking a checked element's address also checks bounds in the interpreter.
- Slow code supports typed C function pointers, noncapturing callbacks and
  opaque `ptr ()` contexts. `addr(function)` forms a callback, and data
  pointers can be erased or restored through `bitcast(ptr T, pointer)`.
  Native and WebAssembly calls use the platform C ABI, with null indirect
  calls trapping.
- A process entry may take `argc: i32, argv: ptr ptr u8`. Native C and WASI
  startup pass the count, zero-terminated byte strings and trailing null
  pointer through a compiler-owned typed adapter. The interpreter accepts
  arguments after `--` and uses the input path as `argv[0]`.
- Native slow-only programs emit platform C and compile to x86-64 or
  AArch64 objects. Their public slow functions use the platform C ABI,
  with header-backed struct imports, pointer parameters and struct returns.
  Native runs and packs remain work in progress.
- Native mixed programs embed Rake-selected register assembly in their C
  unit. Slow callers use uniform `f32` parameters and `f32` results, and
  both object modes check the kernels in the final compiled object. Other
  scalar kernel boundaries remain work in progress.
- The interpreter accepts an explicit target profile for reference `f32`
  rack widths. The browser emits native mixed C and interprets it at that
  profile's width; it does not execute native machine code.
- Native slow frames are thread-local; independent host threads can call
  exported functions with large recursive locals. Module state stays shared.
- Pointer fields in C struct declarations are checked against
  `sizeof(void *)`, rather than assuming a wasm32 pointer.
- Slow scalar bit casts use an alias-safe byte copy, shared by the native
  and WebAssembly C paths.

## 0.6.0-beta

- SSE2 and AVX-512F compile float scratches and rakes to verified vector
  kernels alongside AVX2 and NEON. Rack widths are four, sixteen, eight and
  four binary32 lanes respectively. Native pack traversal and whole programs
  remain work in progress.
- Native target detection selects AVX-512F, AVX2 with FMA, or SSE2 on x86.
  SSE2 rejects explicit single-rounded `fma` because that instruction is
  absent from its ISA. The AVX-512 profile requires AVX-512F only.
- Scratches end with their result expression, without `return`. Tines use
  `means` instead of `when`. These are breaking source-language changes.
- The browser tutorial offers all five implemented vector profiles for
  kernel inspection. Execution and whole-program lessons use WebAssembly.
- Tree-sitter preserves a function body across comment-only lines, including
  comments beginning at the left margin.
- The introduction explains the notation in sequence, with compound masks
  and a diagram of a 600-record pack. The reference page is now titled
  Primitives, operations, and targets.

## 0.5.0-beta

- Rakes end with `sweep:`, without `return`. This is the rake's result form.
  `return` remains the result of a scratch and an exit from a slow function.
  Compiler examples, Tree-sitter and the browser tutorial use the new form.
- `slow { ... }` is a scoped scalar escape in runs and slow functions. It
  supports scalar loops, calls, state and memory views, nesting and a scalar
  tail result. Rack values can't cross the boundary. WebAssembly object
  verification permits only the helper calls selected by these explicit
  blocks, and keeps the surrounding vector checks.
- Tree-sitter and the browser tutorial recognise and teach slow blocks.

## 0.4.0-beta

Changes since 0.3.0.

### Language and compiler

- Named target profiles fix rack widths. `x86-avx2` and `aarch64-neon`
  compile `f32s` scratches and rakes to assembly, and `wasm-simd128` compiles
  scratches, rakes, runs and whole programs to C with one `wasm_simd128.h`
  intrinsic for each selected instruction.
- `rakec --print-capabilities` reports each language feature's status, and
  each profile rejects what it can't compile with the source location and the
  missing operation.
- Rakes have defined inactive lanes on every profile: benign operands on x86
  and AArch64, and none needed on WebAssembly, which has no floating-point
  exception state. A sweep needs one final `_` arm, and its arms' order is
  its priority.
- Fused bindings are pure contiguous data flow. Their identifiers are substituted
  before fused multiply-adds are formed on AVX2 and NEON, and `fma` keeps its
  single rounding. A fused stage may now introduce a constant or choose by a
  mask, and fused bindings inside a through block form regions of their own.
- Pure instructions that nothing uses are removed before instruction
  selection, so a scratch's `repeat` compiles on AVX2 and NEON.
- `wasm-simd128` adds:
  - integer racks, `u8s`, `i16s`, `i32s`, `u32s`, `i64s` and `u64s`, with
    wrapping arithmetic, comparisons, `min` and `max`, bitwise operations and
    bit shifts,
  - `dot`, `narrow`, `widen_low`, `widen_high`, `to_f32` and `to_i32`,
  - float `min`, `max`, `abs` and rounding,
  - one- and two-rack shuffles, `bitmask`, `extract`, `insert`, `all` and
    `any`, and
  - strict reductions and scans, which AVX2 also compiles.
- `exp`, `log`, `log2` and `tanh` are fixed sequences of binary32 operations,
  shared by the interpreter, slow code and racks.
- Conditional expressions choose by a mask on every profile, and by a
  uniform on `wasm-simd128`.
- A uniform must be marked where it meets a rack: `values * <factor>`, not
  `values * factor`. The type checker reports the unmarked name.
- `wrap` and `bitcast` are conversions only before a parenthesis, so they
  remain usable as identifiers. A scratch, rake or run can't be named after a C
  keyword, since each becomes a C function of its own name.
- A rake's through block and its sweep compile to one select, since a select
  whose arm selects on the same mask takes that arm directly.
- `rakec --print-capabilities` marks `let` expressions, `is` comparisons and
  expression predicates unavailable, since no source syntax reaches them.
- `!=` on floats is ordered everywhere: it is false when either operand is
  NaN, for scalars as for racks.
- Number literals are unsigned, and a minus before one makes it negative, so
  `n-1` subtracts.
- Runs on `wasm-simd128` traverse packs, with tails that load and store lane
  by lane and never touch an element past the count. They have nested
  traversals, counted loops, `repeat` and uniform `if`, rack locations and
  arrays of them, checked and unchecked loads, stores and gathers, and
  scratches and rakes inlined with their masks. Rake forms each loop's
  addresses and checks bounds once before the loop. Runs have a published
  wasm32 C boundary.
- A run's uniform arithmetic may use reductions, extractions, bitmasks and
  scratch calls, each computed as a uniform of its own.
- Slow code on `wasm-simd128`: records, arrays, views, pointers, module
  state, embedded files, constants, control flow and calls to C, compiled
  with the runs into one C file with `int main(void)`. Aggregates over 256
  bytes live in a frame stack in linear memory instead of the 64 KiB C stack,
  which they overflowed without a trap.
- `rakec --interpret` runs a program's `main` in Rake's executable
  semantics. It reports a program without `main` instead of failing, and
  broadcasts a uniform stored where a rack goes, as the compiled code does.
- The compiler library exposes the front end, interpreter, C and assembly
  emitters, and a bounded lane trace to the browser through `js_of_ocaml`.
  The browser build runs in a worker and returns source diagnostics without
  requiring a server-side compiler.
- `wasm-simd128-relaxed` is an opt-in profile with `relaxed_madd`,
  `relaxed_nmadd`, `relaxed_min` and `relaxed_max`.

### Verification

- `--verify-native` disassembles every object. On x86 and AArch64 it rejects
  calls, stack use, split or scalarised racks, instructions outside the
  profile's list and a wrong count of fused multiply-adds, and it accepts the
  two-byte nop that pads an AVX2 function. On `wasm-simd128` a scratch may hold
  only register instructions, including the scalar arithmetic clang makes of
  splat arithmetic, and a run only the vector instructions its source selects
  or their documented equivalents.
- `test/program_test.sh` compares every program fixture in the interpreter
  and as WebAssembly under wasmtime, and `test/abi_test.sh` calls runs from C.
  `test/neon_backend_test.sh` compares NEON results under QEMU.
- The compiler's parser and the Tree-sitter grammar are compared over the
  test corpus. The grammar parses indentation with an external scanner, as
  the compiler does.
- Every Rake example in the README, the documentation and the website is
  compiled by `tools/check_documentation_examples.sh`, and most are run.

### Website and documentation

- rake-lang.org now publishes the compiler documentation as a checked set of
  reference pages with Tree-sitter highlighting.
- The playground is an interactive twelve-lesson tutorial. It runs the same
  compiler and interpreter in the browser, shows rack values in the Lanes tab,
  and displays generated C or assembly beside source diagnostics.

### Removed

- The experimental MLIR and LLVM lowering and its command-line modes.
- The toolchain-generated memref C wrapper for runs.
