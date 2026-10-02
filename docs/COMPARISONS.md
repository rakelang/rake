# Rake and other languages

Rake's closest established relative is Intel's ISPC. Both let a programmer
express parallel lanes directly. Bend 2 expresses parallel tasks instead.
This page compares those execution models, the properties their compilers
check, and the performance that still needs measurement.

## Ways to write SIMD code

| Approach | What stays the programmer's job |
| --- | --- |
| A C or Rust scalar loop | confirming that autovectorisation happened, used the intended width, avoided helper calls, and didn't regress after a change to the source or the compiler |
| SIMD libraries for C++ and Rust | portable vector types remove some target-specific syntax, but the compiler doesn't make one register for each value, no spills, no calls and no scalar replacement a condition of compiling |
| C or Rust intrinsics | writing and dispatching an implementation for each width. The compiler still allocates registers and may spill vectors |
| A Rake profile | choosing the profile. The compiler proves the profile's rules or rejects the program |

The `demo/soa-proof` harness in the compiler repository makes this concrete
for one operation, `output_x[i] = position_x[i] + velocity_x[i] * dt` over 400
particles, written in Rake, strict C and Rust. Its sharpest case is a sine of
every lane. None of the builds has a vector sine. The C and Rust builds
compile anyway and call the scalar `sinf` once per value, under the
harness's strict flags. The Rake build stops at native lowering with
`call to 'sin' is not supported by native crunch lowering`. Other toolchains
or flags may make other choices, and the harness records the ones it used.

## Rake and ISPC

ISPC is a C-like language for writing one program across a group of CPU
vector lanes. Both languages express lane-parallel work with widths the
target chooses. ISPC uses an imperative single-program, multiple-data model,
and Rake uses expression-oriented vector data flow with profiles that
constrain instruction selection and register allocation.

They share these ideas:

- the source describes a group of lanes, instead of asking an optimiser to
  find SIMD in a scalar loop,
- one source compiles for several lane counts, chosen by the target,
- values shared by the group are distinguished from values owned by lanes,
- lanes may follow different logical paths under an execution mask,
- columnar data layouts have their own syntax and types, and
- the languages aim at CPUs and GPUs. ISPC ships CPU and Intel GPU targets,
  and Rake has CPU profiles and [a GPU design](GPU.md).

The same update of every particle in a structure of arrays, in ISPC:

```c
export void advance_x(
    uniform float position_x[],
    uniform float velocity_x[],
    uniform float output_x[],
    uniform int count,
    uniform float dt) {
  foreach (i = 0 ... count)
    output_x[i] = position_x[i]
                + velocity_x[i] * dt;
}
```

and in Rake:

```rake
stack Particles {
  f32: position_x, velocity_x;
}

run advance_x(particles: pack Particles, <count: i64>, <dt: f32>) -> f32:
  for particle in particles using f32s up to <count>:
    yield particle.position_x + particle.velocity_x * <dt>
```

ISPC keeps the familiar loop, index, assignment, pointer and C
interoperability. Values in the gang vary by lane unless marked `uniform`.
Rake moves the traversal and the columns into `for ... using ... up to ...`,
`pack` and `stack`, and marks the shared values instead, with angle brackets.
Its vector code favours pure expressions and bindings that are defined once.

| | ISPC | Rake |
| --- | --- | --- |
| Model | imperative C-family SPMD, with loops, assignments, pointers, functions and ordinary control flow | expression-oriented vector data flow, with marked uniforms, fused bindings, tines, through blocks and sweeps |
| Parallel unit | a gang of program instances, which may be wider than one CPU vector | a rack: one physical CPU vector register or one WebAssembly `v128`. A proposed GPU rack spans a specified warp or subgroup |
| Columns | `soa<n>` makes an `n`-wide structure of arrays and supports layout conversion | `stack` declares columns, `pack` supplies them with a count, and the profile chooses the width |
| Divergence | `if`, loops and calls become uniform or varying from their operands | tines name masks, through blocks compute under them, and a sweep picks each lane's result |
| Machine rules | gang semantics are preserved, and LLVM selects instructions and allocates registers | the compiler also rejects split racks, scalar lane loops, spills and helper calls wherever the profile forbids them |
| Back end | LLVM for CPUs, and documented Intel Xe GPU targets | Rake's own instruction selection and allocation for SSE2, AVX2, AVX-512F and NEON, and C intrinsics for WebAssembly |
| Maturity | an established production compiler with C and C++ interoperability, tasking, libraries, tools and CPU and GPU targets | a beta compiler with four physical CPU profiles and WebAssembly. Native mixed programs are an unreleased addition; native runs and GPU targets are WIP* |

*WIP: work in progress.*

