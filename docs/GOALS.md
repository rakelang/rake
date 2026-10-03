# Goals

Rake is a language for SIMD programs. It lets a programmer state the vector
structure of an algorithm, its registers, masks and data layout, without
writing intrinsics or assembly. This page sets out the promises the language
makes. A compiler may reject a program or a profile it can't compile under
them, and it never keeps a program by weakening a rack, a fused region or a
rake into scalar code. Each section ends with what the compiler does today.

## Racks are vector values

A rack is one vector register of a physical CPU profile, or one vector
value in a virtual machine profile. The profile fixes its width, and the
element type gives the lane count: on a 256-bit profile an `f32s` rack has
eight lanes. A rack is never split, narrowed, held in source-visible memory
or computed lane by lane, so a program that would need any of these is
rejected. A scalar target is a separate, explicit profile, never described as
SIMD, and a build for another machine chooses its profile instead of taking
the features of the machine it runs on.

Today: the x86 and AArch64 profiles keep each rack in one physical register,
which the object verifier checks. The `wasm-simd128` profile keeps each rack
as one `v128` value and uses SIMD instructions for rack work. Rake accepts the
virtual machine's fiction and leaves physical register allocation to the
WebAssembly runtime. The proposed GPU rack has a different representation:
one lane per invocation in a specified warp or subgroup, as the GPU contract
below describes.

## Scalars are marked

Plural types, such as `f32s`, are racks. Angle brackets mark a uniform scalar
where it is declared and where it is used, so every broadcast from a scalar
into a rack is visible. Seeing many brackets in a kernel invites the
question of whether those values could vary by lane, or be stored and
processed better. The type checker rejects an implicit conversion between a
scalar and a rack.

`lanes`, the lane count, and `@`, the lane index, are planned. Both are
reserved and unavailable.

## Lane choices are masks

Tines describe lane masks, either locally or as reusable typed global
predicates. A through block computes under one. Without `else`, its result
is defined only there, and the checker refuses reads outside that mask.
A sweep picks each lane's result in priority order. Its arms must provably
cover every lane, using `gaps` or a final `_` where needed. A vector backend
keeps these choices as vector predication,
with masked instructions or benign operands, and never turns them into
branches for each lane. An inactive lane raises no floating-point exception,
touches no memory and has no other effect. A masked operation that a profile
can't compile under both this rule and the one-register rule is rejected.

Today: rakes compile on `x86-sse2`, `x86-avx2`, `x86-avx512`,
`aarch64-neon` and `wasm-simd128`.

## Fused regions are pure data flow

Consecutive `| name <| expression` bindings describe one pure graph of vector
operations, with no calls, spills or reloads. Its identifiers are aliases. They
impose no evaluation order, storage, instruction or rounding boundary, so the
backend may rewrite the whole region to the cheapest graph for the profile,
and different profiles may round its intermediates differently. `fma(a, b, c)`
means one rounding, and is for programs whose correctness needs it. Rake has
no mode that keeps a slower sequence of ordinary operations.

Today: the compiler substitutes identifiers and forms fused multiply-adds on
`x86-avx2`, `x86-avx512` and `aarch64-neon`. Other rewrites are planned, as [fused
bindings](spec/04_fused_bindings.md) describe.

## A complete vector vocabulary

Rake's vector operations are to cover:

- arithmetic, comparisons, masks and mathematical functions,
- the lane count and lane indices, and extracting and inserting lanes,
- reductions and scans,
- shuffles, interleaving, and shifts and rotations of lanes,
- fused multiply-add, chosen by the compiler or required by the source,
- gather, scatter, compression and expansion, and
- layouts of columns and of single records.
 Each operation has a type rule, a rule for inactive lanes,
a set of profiles that support it and a verified lowering. A profile without
a native form of an operation rejects it before generating code.

Today: [primitives, operations, and targets](spec/01_primitives_operations_and_targets.md) lists what each
profile compiles. Lane indices, interleaving, lane shifts and rotations,
scatter, compression, expansion and single-record layouts are planned.

## Data layout is explicit

