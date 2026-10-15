# Roadmap

This roadmap sets out what we intend to build next. [The changelog](../CHANGELOG.md) records work once it has landed, and
[the goals](GOALS.md) set the requirements for every change.

## Capabilities and coverage

### Native runs

We'll finish general native runs, runtime-counted inner loops and the
remaining scalar kernel boundaries, along with the run model itself. General
runs over views still use explicit
counted loops for running prefixes across records and for stencils over
neighbouring records, and both will move into stack runs as column-level
scans and shifted column reads. Pairwise work between two stacks, once
expressed by the now-removed nested traversal, will come back as an explicit
outer form.
On the native profiles, stack runs will gain replacements of byte and 16-bit
fields, views, gathers and 64-bit domains, and on WebAssembly they'll gain
compaction of 8-bit domains. Loop-invariant work, such as a uniform's
broadcast, will move out of each iteration.

### C interoperation

Rake-owned union layouts and interpreted union storage are still in
progress. We'll check layouts, alignment, field offsets and calls in both directions
against independently compiled C headers on x86-64 and AArch64, and extend
those checks as new foreign types and platforms arrive. Scalar code inside
`slow` may be lowered by the platform C compiler, but rack work outside the
block never will be.

### WebAssembly

On WebAssembly, Rake will keep selecting vector instructions and leave
physical register allocation to the WebAssembly runtime. Rack work outside a
`slow` block compiles to vector instructions or fails to compile, and a
general run's explicit loop also needs uniform address, bounds and loop work.

We'll extend WebAssembly's source-derived substitution proofs across
immutable bindings. Clang currently rewrites a composed unsigned shift
pair into a mask and AND, and repeated integer additions into a multiplication.
Those programs run correctly, but the run verifier rejects their objects.
Accepting them needs proofs of operand identity and wrapping arithmetic, so
that the verifier's instruction allow-list doesn't widen for unrelated
expressions.

### Target profiles

We'll add the explicit scalar fallback and complete CPU operation and program
coverage before starting on GPU targets. Each physical profile needs
instruction selection, register allocation, a calling convention, object
verification and differential runtime checks. Relaxed WebAssembly SIMD stays
opt-in until we've validated it on the competition runtime.

### GPU profiles

Once CPU coverage and native C interoperation are done, we'll implement
`nvidia-ptx-sm120`, a 32-lane warp profile that emits PTX 8.7 and compiles it
ahead of time with pinned CUDA 12.8.1 tools. NVIDIA allocates registers and
schedules instructions on that profile, so Rake's verifier checks the final
cubin's lane mapping, control and data flow, memory effects and resources,
and the runtime loads only that exact verified artifact. Portable
SPIR-V/Vulkan subgroup profiles and a direct physical profile for a
sufficiently documented ISA come later. All of them are designs today, and
[GPU profiles](GPU.md) sets them out in detail.

### CPU operations

[The changelog](../CHANGELOG.md) lists the float and 32-bit integer
operations that already compile on all four physical CPU profiles. The rest
of the language's published operation set comes next.

Integer support stops at 32 bits in several places. Extraction, insertion
and shuffles at other integer widths are still to come, along with the
remaining integer operations, native stack runs at other lane widths, and the
remaining column and output widths.

Cross-lane operations in a native stack run need a definition of which lanes
take part in a partial rack. Until we've defined it, native stack runs reject
extraction, insertion and shuffles, and their scans don't carry state from
one rack to the next. Arithmetic on uniform results under a partial lane mask
is still in progress too.

Substantial maths, gathers and the remaining scalar expressions in native
runs follow. A CPU profile gains
an operation only when its compiled result matches the interpreter and its
object verifier proves the selected vector sequence.

### Operations on every profile

Some gaps are shared by every profile: lane movement, transcendental
functions, float remainder, `f64s`, the remaining integer and Boolean rack
types, unsigned comparisons and extrema at other widths, integer scans and
reductions at other widths, widening conversions, further scalar operations
over rack results, scatter, compression and expansion.

An operation may lower to several vector instructions when a profile
publishes that sequence. It may not lower to scalar lanes, helper calls,
split racks or memory temporaries outside `slow` code.

### Fused optimisation

