# Roadmap

Rake's vector contract now has SSE2, AVX2, AVX-512F, NEON and WebAssembly
implementations. General native runs, a scalar fallback and operation parity
remain work in progress. This roadmap states what we intend to build next.
[The changelog](../CHANGELOG.md) records work once it has landed, while
[the goals](GOALS.md) define the requirements for every change.

## Capabilities and coverage

### Compile runs, stacks and whole programs for physical targets

The development compiler after 0.6.0-beta compiles slow orchestration and
register kernels into one native object. Its C unit embeds Rake-selected
assembly, and the final object's kernels pass the existing instruction
verifier. Slow callers can use uniform `f32`, `i32`, `u32` or `bool` parameters and
`f32`, `bool`, `i32` or `u32` results.
Imported C structs use their header's layout, and public slow functions have
the platform C ABI. SSE2, AVX2, AVX-512 and NEON traversals now yield `f32`,
`i32` or `u32` streams or update one column in a mutable input or destination stack,
with full and partial racks,
final-byte verification and independent C/guard-page checks. Traversals also take up to eight uniform
`f32`, `i32`, `u32` or `bool` arguments, preserved in registers across racks
within the platform's C register limits. General native runs and
the remaining scalar kernel boundaries are still
work in progress.

We will extend `run`, stacks and whole programs from `wasm-simd128` to
SSE2, AVX2, AVX-512 and NEON. That work includes native traversal, full-rack
loads and stores, masked tails with benign operands, stable C boundaries and
runtime tests over empty, short, exact and tail counts. The object verifier
will confirm vector memory operations and reject scalar cleanup loops.

The development compiler also accepts typed `argc`/`argv` entry, adapting the
runtime's C pointer array without incompatible pointer aliasing. The C interface
supports typed function pointers, noncapturing callbacks and header-backed C
unions. Rake-owned union layouts and interpreted union storage remain work in
progress. Pointer types now retain C's read-only pointee qualifiers,
including in callback signatures. We will check layouts, alignment, field
offsets and imported/exported calls against independently compiled C headers on x86-64
and AArch64. Scalar lowering inside `slow` may use the platform C compiler;
that permission will never apply to rack work outside the block.

Slow-local frames now use C-defined size and alignment, including
header-backed aggregates nested in arrays or Rake records. Small frames stay
on the host stack, while larger frames use the bounded arena. We will extend
the independent C ABI checks as new foreign types and platforms are added.

WebAssembly will continue to honour the virtual machine's abstraction. Rake
selects vector instructions, but leaves physical register allocation to the
WebAssembly runtime. Rack work outside a `slow` block uses vector
instructions or compilation fails. A run's explicit traversal also needs
uniform address, bounds and loop work.

### Add and validate target profiles

SSE2 and AVX-512F now compile `f32s` scratches and rakes, alongside AVX2 and
NEON. We will add the explicit scalar fallback and complete CPU operation and
program coverage before beginning GPU targets. Each physical profile must
have instruction selection, register allocation, a calling convention,
object verification and differential runtime checks.

We will validate relaxed WebAssembly SIMD on the competition runtime before
considering it a default. Until then it remains explicitly opt-in.

### Preserve and verify GPU lane execution

After CPU coverage and native C interoperation, we will implement
`nvidia-ptx-sm120`: a 32-lane warp profile emitting PTX 8.7, compiled ahead
of time by pinned CUDA 12.8.1 tools. Its final cubin verifier will check lane
mapping, allowed control/data flow, memory effects and resource obligations.
The runtime will load the exact verified artifact through an explicit CUDA
context, stream and parameter ABI, refusing unverified PTX JIT fallback.

This virtual profile delegates final physical allocation and instruction
scheduling to NVIDIA. The useful guarantee is preserved parallel structure
and checked costs. Partial masks remain legitimate program choices, and
occupancy, workload balance and elapsed time still need measurement.

We will later consider portable SPIR-V/Vulkan subgroup profiles, with
device-specific evidence for physical resource claims, and a direct physical
profile for a sufficiently documented ISA. All are designs today.
[GPU profiles](GPU.md) owns the detailed contract and acceptance checks.

### Complete physical CPU operation coverage

