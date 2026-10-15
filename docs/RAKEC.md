# The rakec command

`rakec` compiles one `.rk` file.

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
| `--print-capabilities` | every language feature's status in the frontend and on each profile |
| `--version`, `--help` | the version, or a summary of this page |

`--emit-c`, `--emit-asm`, `--emit-obj` and `--verify-native` write to the
input's filename with `.c`, `.s` or `.o` unless `-o path` gives another. `-o`
isn't allowed with the check, token and syntax-tree modes.

Whole programs, meaning those with slow code, runs, records, state, embedded
files, constants or externs, compile for the wasm profiles. Native profiles
compile slow code that calls register kernels, and `--emit-obj` produces a
platform C object with verified kernels. Slow-only native units have no
vector function to verify, so they use `--emit-obj` instead of
`--verify-native`. SSE2, AVX2, AVX-512 and NEON also compile
[stack runs](spec/02_packs_and_run.md#stack-runs), while general runs over
views are still in progress there. A successful build of stack runs ends with
the [kernel report](spec/02_packs_and_run.md#kernel-report) on standard error,
unless `--no-report` is given. A native kernel called from slow code takes
uniform `f32`, `bool`, `i32` and `u32` parameters and returns one of those
types.

## C output and C interoperation

`--emit-c` gives you source to compile with your C toolchain. On physical CPU
profiles it contains Rake-selected kernel assembly, with its vector
instructions and allocated registers, alongside C for the slow code, and
the C compiler lowers that C to the platform ABI. On WebAssembly, the C unit
expresses the selected virtual instructions through `wasm_simd128.h`
intrinsics.

Rake can call C functions, export slow functions and exchange header-backed
records, unions and typed callbacks, whether it emits C or an object.
[The slow tier](spec/08_slow_tier.md#definitions) explains the declarations.

`--emit-asm` writes a physical-target file containing only register kernels,
and rejects whole programs and WebAssembly. [The backend](BACKEND.md) explains
what `--verify-native` checks.

## Options

| Option | Meaning |
| --- | --- |
| `--target p` | the profile: `native` (the default), `x86-sse2`, `x86-avx2`, `x86-avx512`, `aarch64-neon`, `wasm-simd128`, `wasm-simd128-relaxed`, or the WIP scalar fallback |
| `--width n` | asserts that the profile's `f32` rack has `n` lanes |
| `--wasm-addressing a` | `barrier`, the default, keeps a run's pointers opaque to clang's loop strength reduction so constant offsets fold into loads and stores, and `plain` emits intrinsics alone |
| `-o path`, `--output path` | the output file |
| `-- args...` | process arguments for `--interpret`, including strings that begin with `-` |

`slow main(argc: i32, argv: ptr ptr u8) -> i32` receives the
[process arguments](spec/08_slow_tier.md#process-arguments). In the
interpreter, `argv[0]` is the input path, and native and WASI executables
receive their runtime's program string instead. A `main` without parameters
ignores the process arguments.

`--interpret` evaluates the source in the reference semantics without running
generated machine code. Without `--target` it uses WebAssembly's four `f32`
lanes, and a target sets the rack width, so an AVX2 float reduction uses
eight lanes and an AVX-512 one sixteen.

[Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md#profiles)
explains how `native` chooses a profile and what `--width` checks, and
[packs and runs](spec/02_packs_and_run.md#addressing) explains the addressing
modes.

## Tools and environment

The front end, interpreter and textual output need only the OCaml package
dependencies. Object emission also needs the selected target's toolchain.
Native profiles use GNU ELF assemblers and disassemblers on every host
operating system, and a Mach-O or PE assembler can't stand in for them.

For x86, Rake searches for `x86_64-linux-gnu-`, `x86_64-unknown-linux-gnu-`
and `x86_64-elf-` tools before unprefixed `as` and `objdump`. For AArch64 it
searches for `aarch64-linux-gnu-`, `aarch64-unknown-linux-gnu-`,
`aarch64-none-linux-gnu-` and `aarch64-elf-` tools, so an AArch64 Linux host
with unprefixed tools sets the overrides to `as` and `objdump`. An override is
one executable path, with no flags or shell expansion. A failed tool or
verification step is an error.

| Variable | Meaning |
| --- | --- |
| `RAKE_X86_AS` | GNU ELF x86-64 assembler, invoked with `--64` |
| `RAKE_X86_OBJDUMP` | GNU x86-64 object disassembler |
| `RAKE_AARCH64_AS` | GNU ELF AArch64 assembler |
| `RAKE_AARCH64_OBJDUMP` | GNU AArch64 object disassembler |
| `RAKE_AARCH64_CC` | GCC-compatible AArch64 compiler for native whole programs |
| `RAKE_NATIVE_CC` | native whole-program compiler override, taking precedence for every profile |

On Debian or Ubuntu, install `binutils` for x86 objects and
`binutils-aarch64-linux-gnu` for AArch64 objects, plus `gcc` or
`gcc-aarch64-linux-gnu` for native whole programs. The Nix development shell
supplies these toolchains, and other hosts can use a GNU ELF cross-toolchain
with the same overrides.

The wasm profiles use these variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAKE_WASM_CC` | `clang` | the C compiler for wasm32 objects |
| `RAKE_WASM_OBJDUMP` | `llvm-objdump` | the disassembler for verification |
| `RAKE_WASM_CFLAGS` | empty | extra flags when compiling a whole program |

A process entry with arguments needs WASI headers when compiling a
WebAssembly object. The development shell supplies their include path
through `RAKE_WASM_CFLAGS`. Elsewhere, set that variable to your WASI include
or sysroot flags, and link the object with WASI libc and its command startup
object.

The native C path uses `gcc` on x86 and searches for
`aarch64-linux-gnu-gcc`, `aarch64-unknown-linux-gnu-gcc` and
`aarch64-none-linux-gnu-gcc` on AArch64, and `RAKE_NATIVE_CC` can select any
GCC-compatible compiler. It compiles GNU C11 without
floating-point contraction or fast math, with warnings as errors and the
source directory on the include path. Link the object with the platform
linker and its C libraries, including `libm` for scalar maths.

The emitted C reads two macros. `RAKE_WASM_LINKAGE` replaces `static inline`
on each scratch and rake, and `RAKE_FRAME_BYTES` sets the size of a whole
program's frame stack, 4 MiB by default, as
[the slow tier](spec/08_slow_tier.md#the-c-unit) describes.

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