ISPC is used for performance-critical kernels inside C and C++ systems.
[OSPRay](https://www.ospray.org/index.html)'s CPU renderer is built on it and
uses SSE4, AVX, AVX2, AVX-512 and NEON,
[Embree](https://github.com/RenderKit/embree) supports it for renderer code,
and [CMake](https://cmake.org/cmake/help/latest/envvar/ISPC.html) has
recognised it as a language since version 3.19.

ISPC preserves its SPMD semantics while LLVM chooses the instructions. Its
[performance guide](https://ispc.github.io/perfguide.html) describes
irregular accesses that become gathers, scatters or serialised loads, and
explains their cost. A Rake profile lists the operations it forbids instead,
and rejects a program that would need one, with a diagnostic that gives the
operation. The [ISPC guide](https://ispc.github.io/ispc.html) and [ISPC for
Intel Xe](https://ispc.github.io/ispc_for_xe.html) describe its language and
targets.

## GPU execution: Rake, ISPC and Bend

On an NVIDIA GPU, a warp groups 32 threads. Each thread holds one lane's
values, and participating lanes execute the operation together. Different
paths can leave some lanes inactive. The hardware schedules warps, while
the program determines the work assigned to their lanes. NVIDIA's
[SIMT description](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model)
explains that distinction.

Rake's [proposed GPU contract](GPU.md) will preserve a rack's lane-to-thread
mapping and check its permitted control flow, memory effects and register
use. A partial mask remains a legitimate program choice. The compiler will
reject a hidden loop that serially emulates the rack, or forbidden spills
and helper paths in a strict region. It cannot ensure that every input keeps
all lanes busy, or that a no-spill kernel is the fastest one.

| Question | Rake GPU design | ISPC | Bend 2 |
| --- | --- | --- | --- |
| How is parallel work expressed? | rack lanes mapped onto a specified warp or subgroup | SPMD program instances in a gang, with uniform and varying values | independent parallel calls, arranged as binary fork–join tasks |
| Who distributes or lowers the work? | Rake specifies and checks lane mapping; the proposed PTX route delegates final allocation and scheduling to NVIDIA | LLVM and the Intel GPU compiler lower gangs for Xe; the runtime launches the work | the runtime distributes fork–join tasks across CPU or GPU workers |
| What is the relevant contract? | profile-specific rejection of hidden serial lane work and forbidden lowering/resource costs | defined gang, mask and uniform/varying semantics, with documented performance guidance | independent calls and balanced work, with balance remaining the programmer's responsibility |
| What still needs measurement? | lane activity, occupancy, memory transactions and elapsed time | branch coherence, spills, memory costs and elapsed time | task balance, divergence, scheduling costs and elapsed time |
| Availability | design only; no Rake GPU compiler, runtime or verifier yet | implemented CPU and Intel Xe GPU targets | implemented CPU and GPU parallel-call paths, as described in the pinned guide below |

ISPC already exposes lane parallelism. Its distinction from Rake isn't that
it depends on autovectorising an ordinary C loop. ISPC's
[Xe performance guide](https://ispc.github.io/ispc_for_xe.html)
explains how varying loops and register pressure can cause costly spills,
and how uniform values and coherent branches affect execution. Rake's
planned addition is a strict checked lowering and resource contract for
specified regions, rather than performance advice alone.

Bend 2 asks the programmer to provide independent calls that take roughly
the same time. Its current guide describes a binary fork–join scheduler
that distributes that work once, without moving tasks afterwards. A `!`
after a call sends it and its nested parallel calls to the GPU. Those
constructs distribute task parallelism; they don't define a per-rack
no-spill contract. This comparison uses the [Bend 2 guide at revision
75cc360](https://github.com/bendlang/bend/blob/75cc36027d1ead249c6f8a2e6d22dfe75b261c17/guide/GUIDE.md#parallelism).
The ISPC guides were checked at [documentation revision
c22f07f](https://github.com/ispc/ispc.github.com/tree/c22f07f9f626e32393741ccb5f3c7e145db40bbd).

The original Bend/HVM2 lineage used interaction-net evaluation and runtime
work sharing. Its [HVM2 paper](https://github.com/HigherOrderCO/HVM2/blob/main/paper/HVM2.typst)
is historical context, not a description of the current Bend 2 scheduler.

Rake, ISPC and Bend still need enough independent work and balanced workloads
to use a device effectively. More registers per thread can reduce resident
warps, so forbidding spills doesn't establish a speed ranking. The
comparison above concerns execution models and checked properties, not a
benchmark result between these projects.

## Other languages for parallel kernels

| Language | What it provides | How it differs from Rake |
| --- | --- | --- |
| [Halide](https://halide-lang.org/docs/) | a functional language embedded in C++ for image and stencil pipelines, with the algorithm separate from its schedule across CPUs and GPUs | vector widths, tiling and placement come from a programmer or an autoscheduler, and aren't checked as register rules |
| [Futhark](https://futhark-lang.org/) | a statically typed, purely functional array language compiled to CUDA, OpenCL or multithreaded CPU code | its abstraction is bulk and nested array parallelism, not one rack that must stay one profile-sized vector value |
| CUDA, HIP, shader languages and [Slang](https://docs.shader-slang.org/en/stable/external/slang/docs/user-guide/08-compiling.html) | GPU programming over threads, warps, waves and subgroups, for SPIR-V, DXIL and native GPU code | Rake's proposed GPU profile would additionally require proof of its specified lowering and resource rules, or reject the artifact |
| [Taichi](https://docs.taichi-lang.org/docs/hello_world) | a data-oriented language embedded in Python that compiles parallel kernels for CPUs and GPUs | it concentrates on portable parallel iteration and data layout, not on proving a fixed SIMD representation |
| [Mojo](https://mojolang.org/docs/manual/types/#simd-and-dtype) | a systems language with parameterised SIMD values, vectorised algorithms and CPU and GPU facilities | the element type and width parameter are part of its `SIMD` type. In Rake the profile fixes the width, and a physical profile rejects a rack it can't keep in one register |
| SIMD libraries for C++ and Rust | portable vector types and algorithms | they are library interfaces, and don't make one physical register per value, no spills, no calls and no scalar lane loops a condition of compiling |
| Research languages | Impala and AnyDSL, Lift and Shine, Accelerate and Dex explore staged compilation, rewrite systems and functional data parallelism | their abstractions and status differ by project |