The development compiler now lowers `f32s` absolute values to vector bitwise
operations on SSE2, AVX2, AVX-512F and NEON. Independent bit-pattern checks
cover signed zeros, subnormals, infinities and NaNs, including masked use.
Lane-wise `min` and `max` also compile on all four physical profiles,
preserving NaNs and signed zero. The independent numerical oracle checks
floating-point exceptions as well as results, and guarded stream checks
cover every partial rack.

`floor`, `ceil`, `trunc` and ties-to-even `nearest` now compile on all four
physical profiles too. SSE2 uses vector conversions and selections without
requiring SSE4.1. An independent binary32 oracle checks ties, signed zeros,
subnormals and nonfinite values, and guarded stream checks cover masked tails.

Float reductions and scans now compile on NEON too. All four physical profiles
preserve the specified left-to-right fold, including each binary32 rounding.
The shared scalar oracle checks NaNs at every position and signed-zero extrema.

Literal-index float extraction and insertion now compile on all four
physical profiles.
Their lane bounds follow each profile's rack width. Independent C checks every
lane's bits, scalar argument and return values, and reuse of the original rack.
Insertion accepts a uniform argument, literal or extracted value. Native
streams still reject both operations until tail participation is specified.

Static float shuffles now compile on all four physical profiles. Their
one- and two-input selections span the whole rack, including moves across
AVX register subdivisions. Independent C checks permutations, repeated
indices, exact bits and preservation of still-live inputs. Native stream
shuffles remain work in progress until tail participation is specified.

Mask reductions now compile on all four physical profiles. `all` and `any`
produce a Boolean, and `bitmask` a bitset with one bit per float lane.
Packed bitwise reductions retain their temporary values in vector registers,
then cross the scalar C ABI through a checked terminal transfer. Independent
C checks every lane-mask pattern and ordered comparisons containing quiet
NaNs. Native scalar arithmetic over those results remains work in progress.

Direct uniform `f32` comparisons now choose a whole rack on all four physical
profiles. The comparison uses broadcasts and vector masks, with protected
operands in untaken branches. Independent C checks all six ordered predicates,
including quiet NaNs, and conditions nested inside through masks. Guard-page
checks cover stream tails and in-place output. Boolean uniforms also choose
whole racks on the physical profiles, including values from `all` and `any`.
Their broadcasts expand the value bit into vector masks. C `bool` arguments
use the integer argument slots, with unused upper bits discarded at entry.
Independent C checks exact choices, every reduced lane mask, fused expressions
and protected roots nested inside through masks. Deliberately set upper
argument bits check the C ABI boundary. Float streams also accept Boolean
uniforms, with guard-page checks for nested protected branches and tails.

We will bring the physical profiles up to the language's published operation
set. The development compiler now supports 32-bit integer wrapping add/subtract/multiply
and bitwise AND/OR/XOR/AND-NOT on all four physical profiles, along with signed
negation and absolute value. Lane-wise `min` and `max` support both signed
and unsigned 32-bit racks. Both `i32s` and `u32s` comparisons produce
masks for integer or float selection and mask reductions.
Independent C checks exact overflow bits, signed boundary values and still-live
inputs across the vector ABI, including masked negation of the minimum signed
value. Multiplication checks signed and unsigned overflow, lane order and
destructive register reuse. SSE2 uses a packed vector sequence, while AVX2,
AVX-512F and NEON each have a full-width multiply instruction. Signed extrema
checks cover signed boundaries, nested clamps, masked branches and retained
inputs. SSE2 uses packed comparison and selection, while the other physical
profiles use direct vector extrema instructions. Literal bit shifts also
compile on all four profiles. Independent C checks every count from 0 to 31,
including sign extension, masked branches and retained input racks.
AND-NOT uses a direct packed instruction on each profile. The independent
bit oracle checks operand order, equal operands, literal masks and reuse of
still-live inputs, including masked selection.
Signed absolute value uses a packed sign/XOR/subtract sequence on SSE2,
with one allocated temporary register, and direct full-width instructions
on AVX2, AVX-512F and NEON. The independent C oracle widens to 64 bits
before negating, then checks the wrapping lane bits, including −2³¹,
retained inputs, nested calls and masked selection.
Static `i32s` and `u32s` shuffles now reuse the float shuffle's bit-preserving
lane transfers on all four physical profiles. Independent C checks single-
and two-rack permutations across the whole register, including repeated
lanes, equal input racks and fused expressions that retain both inputs.
The interpreter checks the same 32-bit lane selection at each CPU width.
Unsigned 32-bit comparisons now compile on all four physical profiles and
WebAssembly. The unsigned IR and interpreter preserve ordering across bit 31.
Independent C checks all six predicates, literal order, mask reductions,
global tines and gaps, and still-live inputs. WebAssembly also checks unsigned
uniform broadcasts against hand-specified boundary values.
Unsigned 32-bit extrema also compile on every CPU profile. SSE2 compares
sign-bit-biased copies and selects the original lane bits, with three
temporary registers included in allocation pressure. The other physical
profiles use direct unsigned extrema instructions. Independent C checks
values across bit 31, full-width unsigned literals, nested clamps and
masked selection while retaining live inputs. Interpreter and WebAssembly
goldens check unsigned extrema and literal broadcasts too.
Runtime shift counts, other integer operations and native streams at other lane widths
remain work in progress.

