# Glossary

Rake's language and compiler terminology. The [vectors cheat sheet](VECTORS.md)
explains CPU SIMD and GPU terms, with examples of lane and memory operations.

## Rake's terms

| Term | Meaning |
| --- | --- |
| rack | one parallel value of the target profile, such as an `f32s`: one physical CPU vector register or WebAssembly `v128`. The GPU design maps it across a specified warp or subgroup |
| lane | one element position in a rack: an `f32s` on AVX2 has eight |
| uniform | one scalar shared by every lane, marked `<name>` |
| tine | a labelled lane mask, local to a rake or defined globally as a typed predicate such as `#valid(values)` |
| gaps | the exact Boolean complement of a tine or composed mask, including lanes with NaNs that failed its comparisons |
| through block | code that computes under a mask, with an optional `else` value for other lanes. Without `else`, only selected lanes are defined |
| sweep | the choice of each lane's result in priority order, with masks that provably cover every lane or a final `_` |
| scratch | a function of racks without a tine/through/sweep body |
| rake | a function of racks with tines, through blocks and a sweep |
| run | vector code over memory: traverse stacks and apply rakes or scratches to racks from their columns |
| slow code | scalar code, marked `slow`, that holds no racks |
| slow block | `slow { ... }`, a lexical scalar escape inside a run or slow function, optionally producing a scalar value |
| fused binding | `\| name <\| e`, one stage of a pure fused computation |
| pack | one record described by a `pack` declaration, with its fields stored together |
| stack | a collection of packs transposed into one contiguous column for each field |
| traversal | `for chunk in input using f32s up to <n>:`, a rack-sized slice of a stack's columns at a time |
| view | `[]T`, elements with a count, borrowed from the caller |
| profile | a named target, such as `x86-avx2`, that fixes the rack width and the rules |
| widening | converting narrow stored elements, such as `u8`, to wider lanes without changing their values |

## Compiler terms

| Term | Meaning |
| --- | --- |
| front end, back end | the front end parses and checks source, and the back end selects instructions, assigns registers and writes the program |
| SSA | static single assignment: a representation in which each value is defined once, which makes data dependencies explicit |
| declaration, definition | a declaration introduces a name and may give its type. A definition supplies the value or behaviour it denotes. A language construct can do both |
| binding, reference | a binding associates a name with a value or other program entity, and a reference uses that name within its scope. Rake's immutable value bindings don't designate memory locations |
| fusion | combining separate pieces of work so they can execute together, such as merging loops into one pass or forming a fused multiply-add. Rake uses fused bindings for stages of pure vector calculations |
| instruction selection | choosing the machine instructions for each operation |
| register allocation | assigning each value to a physical register. Rake does this on its physical CPU targets. WebAssembly runtimes and the proposed NVIDIA toolchain own it on their virtual targets |
| object code | encoded machine instructions and data, ready for a linker |
| assembler | the tool that encodes textual assembly as object code |
| LLVM | a compiler infrastructure with optimisation, instruction selection and register allocation for multiple targets |
| ABI | application binary interface: the rules for passing arguments, returning values and laying out data |
| System V ABI | the calling convention most Unix-like x86-64 systems use |
| AAPCS64 | the procedure call standard for 64-bit Arm |
| conformance corpus | the accepted and rejected example programs that check the compiler against the language's rules |
| OCaml, Dune, Nix | the language the compiler is written in, its build system, and the package manager that pins the tools in `nix develop` |
