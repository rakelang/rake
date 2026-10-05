# The rakec command

`rakec` compiles one `.rk` file. Build it with `nix develop --command dune
build`, which puts it at `_build/default/src/bin/main.exe`, or run it with
`dune exec rakec --`.

```sh
rakec program.rk                                   # parse and type-check
rakec --interpret program.rk                       # run main and print its result
rakec --interpret program.rk -- alpha --flag        # pass process arguments
rakec --emit-c --target x86-avx2 program.rk          # write program.c
rakec --emit-asm --target x86-avx2 kernels.rk        # write kernels.s
rakec --verify-native --target wasm-simd128 program.rk  # write a verified program.o
```

## Modes

| Mode | Output |
| --- | --- |
| none | parses and type-checks the file, and prints a confirmation |
| `--interpret` | runs `slow main` in Rake's executable semantics and prints its result, or the trap |
| `--emit-native-ir` | the typed native IR after optimisation, and a whole program's tier IR |
| `--emit-c` | a C translation unit for the selected profile |
| `--emit-asm` | GNU assembly for physical-target register kernels |
| `--emit-obj` | an object file, assembled or compiled from that output |
| `--verify-native` | the object, after disassembling and checking it |
| `--emit-tokens`, `--emit-ast` | the tokens or the syntax tree, for debugging the front end |
| `--print-targets` | the target profiles and their status |
| `--print-capabilities` | every language feature and its status |
| `--version`, `--help` | the version, or a summary of this page |

