# Rake and other languages

Rake's closest established relative is Intel's ISPC, because both let a
programmer express parallel lanes directly, whereas Bend 2 expresses parallel
tasks.

## Ways to write SIMD code

| Approach | Left to the programmer |
| --- | --- |
| A C or Rust scalar loop | confirming that autovectorisation happened at the intended width, without helper calls, and still happens after the next change to the source or compiler |
| SIMD libraries for C++ and Rust | portable vector types remove some target-specific syntax, but compiling doesn't require one register per value, no spills, no calls and no scalar replacement |
| C or Rust intrinsics | writing and dispatching an implementation for each width, while the compiler still allocates registers and may spill vectors |
| A Rake profile | choosing the profile. The compiler proves the profile's rules or rejects the program |

The compiler repository's `demo/soa-proof` harness writes
`output_x[i] = position_x[i] + velocity_x[i] * dt` over 400 particles in
Rake, strict C and Rust, and then takes the sine of every lane. None of the
builds has a vector sine, so under the harness's strict flags the C and Rust
builds call the scalar `sinf` once per value, while the Rake build stops
with
`call to 'sin' is not supported by native scratch lowering`.

## Rake and ISPC

ISPC is a C-like language for writing one program across a group of CPU
vector lanes. Like Rake, its source describes a group of lanes instead of
leaving an optimiser to find SIMD in a scalar loop, and the target chooses the
lane count. Both languages separate values shared by the group from values
owned by lanes, run divergent paths under an execution mask, give columnar
layouts their own syntax and types, and aim at CPUs and GPUs.

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
pack Particles {
  f32: position_x, velocity_x;
}

run advance_x(particles: stack Particles, <dt: f32>) -> stack Particles:
  particles with { position_x: particles.position_x + particles.velocity_x * <dt> }
```

ISPC keeps the familiar imperative loop, index, assignment and pointers, and
values in the gang vary by lane unless marked `uniform`. Rake's version is a
pure expression with no loop or index. A run applies it to whole columns of a
`stack`, the compiler splits them into racks, and the shared values are the
ones marked, with angle brackets.

| | ISPC | Rake |
| --- | --- | --- |
| Parallel unit | a gang of program instances, which may be wider than one CPU vector | a rack: one physical CPU vector register or one WebAssembly `v128` |
| Columns | `soa<n>` makes an `n`-wide structure of arrays | a `pack` describes a record, and a `stack` holds its columns |
| Divergence | `if`, loops and calls become uniform or varying from their operands | tines define masks, through blocks compute under them, and a sweep picks each lane's result |
| Back end | LLVM selects instructions and allocates registers, for CPUs and Intel Xe GPUs | Rake's own selection and allocation for SSE2, AVX2, AVX-512F and NEON, and C intrinsics for WebAssembly |
| Machine rules | gang semantics are preserved | the compiler also rejects split racks, scalar lane loops, spills and helper calls wherever the profile forbids them |
| Maturity | an established production compiler, used in renderers such as [OSPRay](https://www.ospray.org/index.html) and [Embree](https://github.com/RenderKit/embree) | native stack runs compile on four CPU profiles and WebAssembly, while native general runs and GPU targets are in progress |

ISPC's [performance guide](https://ispc.github.io/perfguide.html) and its
[Xe guide](https://ispc.github.io/ispc_for_xe.html) explain the cost of
irregular accesses that become gathers, scatters or serialised loads, and of
register pressure that causes spills. A Rake profile turns those costs into
rules, and rejects a program that breaks one with a diagnostic that identifies
the operation. The [ISPC guide](https://ispc.github.io/ispc.html) describes
the language.

## GPU execution: Rake, ISPC and Bend

On an NVIDIA GPU, a warp groups 32 threads that each hold one lane's values
and execute each operation together, although divergent paths can leave some
lanes inactive. The hardware schedules warps, while the program decides the
work on their lanes, as NVIDIA's
[SIMT description](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model)
explains.

| | Rake GPU design | ISPC | Bend 2 |
| --- | --- | --- | --- |
| Parallel work | rack lanes mapped onto a specified warp or subgroup | SPMD program instances in a gang | independent parallel calls, arranged as binary fork–join tasks |
| Lowering | Rake checks the lane mapping, and NVIDIA allocates and schedules | LLVM and the Intel GPU compiler lower gangs for Xe | the runtime distributes tasks across CPU or GPU workers |
| Guarantee | rejection of hidden serial lane work and forbidden spills or helpers | defined gang, mask and uniform/varying semantics | none for balance, which stays the programmer's job |
| Still needs measurement | lane activity, occupancy, memory transactions and elapsed time | branch coherence, spills, memory costs and elapsed time | task balance, divergence, scheduling costs and elapsed time |
| Availability | [design only](GPU.md) | CPU and Intel Xe GPU targets | CPU and GPU parallel-call paths |

Bend 2 asks the programmer for independent calls that take roughly the same
time. A binary fork–join scheduler distributes that work once, and a `!`
after a call sends it and its nested calls to the GPU. This comparison uses
the [Bend 2 guide at revision
75cc360](https://github.com/bendlang/bend/blob/75cc36027d1ead249c6f8a2e6d22dfe75b261c17/guide/GUIDE.md#parallelism),
and the ISPC guides at [documentation revision
c22f07f](https://github.com/ispc/ispc.github.com/tree/c22f07f9f626e32393741ccb5f3c7e145db40bbd).

## Other languages for parallel kernels

| Language | Provides | Difference from Rake |
| --- | --- | --- |
| [Halide](https://halide-lang.org/docs/) | image and stencil pipelines in C++, with the algorithm separate from its schedule | a programmer or autoscheduler chooses widths, tiling and placement, and nothing checks them as register rules |
| [Futhark](https://futhark-lang.org/) | a purely functional array language for CUDA, OpenCL or multithreaded CPUs | bulk and nested array parallelism, where Rake keeps each rack one profile-sized vector |
| CUDA, HIP, shader languages and [Slang](https://docs.shader-slang.org/en/stable/external/slang/docs/user-guide/08-compiling.html) | GPU programming over threads, warps, waves and subgroups | Rake's proposed GPU profile would also prove its lowering and resource rules or reject the artifact |
| [Taichi](https://docs.taichi-lang.org/docs/hello_world) | parallel kernels for CPUs and GPUs, embedded in Python | portable parallel iteration and data layout, with no proof of a fixed SIMD representation |
| [Mojo](https://mojolang.org/docs/manual/types/#simd-and-dtype) | a systems language with parameterised SIMD values and CPU and GPU facilities | the width is a `SIMD` type parameter, whereas a Rake profile fixes it and rejects a rack too wide for one register |
| Research languages | Impala and AnyDSL, Lift and Shine, Accelerate and Dex | staged compilation, rewrite systems and functional data parallelism |