Native register kernels now take signed and unsigned 32-bit uniforms through
the platform's integer argument registers. Entry imports use allocated vector
registers, and rack arithmetic uses broadcasts of their exact bits. Independent
C checks mixed argument order, high-bit values, all integer argument slots,
eight SIMD arguments alongside an integer uniform, and retained input racks.
Slow callers use the same boundary. Direct `i32` and `u32` uniform
comparisons now choose a whole rack through vector comparison and selection.
Independent C checks all six signed and unsigned predicates, literals on
either side, retained inputs and nesting within a through mask. The
untaken floating-point branches retain their inactive-operand protection.
Float streams also accept integer uniforms. Mixed-type C calls check their
independent integer and float register counters, the output pointer's slot,
all eight persistent arguments, in-place updates and separate destinations.
Native streams now traverse signed and unsigned 32-bit columns too. They
share full-width transfers and guarded tails with float columns, and can
combine those types in one lane expression. Independent C checks wrapping
arithmetic, unsigned clamps, literal shifts, mixed masks, exact aliasing and
single-column updates against arrays ending at guard pages. WebAssembly
and each selected-profile interpreter check the same fixture. Native traversal
now also widens signed and unsigned byte or 16-bit columns into 32-bit
working racks, retaining compact storage and guarded tails. Signedness
bitcasts keep the rack's bits and selected profile width. Independent C
checks all four compact types, updates and destinations against guarded
arrays. WebAssembly verifies its packed widening in both addressing modes,
with source bounds required for narrower comparisons or extending multiplies.
Signed `i32s`/`f32s` numerical conversion and unsigned `u32s` to `f32s`
now compile on every physical profile, in register kernels and streams.
An independent integer-bit oracle
checks nearest-even rounding, saturation, infinities and NaNs. Masked calls
check inactive-lane exceptions, and stream arrays end at guard pages.
The unsigned conversion also passes the bit oracle on WebAssembly in both
addressing modes. SSE2 and AVX2 use exactly converted 16-bit halves before
their final rounded addition. AVX-512F and NEON use unsigned vector
conversion instructions. Guard-page checks include compact unsigned
columns and exact input/output aliasing.
We will extend the remaining column and output widths and float-to-unsigned
conversion, then define participation for cross-lane operations before
admitting them in tails.

The next work covers substantial maths, the remaining integer operations, other integer shuffle widths,
integer extraction and insertion, the remaining scalar expressions and
gather. A CPU profile
will gain an operation only when its compiled result matches the interpreter
and its object verifier proves the selected vector sequence.

### Complete cross-profile operation coverage

We will fill the gaps shared by every profile. These include lane movement,
transcendental functions, float remainder, `f64s`, the remaining integer and
boolean rack types, unsigned comparisons and extrema at other widths, integer reductions,
widening conversions, scalar arithmetic over rack results, scatter,
compression and expansion.

An operation may lower to several vector instructions when a profile publishes
that sequence. It may not lower to scalar lanes, helper calls, split racks or
memory temporaries outside `slow` code.

### Expand fused optimisation

We will extend the optimiser beyond substitution and fused multiply-add
formation. Planned rewrites include reassociation, factoring, distribution,
common-subexpression sharing and strength reduction within a fused region.
Each profile will choose among legal rewrites using its operation costs, and
tests will compare the emitted result with the verified optimised graph.

### Implement the unavailable language capabilities

We will work down the capability catalogue, which currently reports 91 checked
and 34 unavailable capabilities. The outstanding language areas
include tuple types, closures, lambdas, pipelines, type aliases, spread
parameters, record updates, inline tines, outer products and several masked
operations.

