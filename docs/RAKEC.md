# The rakec command

`rakec` compiles one `.rk` file. Build it with `nix develop --command dune
build`, which puts it at `_build/default/src/bin/main.exe`, or run it with
`dune exec rakec --`.

```sh
rakec program.rk                                   # parse and type-check
rakec --interpret program.rk                       # run main and print its result
rakec --emit-asm --target x86-avx2 program.rk      # write program.s
rakec --verify-native --target wasm-simd128 program.rk  # write a verified program.o
```

## Modes

| Mode | Output |
| --- | --- |
| none | parses and type-checks the file, and prints a confirmation |
| `--interpret` | runs `slow main() -> i32` in Rake's executable semantics and prints its result, or the trap |
| `--emit-native-ir` | the typed native IR after optimisation, and a whole program's tier IR |
| `--emit-asm` | GNU assembly on x86 and AArch64, C on the wasm profiles |
| `--emit-obj` | an object file, assembled or compiled from that output |
| `--verify-native` | the object, after disassembling and checking it |
| `--emit-tokens`, `--emit-ast` | the tokens or the syntax tree, for debugging the front end |
| `--print-targets` | the target profiles and their status |
| `--print-capabilities` | every language feature and its status |
| `--version`, `--help` | the version, or a summary of this page |

`--emit-asm`, `--emit-obj` and `--verify-native` write to the input's name
with `.s`, `.c` or `.o` unless `-o path` gives another. `-o` isn't allowed
with the check, token and syntax-tree modes. A whole program, one with slow
code, runs, records, state, embedded files, constants or externs, compiles for
the wasm profiles only.

## Options

| Option | Meaning |
| --- | --- |
| `--target p` | the profile: `native` (the default), `x86-sse2`, `x86-avx2`, `x86-avx512`, `aarch64-neon`, `wasm-simd128`, `wasm-simd128-relaxed`, or the WIP scalar fallback |
| `--width n` | asserts that the profile's `f32` rack has `n` lanes |
| `--wasm-addressing a` | `barrier`, the default, keeps a run's pointers opaque to clang's loop strength reduction so constant offsets fold into loads and stores, and `plain` emits intrinsics alone |
| `-o path`, `--output path` | the output file |

[Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md#profiles) explains how
`native` chooses a profile and what `--width` checks, and [packs and
runs](spec/02_packs_and_run.md#addressing) explains the addressing modes.

## Tools and environment

On every x86 profile the assembler is `as --64`, and on `aarch64-neon` it is
`aarch64-unknown-linux-gnu-as`. Verification disassembles with the matching
`objdump`. The wasm profiles use these variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAKE_WASM_CC` | `clang` | the C compiler for wasm32 objects |
| `RAKE_WASM_OBJDUMP` | `llvm-objdump` | the disassembler for verification |
| `RAKE_WASM_CFLAGS` | empty | extra flags when compiling a whole program |

The emitted C reads two macros. `RAKE_WASM_LINKAGE` replaces `static inline`
on each crunch and rake, and `RAKE_FRAME_BYTES` sets the size of a whole
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
