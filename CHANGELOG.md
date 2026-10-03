# Changelog

A Rake version identifies one compiler, Tree-sitter grammar, documentation set and
website. Beta releases may still change the source language and the binary
boundaries between versions. A design in the documentation gets a version
only when the compiler implements it and the tests cover it.

## Unreleased

- `to_f32` accepts `u32s` on all five CPU profiles, in register kernels and
  streams. SSE2 and AVX2 convert two exactly represented 16-bit halves
  before one rounded addition. AVX-512F, NEON and WebAssembly select
  unsigned vector conversion instructions. The integer-bit oracle checks
  rounding across bit 31, retained inputs, masked exceptions, compact
  widening and guarded stream tails. Generated WebAssembly C explicitly
  discards unused ABI parameters, including unneeded tail masks, so strict
  unused-parameter warnings remain enabled.

- Signed `to_f32` and `to_i32` compile on SSE2, AVX2, AVX-512F and NEON,
  in register kernels and streams. Packed operations preserve nearest-even
  rounding, saturating float-to-integer results and NaN-to-zero conversion.
  Masked operands become zero before conversion. Independent integer-bit
  oracles check boundary and raw values, retained inputs, exception flags
  and guarded tails. Final-object fixtures reject scalar and narrowed
  instructions. The interpreter now clamps infinities and out-of-range
  values before scalar integer conversion.

- Native streams explicitly widen `i8` and `i16` columns into `i32s`, or
  `u8` and `u16` columns into `u32s`, on SSE2, AVX2, AVX-512F and NEON.
  Packed extension preserves signed values, with guarded compact transfers
  in partial racks. Independent C checks all four stored types, wrapping
  sums, unsigned products, single-column updates and separate destinations
  for every count from zero through 65, with arrays ending at guard pages.
  Outputs remain 32-bit, and general native runs remain WIP.

- Native `bitcast` between `i32s` and `u32s` preserves lane bits in register
  kernels and streams. Allocation reuses a dying input or copies it through
  a vector register, without numerical conversion. The interpreter now keeps
  the selected profile's width through bitcasts and integer broadcasts.

- WebAssembly object verification accepts narrower packed comparisons and
  extending multiplies only when source-derived operand bounds justify them.
  Compact column types and literals establish those bounds. Unproved
  arithmetic drops them. Independently compiled packed objects reject without
  the bounds and pass with them. LLVM's six extending-load spellings are
  normalised to their WebAssembly instruction identifiers. Compact streams
  pass numerical and object checks in both addressing modes.

- Native streams traverse `f32`, `i32` and `u32` columns on SSE2, AVX2,
  AVX-512F and NEON. One to four same-width columns can contribute to a
  stream or single-column update, retaining each column's type and the
  existing guarded-tail contract. Independent C checks signed wrapping
  arithmetic, unsigned boundaries, literal shifts, mixed float/integer
  masks, exact aliasing and separate destination layouts. C and Rake callers
  check the boundary, and all five CPU-profile interpreters check the same
  source. Cross-lane traversal operations remain WIP.
  Embedded kernel assembly restores the text section before slow functions,
  so platform startup adapters remain executable code.

- WebAssembly partial stores keep their scalar remainder opaque to clang,
  retaining integer arithmetic on a rack before lane stores. This applies
  in both addressing modes. Unsigned comparisons at the high-bit boundary
  select their packed sign-mask sequence explicitly. Independent expected
  masks and the strict final-object verifier check both changes.

- WebAssembly uniform choices broadcast a Boolean mask and select rack bits.
  This retains the rack choice through partial stores. Clang previously moved
  scalar choices after a one-lane extraction, which the strict object verifier
  rejected. Scalar expected values check both nested choices and every tail
  remainder, including unchanged output beyond the count.

- Native float streams take `i32`, `u32` and `bool` uniforms alongside
  floats. Integer arguments, descriptors, counts and output pointers follow
  their C register counter independently of float arguments. Direct uniform
  comparisons and Boolean choices retain protected full-rack and tail
  semantics. Independent C checks interleaved argument types, signed and
  unsigned boundaries, unused Boolean argument bits, eight persistent
  uniforms, in-place updates and separate destinations ending at guard pages.
  Stack arguments remain work in progress.