A `pack` describes one record. A `stack` collects those records in
structure-of-arrays storage, and a traversal visits its columns a rack at a
time. Conversions between layouts and memory
operations are written in the source or set by a documented calling
convention. A traversal's tail never reads or writes past the count, and its
inactive lanes raise no exception and have no effect.

Today: general runs, stacks and traversals compile on `wasm-simd128`.
The development compiler adds `f32`, `i32` and `u32` stream traversals and single-column
stack updates on SSE2, AVX2, AVX-512 and NEON. An update can write its input
stack or a separate destination with a different record layout.
Explicit `widen` also reads signed and unsigned byte or 16-bit columns into
32-bit working racks. Each column advances by its stored element width,
and a partial rack reads only participating records. Outputs stay 32-bit.
Signed integer/float numerical conversions preserve those 32-bit lanes,
with masked protection, nearest-even rounding and saturating float-to-integer
results.
[Packs and runs](spec/02_packs_and_run.md) defines
their boundaries and checked tails.

## Scalar code stays scalar

A program's scalar work, its records, state, control flow and calls to C, is
slow code, marked `slow`. A run enters it explicitly with `slow { ... }` and
resumes vector mode at `}`. Slow code can't hold a rack, and reaches vector
work only through calls whose uniform arguments are marked, so the promises
above hold unchanged around it. The compiler guarantees vector lowering,
not a particular elapsed time or the fastest possible algorithm.

Today: whole programs compile on `wasm-simd128`, as [the slow
tier](spec/08_slow_tier.md) describes. The unreleased development compiler
also compiles slow orchestration with register kernels into native objects.
Their C unit embeds Rake-selected assembly, which remains opaque to the
platform C compiler. Slow callers can pass uniform `f32`, `i32` and `u32`
arguments and receive `f32`, `bool`, `i32` or `u32` results. Native runs beyond
the stream subset and other scalar kernel boundaries remain work in progress.

## Compilation is predictable

On physical CPU profiles the compiler owns rack instruction selection,
register allocation, instruction sequencing and assembly. The assembler only
encodes what it is given. Explicit slow code uses the platform C compiler.
On WebAssembly, Rake owns selection of the virtual machine instructions and the
shape of its `v128` values. The WebAssembly runtime owns their eventual
physical registers. Every compiler stage can be inspected, and the compiler
proves the properties it claims for an accepted program. When it can't prove
one, it fails with the source construct, profile and obligation that failed.
A benchmark result is reported with its source, profile, compiler version,
command, input size and baseline.

Today: on SSE2, AVX2, AVX-512 and NEON the compiler selects instructions,
allocates registers without spills and writes the assembly, and
`--emit-native-ir` and `--emit-asm` show its work. On `wasm-simd128` it
selects the instructions and writes each as one intrinsic in C, and clang
encodes them, choosing locals and occasionally an equivalent instruction,
which `--verify-native` checks.

## GPU work keeps its parallel structure

A GPU rack will map its lanes onto a specified warp, wave or subgroup.
Per-invocation arithmetic is that parallel work. A hidden loop serially
processing the rack inside one invocation is forbidden. Uniform values,
lane masks, collective participation, memory address patterns and
synchronisation scopes will be explicit parts of the profile.

The hardware schedules warps. Rake will preserve and verify the declared lane
mapping and permitted control flow, including programmer-selected partial
masks. It cannot promise that arbitrary inputs keep all lanes active. In
regions with a strict resource contract, forbidden spills, reloads and helper
paths cause rejection.

The initial NVIDIA PTX route delegates final physical allocation and
instruction scheduling to NVIDIA, then verifies the exact cubin. Portable
SPIR-V could preserve the same source-level contract, with device-specific
evidence for final-code claims. A later direct physical backend is a stronger
ownership option, rather than a prerequisite for useful GPU guarantees.

Register count, memory address structure and absence of forbidden lowering
can be checked. Achieved occupancy, cache behaviour and elapsed time require
measurement. No-spill does not mean fastest: retaining more registers may
reduce resident warps. Another resource policy must be an explicit profile,
never a silent fallback.

Today: GPU support is a design. [GPU profiles](GPU.md) defines the first
proposed NVIDIA profile, its artifact verifier and runtime boundary.
