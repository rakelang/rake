# Rake and other languages

Rake's closest established relative is Intel's ISPC. This page compares the
two, then sets Rake beside the other ways of writing SIMD code and the other
languages for parallel kernels.

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
| Parallel unit | a gang of program instances, which may be wider than one CPU vector | a rack, exactly one vector register |
| Columns | `soa<n>` makes an `n`-wide structure of arrays and supports layout conversion | `stack` declares columns, `pack` supplies them with a count, and the profile chooses the width |
| Divergence | `if`, loops and calls become uniform or varying from their operands | tines name masks, through blocks compute under them, and a sweep picks each lane's result |
| Machine rules | gang semantics are preserved, and LLVM selects instructions and allocates registers | the compiler also rejects split racks, scalar lane loops, spills and helper calls wherever the profile forbids them |
| Back end | LLVM for CPUs, and documented Intel Xe GPU targets | Rake's own instruction selection and allocation for AVX2 and NEON, and C intrinsics for WebAssembly |
| Maturity | an established production compiler with C and C++ interoperability, tasking, libraries, tools and CPU and GPU targets | a beta compiler with verified AVX2, NEON and WebAssembly profiles, runs and whole programs on WebAssembly |

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

## Other languages for parallel kernels

| Language | What it provides | How it differs from Rake |
| --- | --- | --- |
| [Halide](https://halide-lang.org/docs) | a functional language embedded in C++ for image and stencil pipelines, with the algorithm separate from its schedule across CPUs and GPUs | vector widths, tiling and placement come from a programmer or an autoscheduler, and aren't checked as register rules |
| [Futhark](https://futhark-lang.org/) | a statically typed, purely functional array language compiled to CUDA, OpenCL or multithreaded CPU code | its abstraction is bulk and nested array parallelism, not one rack that must stay one register |
| CUDA, HIP, shader languages and [Slang](https://docs.shader-slang.org/en/stable/external/slang/docs/user-guide/08-compiling.html) | GPU programming over threads, warps, waves and subgroups, for SPIR-V, DXIL and native GPU code | they model the GPU well, but no construct is a portable CPU SIMD register with a compiler that refuses what it can't keep in one |
| [Taichi](https://docs.taichi-lang.org/docs/hello_world) | a data-oriented language embedded in Python that compiles parallel kernels for CPUs and GPUs | it concentrates on portable parallel iteration and data layout, not on proving a fixed SIMD representation |
| [Mojo](https://docs.modular.com/mojo/std/builtin/simd/SIMD/) | a systems language with parameterised SIMD values, vectorised algorithms and CPU and GPU facilities | the width is part of the SIMD type, and Mojo documents that an oversized value may be split across registers. In Rake the profile sets the width, and a split is a rejection |
| SIMD libraries for C++ and Rust | portable vector types and algorithms | they are library interfaces, and don't make one register for each value, no spills, no calls and no scalar lane loops a condition of compiling |
| Research languages | Impala and AnyDSL, Lift and Shine, Accelerate and Dex explore staged compilation, rewrite systems and functional data parallelism | their abstractions and status differ by project |