- Boolean uniforms choose whole racks on all four physical profiles, including
  results of `all` and `any`. A packed broadcast and sign extension turn the
  Boolean into a lane mask, with the usual protection for untaken floating-point
  work. Native kernel arguments accept C `bool` through the integer argument
  slots and retain only its value bit. Independent C checks both choices,
  every reduced lane mask, fused expressions and nested through masks.
  Assembly callers deliberately set unused upper argument bits. Slow callers
  check Boolean arguments, literals, results and inlined calls.
  Marked literals `<true>` and `<false>` are Boolean uniforms, including
  forms with spaces inside the brackets. The lexer previously treated the
  compact forms as variable references, unlike the Tree-sitter grammar.

- Direct uniform `i32` and `u32` comparisons choose whole racks on all four
  physical profiles. Broadcast operands use the existing typed vector
  comparisons, with mask protection for untaken floating-point work.
  Independent C checks all six predicates, signed and unsigned boundaries,
  literals on either side and retained input racks. Nested conditions inside
  through masks check exception flags as well as results. Slow callers and
  WebAssembly programs exercise the same source forms.

- Native register kernels take `i32` and `u32` uniforms through the platform
  C integer argument registers, independently of SIMD argument slots. Their
  entry imports and vector broadcasts preserve all 32 bits. Verification
  permits only the declared entry transfers. Independent C checks high-bit
  values, interleaved argument classes, every integer argument register,
  eight SIMD arguments and retained racks. Slow callers also use these
  uniforms and signed 32-bit results. Integer bitwise built-ins and extrema
  broadcast marked uniforms in either operand, including two uniforms.
  Typed calls check integer literals against the parameter's range, and
  explicitly typed rack bindings broadcast their uniforms. Native scalar
  integer constants stay in vector registers until the C return transfer.
  Executable semantics and WebAssembly checks cover unsigned boundary bits
  and wrapping uniform arithmetic. Runtime shift counts remain work in progress.

- `u32s` `min` and `max` compile on SSE2, AVX2, AVX-512F, NEON and
  WebAssembly. SSE2 compares sign-bit-biased copies, then selects the
  original lane bits with three allocated temporary registers. AVX2 and
  AVX-512F use `vpminud` and `vpmaxud`, NEON uses `umin` and `umax`, and
  WebAssembly uses `i32x4.min_u` and `i32x4.max_u`. Independent C checks
  unsigned boundaries, nested clamps, masked selection and retained inputs.
  Interpreter and WebAssembly goldens include full-width unsigned literals.

- `u32s` supports all six comparisons on SSE2, AVX2, AVX-512F, NEON and
  WebAssembly. Unsigned rack and uniform types retain their signedness in
  the IR and interpreter. SSE2 and AVX2 compare sign-bit-biased copies,
  AVX-512F uses `vpcmpud`, and NEON uses `cmhi` and `cmhs`. Independent C
  checks high-bit boundaries, operand order, mask reductions and live inputs.
  Interpreter goldens and a whole-program WebAssembly fixture check unsigned
  ordering and broadcasts.

- Static `i32s` and `u32s` shuffles compile on all four physical profiles.
  They share the float shuffle's bit-preserving selection, allocation and
  final-object checks. Independent C checks one- and two-rack permutations,
  repeated lanes, whole-register selection and still-live or aliased inputs.
  The interpreter also selects 32-bit integer lanes, with hand-specified
  boundary-bit cases at four, eight and sixteen lanes. Native stream
  shuffles remain WIP until their tail participation contract is defined.

- Native signed `i32s` `abs` compiles on all four physical profiles,
  retaining the wrapping −2³¹ result. SSE2 uses packed sign extension,
  XOR and subtraction with an allocated temporary register. AVX2, AVX-512F
  and NEON use direct full-width absolute-value instructions. Independent
  widened C arithmetic checks exact bits, retained inputs, nested calls and
  masked selection. Final-object fixtures refuse narrowed and memory forms,
  and SSSE3 instructions in the SSE2 profile.

- Native `i32s` and `u32s` `bit_andnot(a, b)` uses a full-width packed
  instruction on every physical profile, preserving `a & ~b`. The x86
  emitter reverses instruction operands, and SSE2 preserves inputs across
  destructive register reuse. Independent C checks exact bits, equal
  operands, literal masks and masked selection. Final-object fixtures
  refuse narrowed, scalar and memory forms.