`--emit-c`, `--emit-asm`, `--emit-obj` and `--verify-native` write to the input's
filename with `.c`, `.s` or `.o` unless `-o path` gives another. `-o` isn't allowed
with the check, token and syntax-tree modes. A whole program, one with slow
code, runs, records, state, embedded files, constants or externs, compiles for
the wasm profiles. Rake 0.7.0 also supports native slow orchestration with
register kernels. Their `--emit-c`
output embeds Rake-selected assembly, and their `--emit-obj`
output is a platform C object with verified kernels. `--verify-native` checks
those kernels too. Native slow-only units have no vector function to verify,
so they use `--emit-obj`. SSE2, AVX2, AVX-512 and NEON additionally compile
[stack runs](spec/02_packs_and_run.md#stack-runs). General runs over views remain
work in progress on those profiles. A successful build of stack runs ends with
the [kernel report](spec/02_packs_and_run.md#kernel-report) on standard error,
which `--no-report` omits. A
native kernel called from slow code supports uniform `f32`, `bool`, `i32` and `u32`
parameters and returns `f32`, `bool`, `i32` or `u32`.

## C output and C interoperation

`--emit-c` gives you source to compile with your C toolchain. On physical CPU
profiles it contains Rake-selected kernel assembly alongside the C for slow
code. The C compiler lowers that slow code and implements its platform ABI.
The embedded assembly retains Rake's vector instructions and allocated
registers. On WebAssembly, the C unit expresses selected virtual instructions
through `wasm_simd128.h` intrinsics.

C ABI interoperation describes the binary boundary between functions,
regardless of which source language produced them. Rake can call C functions,
export slow functions and exchange header-backed records, unions and typed
callbacks. Those abilities apply when Rake emits an object directly too.
[The slow tier](spec/08_slow_tier.md#definitions) explains the declarations.

Use `--emit-asm` for a physical-target file containing only register kernels.
It rejects whole programs and WebAssembly instead of writing C under an
assembly option. Emitted source still needs compilation. `--verify-native`
checks the vector functions in the resulting object against the selected
profile, as [the backend](BACKEND.md) explains.

## Options

| Option | Meaning |
| --- | --- |
| `--target p` | the profile: `native` (the default), `x86-sse2`, `x86-avx2`, `x86-avx512`, `aarch64-neon`, `wasm-simd128`, `wasm-simd128-relaxed`, or the WIP scalar fallback |
| `--width n` | asserts that the profile's `f32` rack has `n` lanes |
| `--wasm-addressing a` | `barrier`, the default, keeps a run's pointers opaque to clang's loop strength reduction so constant offsets fold into loads and stores, and `plain` emits intrinsics alone |
| `-o path`, `--output path` | the output file |
| `-- args...` | process arguments for `--interpret`, including strings that begin with `-` |

Rake 0.7.0 supports [process arguments](spec/08_slow_tier.md#process-arguments)
through `slow main(argc: i32, argv: ptr ptr u8) -> i32`. The input path is
`argv[0]` in the interpreter. Native and WASI executables receive their
runtime's program string instead. Without parameters, `main` ignores the
process arguments.

Without an explicit target, `--interpret` uses WebAssembly's four `f32` lanes.
`--target` selects the reference rack width, so an AVX2 float reduction uses
eight lanes and an AVX-512 reduction uses sixteen. This interprets the source;
it does not execute the generated machine code.

[Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md#profiles) explains how
`native` chooses a profile and what `--width` checks, and [packs and
runs](spec/02_packs_and_run.md#addressing) explains the addressing modes.

## Tools and environment

The front end, interpreter and textual output need only the OCaml package
dependencies. Object emission additionally needs the selected target's
toolchain. Native profiles use GNU ELF assemblers and disassemblers, even
when the compiler itself runs on another operating system. A host's Mach-O
or PE assembler is not a substitute for the selected ELF toolchain.

For x86, Rake searches `x86_64-linux-gnu-`, `x86_64-unknown-linux-gnu-` and
`x86_64-elf-` tools before unprefixed `as` and `objdump`. For AArch64 it
searches `aarch64-linux-gnu-`, `aarch64-unknown-linux-gnu-`,
`aarch64-none-linux-gnu-` and `aarch64-elf-` tools. On an AArch64 Linux host
with unprefixed tools, set the overrides to `as` and `objdump`. An explicit
override is one executable path, with no flags or shell expansion. A failed
tool or verification step remains an error.

| Variable | Meaning |
| --- | --- |
| `RAKE_X86_AS` | GNU ELF x86-64 assembler, invoked with `--64` |
| `RAKE_X86_OBJDUMP` | GNU x86-64 object disassembler |
| `RAKE_AARCH64_AS` | GNU ELF AArch64 assembler |
| `RAKE_AARCH64_OBJDUMP` | GNU AArch64 object disassembler |
| `RAKE_AARCH64_CC` | GCC-compatible AArch64 compiler for native whole programs |
| `RAKE_NATIVE_CC` | native whole-program compiler override, taking precedence for every profile |

On Debian or Ubuntu, install `binutils` for x86 objects and
`binutils-aarch64-linux-gnu` for AArch64 objects. The native
whole-program path also needs `gcc` or `gcc-aarch64-linux-gnu` respectively.
The Nix development shell supplies these toolchains. Other hosts can use a
GNU ELF cross-toolchain with the same executable overrides.

The wasm profiles use these variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAKE_WASM_CC` | `clang` | the C compiler for wasm32 objects |
| `RAKE_WASM_OBJDUMP` | `llvm-objdump` | the disassembler for verification |
| `RAKE_WASM_CFLAGS` | empty | extra flags when compiling a whole program |

Process entries with arguments need WASI headers during WebAssembly object
compilation. The development shell supplies their include path through
`RAKE_WASM_CFLAGS`. Outside it, set that variable to your WASI include or
sysroot flags and link the emitted object with WASI libc and its command
startup object.

The native C path uses `gcc` on x86 and searches
`aarch64-linux-gnu-gcc`, `aarch64-unknown-linux-gnu-gcc` and
`aarch64-none-linux-gnu-gcc` on AArch64. `RAKE_NATIVE_CC` can select a
different executable with the same GCC-compatible command-line interface.
The compiler writes GNU C11, disables floating-point contraction and fast
math, and compiles with warnings treated as errors. Its source directory is
on the include path. Link the emitted object with the platform linker and
its required C libraries, including `libm` for scalar maths. Native register
kernels remain opaque GNU assembly in that C unit, so the C compiler cannot
replace their selected instructions.

The emitted C reads two macros. `RAKE_WASM_LINKAGE` replaces `static inline`
on each scratch and rake, and `RAKE_FRAME_BYTES` sets the size of a whole
program's frame stack, 4 MiB by default, as [the slow
tier](spec/08_slow_tier.md#the-c-unit) describes.

## Diagnostics

Errors give the file, line and column and the stage that failed:

```text
program.rk:3:9: Type error: repeat is the unrolled vector loop; slow code counts with for
native instruction selection failed: f: AVX2 selection failed at native instruction 0: ...
```

Front-end errors are lexical, syntax, layout or type errors. Back-end errors
identify the stage, such as native lowering, instruction selection, register
allocation or object verification, and the operation or obligation that
failed. A trap from `--interpret` gives the location and the reason, such as
`trap: i32 overflow`.
