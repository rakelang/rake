# Goals

Rake is a language for SIMD programs. It lets a programmer state the vector
structure of an algorithm, its registers, masks and data layout, without
writing intrinsics or assembly. This page defines the language's compilation
rules. When a program can't be compiled under them, the compiler rejects it,
and it never keeps a program by weakening a rack, a fused region or a rake
into scalar code. Each section ends with what the compiler does today.

## Racks are vector values

A rack is one vector register of a physical CPU profile, or one vector
value in a virtual machine profile. The profile fixes its width, and the
element type gives the lane count: on a 256-bit profile an `f32s` rack has
eight lanes. A rack is never split, narrowed, held in source-visible memory
or computed lane by lane. A scalar target is a separate, explicit profile,
and a build for another machine chooses its profile instead of taking the
host machine's features.

Today: the x86 and AArch64 profiles keep each rack in one physical register,
and the object verifier checks it. The `wasm-simd128` profile keeps each rack
as one `v128` value and leaves physical register allocation to the
WebAssembly runtime.

## Scalars are marked

Plural types, such as `f32s`, are racks. Angle brackets mark a uniform scalar
where it is declared and where it is used, so every broadcast from a scalar
into a rack is visible, and a kernel full of brackets prompts the question of
whether those values should vary by lane. The type checker rejects an
implicit conversion between a scalar and a rack. `lanes`, the lane count, and
`@`, the lane index, are reserved for later.

## Lane choices are masks

Tines describe lane masks, locally or as reusable typed global predicates. A
through block computes under one, and without `else` its result is defined
only under that mask. A sweep picks each lane's result in priority order, and
the checker proves that its arms cover every lane. A vector backend keeps
these choices as vector predication, with masked instructions or benign
operands, and never turns them into branches for each lane. An inactive lane
raises no floating-point exception, touches no memory and has no other
effect.

Today: rakes compile on `x86-sse2`, `x86-avx2`, `x86-avx512`,
`aarch64-neon` and `wasm-simd128`.

## Fused regions are pure data flow

Consecutive `| name <| expression` bindings describe one pure graph of vector
operations, with no calls, spills or reloads. Its identifiers are aliases
that impose no evaluation order, storage, instruction or rounding boundary,
so the backend may rewrite the whole region to the cheapest graph for the
profile, and different profiles may round its intermediates differently.
`fma(a, b, c)` means one rounding, for programs that depend on it.

Today: the compiler substitutes identifiers and forms fused multiply-adds on
`x86-avx2`, `x86-avx512` and `aarch64-neon`, and [fused
bindings](spec/04_fused_bindings.md) describes the planned rewrites.

## A complete vector vocabulary

Rake's vector operations will cover:

- arithmetic, comparisons, masks and mathematical functions,
- the lane count and lane indices, and extracting and inserting lanes,
- reductions and scans,
- shuffles, interleaving, and shifts and rotations of lanes,
- fused multiply-add, chosen by the compiler or required by the source,
- gather, scatter, compression and expansion, and
- layouts of columns and of single records.

Each operation has a type rule, a rule for inactive lanes, a set of
supporting profiles and a verified lowering. A profile without a native form
of an operation rejects it before generating code.

Today: [primitives, operations, and targets](spec/01_primitives_operations_and_targets.md)
lists what each profile compiles.

## Data layout is explicit

A `pack` describes one record. A `stack` collects those records in
structure-of-arrays storage, and a stack run applies calculations to its
whole columns while the compiler visits them a rack at a time. Layout
conversions and memory operations are written in the source or set by a
documented calling convention. A stack run's tail never reads or writes past
the count.

Stacks move into the run returning them, so every update is in place and a
copy happens only where the source writes `copy`. A run selects records by
masking, with `where`, or by compaction, with `compact`, and the kernel
report shows the selection method on each target.

Today: stack runs compile on SSE2, AVX2, AVX-512, NEON and `wasm-simd128`, and
general runs over views on `wasm-simd128`. [Packs and
runs](spec/02_packs_and_run.md) defines their boundaries and checked tails.

## Scalar code stays scalar

A program's scalar work, its records, state, control flow and calls to C, is
slow code, marked `slow`. A run enters it explicitly with `slow { ... }` and
resumes vector mode at `}`. Slow code can't hold a rack, and reaches vector
work only through calls with marked uniform arguments.

Today: whole programs compile on `wasm-simd128`, as [the slow
tier](spec/08_slow_tier.md) describes. The development compiler also builds
native objects in which slow code calls register kernels, passing and
receiving uniform `f32`, `bool`, `i32` and `u32` values.

## Compilation is predictable

On physical CPU profiles the compiler owns rack instruction selection,
register allocation, instruction sequencing and assembly, and the assembler
only encodes what it's given. On WebAssembly, Rake selects the virtual
machine instructions and the shape of its `v128` values, while the runtime
chooses physical registers. Every compiler stage can be inspected. When the
compiler can't prove a profile's properties for a program, it fails with the
source construct, profile and obligation involved. A benchmark result is
reported with its source, profile, compiler version, command, input size and
baseline.

Today: on SSE2, AVX2, AVX-512 and NEON the compiler selects instructions,
allocates registers without spills and writes the assembly, and
`--emit-native-ir` and `--emit-asm` show its work. On `wasm-simd128`,
`--emit-c` writes each selected instruction as one intrinsic, clang encodes
them, and `--verify-native` checks the result.

## GPU work keeps its parallel structure

A GPU rack will map its lanes onto a specified warp, wave or subgroup, so
per-invocation arithmetic is the parallel work, and a hidden loop over the
rack inside one invocation is forbidden. Uniform values, lane masks,
collective participation, memory address patterns and synchronisation scopes
will be explicit parts of the profile, and the compiler will verify the
declared lane mapping and permitted control flow.

The initial NVIDIA PTX route leaves final register allocation and
instruction scheduling to NVIDIA, then verifies the exact cubin. Register
count, memory address structure and the absence of forbidden lowering can be
checked, whereas occupancy, cache behaviour and elapsed time need
measurement. Each resource policy has an explicit profile, and the compiler
refuses a program that would need a different one.

Today: GPU support is a design. [GPU profiles](GPU.md) defines the first
proposed NVIDIA profile, its artifact verifier and runtime boundary.