- Integer rack mask literals use their scalar element's range check. Valid
  `u32s` masks up to 4294967295 are accepted, including a literal as the
  first operand of `bit_andnot`. Native lowering preserves those high-bit
  masks in its 32-bit representation. An untyped integer literal retains
  the signed `i32` range.

- Native `i32s` and `u32s` bit shifts accept literal counts from 0 to 31 on
  all four physical profiles. Full-width packed instructions implement left,
  logical-right and signed-right shifts. A zero count leaves the rack unchanged.
  Independent C checks every count, sign extension, masked use and retained
  inputs. Final-object checks reject narrowed or scalar shifts, runtime
  counts and out-of-range immediates. Native uniform counts remain WIP.

- Native signed `i32s` `min` and `max` compile on all four physical profiles.
  SSE2 uses packed comparison and logical selection with an allocated mask
  register. AVX2, AVX-512F and NEON use direct full-width extrema instructions.
  Independent C checks signed limits, nested clamps, masked branches and
  retained inputs. Final-object checks reject narrower extrema and SSE4.1
  instructions in the SSE2 profile.

- Native `i32s` and `u32s` multiplication wraps to the low 32 bits on all
  four physical profiles. SSE2 uses two packed multiplies and four shuffles
  with allocated vector temporaries. AVX2, AVX-512F and NEON select one
  full-width multiply instruction. Independent C checks overflow, lane order,
  masked products and destructive input reuse. Final-object checks refuse
  MMX, narrowed vectors, scalar work and memory multiply operands.

- Native signed `i32s` negation uses full-width packed zero/subtract on
  SSE2, AVX2 and AVX-512F, and `neg .4s` on NEON. The independent C oracle
  checks wrapping bits, retained inputs and lane-masked selection, including
  the minimum signed value. The final-object verifier rejects narrower NEON
  negation forms.

- Native `i32s` and `u32s` support wrapping add/subtract and bitwise
  AND/OR/XOR on SSE2, AVX2, AVX-512F and NEON. Signed `i32s` comparisons
  produce masks for selection and mask reductions. Mixed integer/float
  selection preserves the vector C ABI. An independent C oracle checks
  overflow bits, signed extremes, tines/gaps and still-live inputs. Assembled
  negative fixtures reject narrowed vectors, scalar work and integer memory
  operations. Other integer operations remain WIP.

- Direct uniform `f32` comparisons support whole-rack conditional expressions
  on all four physical profiles. Broadcast operands use ordered vector
  comparisons and selection, with benign operands in untaken branches.
  Independent C checks the six predicates, NaNs, signed zeros, subnormals,
  mixed scalar/vector arguments and nesting inside through masks. Stream
  checks cover guarded tails, in-place output and Rake callers.

- Float comparison masks support `all`, `any` and `bitmask` on all four
  physical profiles. Full-width bitwise reductions use one checked temporary
  vector register, then transfer the completed Boolean or bitset through the
  scalar C return ABI. Native slow callers can receive `bool` and `u32`
  results from uniform-`f32` kernels. Independent C checks every lane-mask
  pattern and quiet-NaN gaps. Final-object fixtures reject intermediate or
  incorrect scalar transfers and scalar arithmetic inside a kernel.

- Static `f32s` shuffles compile on all four physical profiles, selecting
  lanes from one or two racks across their full width. Register-only
  sequences preserve exact lane bits, with scratch registers included in
  the no-spill allocation check. Independent C checks permutations, repeated
  indices, signalling NaNs and still-live inputs. Final-object fixtures
  reject unselected permutations and memory stores. Native stream shuffles
  remain work in progress pending their partial-rack contract.

- Literal-index `f32s` insertion compiles on all four physical profiles.
  It replaces one lane's bits from a uniform argument, literal or extracted
  value, preserving every other lane. The scan pipeline shares its insertion
  sequence. Independent C checks the mixed scalar/vector ABI, exact bits,
  signalling NaNs and preservation of still-live inputs. Native streams still
  reject extraction and insertion pending their tail participation contract.