A capability becomes supported only when one compiler revision contains its
syntax and semantics, source-located diagnostics, interpreter behaviour,
compiled implementation, object-verifier rules, tests and documentation.
External C storage is checked through its independent compiled ABI oracle.
The interpreter explicitly rejects storage whose platform layout it cannot
represent, including C unions.

## Grammar and syntax

### Resolve internal forms that have no language meaning

We will either give every internal AST form source syntax and defined semantics
or remove it. Parser and capability reports will then describe only constructs
that the language can accept or deliberately rejects as planned work.

### Design modules and separate compilation

We will design one coherent system for modules, imports, namespaces, packages
and separate compilation. The design must preserve Rake's explicit target
contract and produce stable boundaries that native and WebAssembly callers can
inspect. We will not add isolated import syntax before that system is defined
end to end.

### Teach the vector notation at the point of use

We will keep the tutorial, diagnostics and reference examples aligned so that
`<uniform>`, `#tine`, fused `| name <| value` bindings, `through` and `sweep`
are introduced when a learner first needs them. Compiler messages will name
the same concepts as the documentation and point to the relevant lesson.

Global tines now provide reusable typed predicates, and `gaps` supplies exact
mask inversion. Optional fallbacks are checked through Boolean coverage and
lane-definedness proofs. We will extend this analysis only with sound
floating-point and lane-movement semantics, retaining compile-time refusal
when coverage cannot be proved.

### Remove the negative-uniform ambiguity

We will choose and validate a spelling for negative uniforms that cannot be
mistaken for an assignment arrow when a programming font enables ligatures.
The compiler, grammar, formatter, highlighter and documentation will change
together. Until then the website will continue to disable ligatures inside
uniforms such as `<-1.0>`.

### Review layout and delimiters against real programs

We will test the current combination of indentation-sensitive bodies and
braces for packs and records against larger programs, formatter design and
editor recovery. We will retain the hybrid only if it remains the clearest
single rule set. Any syntax change will replace the old form across the
compiler, grammar, examples and documentation in one release.

## Tooling

### Build a language server

We will provide a language server with live diagnostics, completion, hover,
rename and semantic navigation. It will use the compiler's parser, types and
source locations rather than maintaining a second understanding of Rake.

### Add a canonical formatter

We will build a formatter that produces one stable layout for declarations,
indentation-sensitive bodies, records, packs, fused bindings, tines and
sweeps. Formatting will be idempotent and checked against every example in the
documentation.

### Package editor integrations

We will release editor extensions that combine Tree-sitter highlighting, the
formatter and the language server. The first supported editors will be chosen
by actual use, and each package will carry a versioned compatibility statement
for the compiler and grammar.

### Add source-level debugging and profiling

We will map compiled instructions and runtime costs back to Rake source. The
debugger will expose uniforms, racks, masks and slow-code state without
pretending that WebAssembly virtual registers are physical registers. The
profiler will distinguish vector work, slow work, loads, stores and rejected
scalarisation opportunities.

### Ship binary toolchain bundles

We will publish reproducible `rakec` bundles for the supported host platforms,
with checksums, version information and the matching grammar and documentation.
Users will not need an OCaml or Nix development environment to compile Rake.

### Grow the playground into a project environment

We will extend the tutorial and single-file compiler with persistent projects,
shareable links, multiple files and explicit compiler-version selection. The
interactive lessons will remain reproducible examples rather than becoming a
separate dialect of the language.

### Publish and verify every Tree-sitter package

The grammar is published on npm, PyPI and crates.io. SwiftPM builds in CI
with Foundation available, alongside the npm, Python, Rust and Go package
checks. We will keep testing installation from each registry and publish
syntax changes together with the compiler. Generated bindings, comments, queries and
version metadata will continue to come from the same current grammar revision.

## Release gates

A capability moves from unavailable to supported when one compiler revision
has all of these:

- the specification gives its types and meaning,
- unavailable and malformed uses get diagnostics with a source location,
- the interpreter covers ordinary, boundary and exceptional inputs,
- the compiled code matches the interpreter,
- the object verifier checks the profile's rules for it, and
- `rakec --print-capabilities`, the tests, the changelog and the documentation
  agree.

A published benchmark records its source, compiler version, profile, command,
input size, machine and baseline.