The optimiser currently performs substitution and fused multiply-add
formation. Planned rewrites include reassociation, factoring, distribution,
common-subexpression sharing and strength reduction within a fused region.
Each profile will choose among legal rewrites using its operation costs, and
tests will compare the emitted result with the verified optimised graph.

### Fallback coverage

The compiler checks optional fallbacks by proving Boolean coverage and lane
definedness. We'll extend that analysis only with sound floating-point and
lane-movement semantics, and the compiler will keep refusing a program when
it can't prove coverage.

### Unavailable language capabilities

The capability catalogue currently reports 91 checked and 34 unavailable
capabilities, and we'll work down the unavailable ones. The outstanding
language areas include tuple types, closures, lambdas, pipelines, type
aliases, spread parameters, record updates, inline tines, outer products and
several masked operations. Each becomes supported under the release checks at
the end of this page.

## Grammar and syntax

### Internal AST forms

Every internal AST form will either get source syntax and defined semantics
or be removed. Parser and capability reports will then cover only
accepted constructs and those deliberately rejected as planned work.

### Modules and separate compilation

We'll design one coherent system for modules, imports, namespaces, packages
and separate compilation. It will preserve Rake's explicit target rules and
produce stable boundaries for native and WebAssembly callers to inspect.
Import syntax will come with that complete design.

### Teaching the vector notation

The tutorial, diagnostics and reference examples will introduce
`<uniform>`, `#tine`, fused `| name <| value` bindings, `through` and `sweep`
when a learner first needs them. Compiler messages will use the
documentation's terminology and point to the relevant lesson.

### Negative uniforms

With ligatures enabled, a programming font can render a negative uniform as
an assignment arrow. We'll choose and validate a spelling that can't be
mistaken for one, and change the compiler, grammar, formatter, highlighter
and documentation together. Until then the website disables ligatures inside
uniforms such as `<-1.0>`.

### Layout and delimiters

Rake combines indentation-sensitive bodies with braces for packs and
records. We'll test that combination against larger programs, formatter
design and editor recovery, and keep the hybrid only if it remains the
clearest single rule set. Any syntax change will replace the old form across
the compiler, grammar, examples and documentation in one release.

## Tooling

### Language server

We'll provide a language server with live diagnostics, completion, hover,
rename and semantic navigation. It will use the compiler's own parser, types
and source locations instead of keeping a second model of Rake.

### Formatter

The formatter will produce one stable layout for declarations,
indentation-sensitive bodies, records, packs, fused bindings, tines and
sweeps. Formatting will be idempotent and checked against every example in
the documentation.

### Editor integrations

Editor extensions will combine Tree-sitter highlighting, the formatter and
the language server. We'll choose the first supported editors by actual use,
and each package will state which compiler and grammar versions it's
compatible with.

### Debugging and profiling

We'll map compiled instructions and runtime costs back to Rake source. The
debugger will show uniforms, racks, masks and slow-code state without
pretending that WebAssembly virtual registers are physical registers. The
profiler will separate vector work, slow work, loads, stores and rejected
scalarisation opportunities.

### Toolchain bundles

We'll publish reproducible `rakec` bundles for the supported host platforms,
with checksums, version information and the matching grammar and
documentation, so compiling Rake won't need an OCaml or Nix development
environment.

### Playground projects

The tutorial and single-file compiler will grow persistent projects,
shareable links, multiple files and explicit compiler-version selection. The
interactive lessons will stay reproducible examples instead of becoming a
separate dialect of the language.

### Tree-sitter packages

The grammar is published on npm, PyPI and crates.io, and CI builds SwiftPM
with Foundation available alongside the npm, Python, Rust and Go package
checks. We'll keep testing installation from each registry and publish
syntax changes together with the compiler. Generated bindings, comments,
queries and version metadata will keep coming from the same current grammar
revision.

## Release checks

A capability moves from unavailable to supported when one compiler revision
has all of these:

- the specification gives its types and meaning,
- unavailable and malformed uses get diagnostics with a source location,
- the interpreter covers ordinary, boundary and exceptional inputs, and
  explicitly rejects storage with a platform layout beyond its model, such
  as C unions, which go to an independently compiled C ABI oracle instead,
- the compiled code matches the interpreter,
- the object verifier checks the profile's rules for it, and
- `rakec --print-capabilities`, the tests, the changelog and the
  documentation agree.

A published benchmark records its source, compiler version, profile,
command, input size, machine and baseline.