- Literal-index `f32s` extraction compiles on SSE2, AVX2, AVX-512F and NEON.
  The index bounds follow the selected profile's four, eight or sixteen lanes.
  Full-width vector transfers preserve the selected bits and return through
  the scalar C ABI. Independent C checks every lane, signalling NaNs,
  rebroadcasts and preservation of a still-live rack.

- NEON compiles the four float reductions and inclusive scans as three
  ordered steps. Intermediate values stay in complete vector registers,
  and strict extrema canonicalise NaNs. The object verifier permits lane
  broadcasts and prefix insertion only for selected cross-lane functions.
  The shared scalar oracle checks order, signed zeros and NaNs at every
  position on all physical profiles.

- Native `f32s` `floor`, `ceil`, `trunc` and ties-to-even `nearest` compile
  on SSE2, AVX2, AVX-512F and NEON. SSE2 uses vector conversions and masks,
  with five temporary registers checked by the no-spill allocator. Other
  profiles use integral-rounding instructions. Independent binary32 checks
  cover result bits, active signalling NaNs, inactive lanes and guarded tails.
  The interpreter's `nearest` now preserves negative zero.

- Native `f32s` `min` and `max` preserve NaNs and signed zero on SSE2, AVX2,
  AVX-512F and NEON. The x86 lowering reuses the strict reduction sequence,
  with five temporary vector registers included in allocation pressure.
  NEON uses full-width `fmin` and `fmax`. An independent bit-ordering oracle
  checks values, signalling-NaN exceptions and masked gaps, and guard pages
  check every stream tail. Native floating-point control settings are now
  explicit caller obligations.

- Native `f32s` absolute values compile on SSE2, AVX2, AVX-512F and NEON as
  full-rack bitwise operations. An independent IEEE-754 bit oracle checks
  signed zeros, subnormals, infinities and NaNs, including signalling NaNs
  under masks. Traversal checks cover every tail and C and Rake callers.

- Native `f32` traversals accept `i32` counts as well as `i64` counts. The
  selected entry code sign-extends a 32-bit C argument before loop guards and
  pointer access. Independent C checks supply unspecified upper register
  bits for every tail and for zero and negative counts on all four profiles.

- Native `f32` traversals can write one column in a separate mutable
  destination stack. Its descriptor follows the count in the platform C ABI,
  and the selected pointer uses the destination's own record layout. C checks
  values and exact aliases against independent scalar results, with guard
  pages for every partial rack. Rake callers exercise the same boundary.
- Native `f32` traversals can update one column of their mutable input stack,
  with the same selected vector loop and guarded tail as stream output.
  All read columns are loaded before the update. Independent C checks the
  mutable descriptor ABI, in-place results, an unread destination and
  untouched independent columns, alongside Rake callers on every CPU profile.
- Native `f32` streams accept up to eight uniform `f32` arguments after their
  count. Their platform C argument registers are copied into caller-clobbered
  slots and kept live across full and partial racks by the no-spill allocator.
  Independent C checks scale, bias and threshold arguments, quiet NaNs and all
  eight register slots, alongside Rake callers on every physical CPU profile.
- Extend native `f32` streams to NEON: four-lane vector transfers and
  count-guarded partial-rack memory operations, with vector arithmetic in
  the tail. The final ELF function extent is checked against the selected
  assembly. Independent C and guard pages check one to four columns, exact
  in-place output and million-element results on all four CPU profiles.
  NEON ordered comparisons preserve quiet-NaN behaviour through vector
  operand sanitisation. The numerical oracle checks all six operators.
- Correct the safe-root check-only command to include its million-element
  comparison before returning. Earlier check-only runs covered short counts
  and guarded tails.
- Extend native `f32` streams to SSE2: four-lane racks with guarded memory
  transfers for partial racks and vector arithmetic throughout. Independent
  C and guard-page checks pass on SSE2, AVX2 and AVX-512F. SSE2 ordered
  comparisons now preserve quiet-NaN behaviour through explicit vector
  sanitisation, with additional mask-register pressure checked by the allocator.
- Extend native `f32` streams to AVX-512F: sixteen-lane racks, masked
  loads and stores, and inactive-input sanitisation. Independent C and
  guard-page checks exercise one, two and four columns on the AVX2 and AVX-512
  stream profiles, including every tail remainder and exact in-place output.
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
